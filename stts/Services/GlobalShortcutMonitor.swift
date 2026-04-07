import Cocoa
import Carbon

struct ShortcutOption: Equatable {
    let keyCode: UInt32
    let title: String
}

private final class CarbonEventHandler: NSObject {
    static let shared = CarbonEventHandler()

    var onShortcutPressed: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    func install(keyCode: UInt32) {
        uninstall()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                CarbonEventHandler.shared.handleEvent(event)
            },
            1,
            &eventSpec,
            nil,
            &handler
        )

        guard installStatus == noErr else {
            print("Failed to install event handler: \(installStatus)")
            return
        }
        eventHandler = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x53545453), id: 1)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if registerStatus == noErr {
            hotKeyRef = ref
        } else {
            print("Failed to register hot key: \(registerStatus)")
        }
    }

    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleEvent(_ event: EventRef?) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        if status == noErr && hotKeyID.signature == OSType(0x53545453) {
            DispatchQueue.main.async { [weak self] in
                self?.onShortcutPressed?()
            }
        }

        return noErr
    }
}

final class GlobalShortcutMonitor {
    private let selectedShortcutKey = "selectedShortcutKeyCode"

    var onShortcutPressed: (() -> Void)? {
        didSet {
            CarbonEventHandler.shared.onShortcutPressed = onShortcutPressed
        }
    }

    func availableShortcuts() -> [ShortcutOption] {
        [
            ShortcutOption(keyCode: UInt32(kVK_F1), title: "F1"),
            ShortcutOption(keyCode: UInt32(kVK_F2), title: "F2"),
            ShortcutOption(keyCode: UInt32(kVK_F3), title: "F3"),
            ShortcutOption(keyCode: UInt32(kVK_F4), title: "F4"),
            ShortcutOption(keyCode: UInt32(kVK_F5), title: "F5"),
            ShortcutOption(keyCode: UInt32(kVK_F6), title: "F6"),
            ShortcutOption(keyCode: UInt32(kVK_F7), title: "F7"),
            ShortcutOption(keyCode: UInt32(kVK_F8), title: "F8"),
            ShortcutOption(keyCode: UInt32(kVK_F9), title: "F9"),
            ShortcutOption(keyCode: UInt32(kVK_F10), title: "F10"),
            ShortcutOption(keyCode: UInt32(kVK_F11), title: "F11"),
            ShortcutOption(keyCode: UInt32(kVK_F12), title: "F12")
        ]
    }

    func currentShortcut() -> ShortcutOption {
        let storedValue = UserDefaults.standard.object(forKey: selectedShortcutKey)
        let storedCode = storedValue.map { _ in UInt32(UserDefaults.standard.integer(forKey: selectedShortcutKey)) }

        if let storedCode,
           let shortcut = availableShortcuts().first(where: { $0.keyCode == storedCode }) {
            return shortcut
        }

        return ShortcutOption(keyCode: UInt32(kVK_F12), title: "F12")
    }

    func updateShortcut(keyCode: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: selectedShortcutKey)
        restart()
    }

    func start() {
        CarbonEventHandler.shared.onShortcutPressed = onShortcutPressed
        CarbonEventHandler.shared.install(keyCode: currentShortcut().keyCode)
    }

    func stop() {
        CarbonEventHandler.shared.uninstall()
    }

    private func restart() {
        stop()
        start()
    }
}
