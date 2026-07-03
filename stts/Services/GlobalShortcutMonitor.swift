import Cocoa
import Carbon

private enum ShortcutEventKind {
    case keyDown
    case keyUp
}

enum ShortcutAction: Int, CaseIterable {
    case adapterMac = 1
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

@MainActor
private final class CarbonEventHandler: NSObject {
    static let shared = CarbonEventHandler()

    var onShortcutPressed: ((ShortcutAction) -> Void)?
    var onShortcutReleased: ((ShortcutAction) -> Void)?
    var onCancelRequested: (() -> Void)?

    private var pressedEventHandler: EventHandlerRef?
    private var releasedEventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyUpMonitor: Any?

    func install(shortcuts: [(action: ShortcutAction, shortcut: ShortcutOption)]) {
        uninstall()

        var pressedEventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var releasedEventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased)
        )

        var pressedHandler: EventHandlerRef?
        let pressedStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                CarbonEventHandler.shared.handleEvent(event, kind: .keyDown)
            },
            1,
            &pressedEventSpec,
            nil,
            &pressedHandler
        )

        guard pressedStatus == noErr else {
            print("Failed to install pressed event handler: \(pressedStatus)")
            return
        }
        pressedEventHandler = pressedHandler

        var releasedHandler: EventHandlerRef?
        let releasedStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                CarbonEventHandler.shared.handleEvent(event, kind: .keyUp)
            },
            1,
            &releasedEventSpec,
            nil,
            &releasedHandler
        )

        guard releasedStatus == noErr else {
            print("Failed to install released event handler: \(releasedStatus)")
            uninstall()
            return
        }
        releasedEventHandler = releasedHandler

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

        if let pressedEventHandler {
            RemoveEventHandler(pressedEventHandler)
            self.pressedEventHandler = nil
        }
        if let releasedEventHandler {
            RemoveEventHandler(releasedEventHandler)
            self.releasedEventHandler = nil
        }

        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
        if let globalKeyUpMonitor {
            NSEvent.removeMonitor(globalKeyUpMonitor)
            self.globalKeyUpMonitor = nil
        }
        if let localKeyUpMonitor {
            NSEvent.removeMonitor(localKeyUpMonitor)
            self.localKeyUpMonitor = nil
        }
    }

    private func handleEvent(_ event: EventRef?, kind: ShortcutEventKind) -> OSStatus {
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
                switch kind {
                case .keyDown:
                    self?.onShortcutPressed?(action)
                case .keyUp:
                    self?.onShortcutReleased?(action)
                }
            }
        }

        return noErr
    }

    private func installCancelMonitor() {
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCancelEvent(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCancelEvent(event)
            return event
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleCancelEvent(event)
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
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

@MainActor
final class GlobalShortcutMonitor {
    private let adapterMacShortcutKeyCode = "adapterMacShortcutKeyCode"
    private let adapterMacShortcutModifiers = "adapterMacShortcutModifiers"
    private let bruteSessionShortcutKeyCode = "bruteSessionShortcutKeyCode"
    private let bruteSessionShortcutModifiers = "bruteSessionShortcutModifiers"

    var onAdapterMacShortcutPressed: (() -> Void)? {
        didSet {
            refreshEventHandlerClosures()
        }
    }

    var onAdapterMacShortcutReleased: (() -> Void)? {
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

    nonisolated static func availableShortcutKeys() -> [ShortcutKeyOption] {
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

    nonisolated static func keyTitle(for keyCode: UInt32) -> String {
        availableShortcutKeys().first(where: { $0.keyCode == keyCode })?.title ?? "Key \(keyCode)"
    }

    nonisolated static func modifierTitles(for modifiers: UInt32) -> [String] {
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
            (.adapterMac, currentShortcut(for: .adapterMac)),
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
            case .adapterMac:
                self.onAdapterMacShortcutPressed?()
            case .bruteSession:
                self.onBruteSessionShortcutPressed?()
            }
        }
        CarbonEventHandler.shared.onShortcutReleased = { [weak self] action in
            guard let self else { return }
            switch action {
            case .adapterMac:
                self.onAdapterMacShortcutReleased?()
            case .bruteSession:
                break
            }
        }
    }

    private func storageKeys(for action: ShortcutAction) -> (String, String, ShortcutOption) {
        switch action {
        case .adapterMac:
            return (
                adapterMacShortcutKeyCode,
                adapterMacShortcutModifiers,
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
