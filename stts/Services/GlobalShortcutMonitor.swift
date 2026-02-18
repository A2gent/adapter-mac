import Cocoa
import Carbon

class GlobalShortcutMonitor {
    var onShortcutPressed: (() -> Void)?
    private var eventHandler: EventHandlerRef?
    private var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    private var hotKeyID = EventHotKeyID(signature: OSType(0x53545453), id: 1) // 'STTS'
    private var hotKeyRef: EventHotKeyRef?
    
    func start() {
        // Install event handler
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (nextHandler, event, userData) -> OSStatus in
                let monitor = unsafeBitCast(userData, to: GlobalShortcutMonitor.self)
                monitor.onShortcutPressed?()
                return noErr
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handler
        )
        
        if status == noErr {
            eventHandler = handler
        }
        
        // Register F12 as hot key (keyCode 111)
        registerHotKey(keyCode: 111, modifiers: 0)
    }
    
    func stop() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
    
    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        
        if status == noErr {
            hotKeyRef = ref
        } else {
            print("Failed to register hot key: \(status)")
        }
    }
}
