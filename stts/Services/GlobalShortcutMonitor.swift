import Cocoa
import Carbon

enum ShortcutAction: Int, CaseIterable {
    case parselton = 1
    case bruteSession = 2
}

struct ShortcutKeyOption: Equatable {
    let keyCode: UInt32
    let title: String
}

struct ShortcutOption: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    var title: String {
        let keyTitle = GlobalShortcutMonitor.keyTitle(for: keyCode)
        let modifierTitles = GlobalShortcutMonitor.modifierTitles(for: modifiers)
        if modifierTitles.isEmpty {
            return keyTitle
        }
        return modifierTitles.joined(separator: "+") + "+" + keyTitle
    }
}

private final class CarbonEventHandler: NSObject {
    static let shared = CarbonEventHandler()

    var onShortcutPressed: ((ShortcutAction) -> Void)?
    var onCancelRequested: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func install(shortcuts: [(action: ShortcutAction, shortcut: ShortcutOption)]) {
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

        for registration in shortcuts {
            let hotKeyID = EventHotKeyID(signature: OSType(0x53545453), id: UInt32(registration.action.rawValue))
            var ref: EventHotKeyRef?
            let registerStatus = RegisterEventHotKey(
                registration.shortcut.keyCode,
                registration.shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if registerStatus == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                print("Failed to register hot key \(registration.shortcut.title): \(registerStatus)")
            }
        }

        installCancelMonitor()
    }

    func uninstall() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
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

        if status == noErr,
           hotKeyID.signature == OSType(0x53545453),
           let action = ShortcutAction(rawValue: Int(hotKeyID.id)) {
            DispatchQueue.main.async { [weak self] in
                self?.onShortcutPressed?(action)
            }
        }

        return noErr
    }

    private func installCancelMonitor() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCancelEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCancelEvent(event)
            return event
        }
    }

    private func handleCancelEvent(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Escape) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onCancelRequested?()
        }
    }
}

final class GlobalShortcutMonitor {
    private let parseltonShortcutKeyCode = "parseltonShortcutKeyCode"
    private let parseltonShortcutModifiers = "parseltonShortcutModifiers"
    private let bruteSessionShortcutKeyCode = "bruteSessionShortcutKeyCode"
    private let bruteSessionShortcutModifiers = "bruteSessionShortcutModifiers"

    var onParseltonShortcutPressed: (() -> Void)? {
        didSet {
            refreshEventHandlerClosures()
        }
    }

    var onBruteSessionShortcutPressed: (() -> Void)? {
        didSet {
            refreshEventHandlerClosures()
        }
    }

    var onCancelRequested: (() -> Void)? {
        didSet {
            CarbonEventHandler.shared.onCancelRequested = onCancelRequested
        }
    }

    static func availableShortcutKeys() -> [ShortcutKeyOption] {
        [
            ShortcutKeyOption(keyCode: UInt32(kVK_Space), title: "Space"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_A), title: "A"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_B), title: "B"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_C), title: "C"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_D), title: "D"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_E), title: "E"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_F), title: "F"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_G), title: "G"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_H), title: "H"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_I), title: "I"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_J), title: "J"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_K), title: "K"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_L), title: "L"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_M), title: "M"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_N), title: "N"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_O), title: "O"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_P), title: "P"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_Q), title: "Q"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_R), title: "R"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_S), title: "S"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_T), title: "T"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_U), title: "U"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_V), title: "V"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_W), title: "W"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_X), title: "X"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_Y), title: "Y"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_Z), title: "Z"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_0), title: "0"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_1), title: "1"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_2), title: "2"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_3), title: "3"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_4), title: "4"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_5), title: "5"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_6), title: "6"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_7), title: "7"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_8), title: "8"),
            ShortcutKeyOption(keyCode: UInt32(kVK_ANSI_9), title: "9"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F1), title: "F1"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F2), title: "F2"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F3), title: "F3"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F4), title: "F4"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F5), title: "F5"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F6), title: "F6"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F7), title: "F7"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F8), title: "F8"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F9), title: "F9"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F10), title: "F10"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F11), title: "F11"),
            ShortcutKeyOption(keyCode: UInt32(kVK_F12), title: "F12")
        ]
    }

    static func keyTitle(for keyCode: UInt32) -> String {
        availableShortcutKeys().first(where: { $0.keyCode == keyCode })?.title ?? "Key \(keyCode)"
    }

    static func modifierTitles(for modifiers: UInt32) -> [String] {
        var titles: [String] = []
        if modifiers & UInt32(cmdKey) != 0 {
            titles.append("Command")
        }
        if modifiers & UInt32(optionKey) != 0 {
            titles.append("Option")
        }
        if modifiers & UInt32(controlKey) != 0 {
            titles.append("Control")
        }
        if modifiers & UInt32(shiftKey) != 0 {
            titles.append("Shift")
        }
        return titles
    }

    func currentShortcut(for action: ShortcutAction) -> ShortcutOption {
        let (keyCodeKey, modifiersKey, fallback) = storageKeys(for: action)
        let defaults = UserDefaults.standard
        let hasStoredKey = defaults.object(forKey: keyCodeKey) != nil
        guard hasStoredKey else {
            return fallback
        }
        let storedKeyCode = UInt32(defaults.integer(forKey: keyCodeKey))
        let storedModifiers = UInt32(defaults.integer(forKey: modifiersKey))
        let isKnownKey = Self.availableShortcutKeys().contains(where: { $0.keyCode == storedKeyCode })
        return isKnownKey ? ShortcutOption(keyCode: storedKeyCode, modifiers: storedModifiers) : fallback
    }

    func updateShortcut(for action: ShortcutAction, shortcut: ShortcutOption) {
        let (keyCodeKey, modifiersKey, _) = storageKeys(for: action)
        UserDefaults.standard.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(shortcut.modifiers), forKey: modifiersKey)
        restart()
    }

    func start() {
        refreshEventHandlerClosures()
        CarbonEventHandler.shared.onCancelRequested = onCancelRequested
        CarbonEventHandler.shared.install(shortcuts: [
            (.parselton, currentShortcut(for: .parselton)),
            (.bruteSession, currentShortcut(for: .bruteSession)),
        ])
    }

    func stop() {
        CarbonEventHandler.shared.uninstall()
    }

    private func restart() {
        stop()
        start()
    }

    private func refreshEventHandlerClosures() {
        CarbonEventHandler.shared.onShortcutPressed = { [weak self] action in
            guard let self else { return }
            switch action {
            case .parselton:
                self.onParseltonShortcutPressed?()
            case .bruteSession:
                self.onBruteSessionShortcutPressed?()
            }
        }
    }

    private func storageKeys(for action: ShortcutAction) -> (String, String, ShortcutOption) {
        switch action {
        case .parselton:
            return (
                parseltonShortcutKeyCode,
                parseltonShortcutModifiers,
                ShortcutOption(keyCode: UInt32(kVK_F12), modifiers: 0)
            )
        case .bruteSession:
            return (
                bruteSessionShortcutKeyCode,
                bruteSessionShortcutModifiers,
                ShortcutOption(keyCode: UInt32(kVK_F11), modifiers: 0)
            )
        }
    }
}
