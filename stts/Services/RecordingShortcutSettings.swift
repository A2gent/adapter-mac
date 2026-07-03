import Foundation

struct RecordingShortcutSettings {
    private static let holdToRecordEnabledKey = "adapterMacHoldToRecordEnabled"

    static var holdToRecordEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: holdToRecordEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: holdToRecordEnabledKey)
        }
    }
}

struct HoldToRecordGesture {
    let threshold: TimeInterval

    func shouldStopRecordingOnKeyUp(pressDuration: TimeInterval) -> Bool {
        pressDuration >= threshold
    }
}
