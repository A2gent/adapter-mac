import Cocoa
import ApplicationServices

enum AccessibilityPasteResult {
    case pasted
    case copiedToClipboard(reason: String)
}

class AccessibilityService {
    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }
    
    static func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
    
    static func getSelectedText() -> String? {
        guard isAccessibilityEnabled() else { return nil }
        
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp else {
            return nil
        }
        
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            return nil
        }
        
        var selectedText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
              let text = selectedText as? String else {
            return nil
        }
        
        return text
    }

    static func getSelectedText(completion: @escaping (String?) -> Void) {
        if let directSelection = getSelectedText(), !directSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(directSelection)
            return
        }

        copySelectedTextViaClipboard(completion: completion)
    }
    
    static func pasteText(_ text: String) -> AccessibilityPasteResult {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isAccessibilityEnabled() else {
            print("Accessibility permission not granted")
            return .copiedToClipboard(reason: "Accessibility access is not active for this running build.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) // V key
            cmdVDown?.flags = .maskCommand
            cmdVDown?.post(tap: .cghidEventTap)
            
            let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
            cmdVUp?.flags = .maskCommand
            cmdVUp?.post(tap: .cghidEventTap)
            
            // Restore previous clipboard after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let previous = previousContents {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }

        return .pasted
    }

    private static func copySelectedTextViaClipboard(completion: @escaping (String?) -> Void) {
        guard isAccessibilityEnabled() else {
            completion(nil)
            return
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        let cmdCDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: true) // C key
        cmdCDown?.flags = .maskCommand
        cmdCDown?.post(tap: .cghidEventTap)

        let cmdCUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: false)
        cmdCUp?.flags = .maskCommand
        cmdCUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let copiedText: String?
            if pasteboard.changeCount != previousChangeCount {
                copiedText = pasteboard.string(forType: .string)
            } else {
                copiedText = nil
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                if let previousContents, !previousContents.isEmpty {
                    pasteboard.setString(previousContents, forType: .string)
                }

                let normalized = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                completion((normalized?.isEmpty == false) ? normalized : nil)
            }
        }
    }
}
