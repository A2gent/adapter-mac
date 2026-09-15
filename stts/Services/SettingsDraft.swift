import Foundation

struct SettingsDraft: Equatable {
    var inputDeviceID: String?
    var adapterShortcut: ShortcutOption
    var bruteShortcut: ShortcutOption
    var holdToRecord: Bool
    var provider: TranscriptionProviderOption
    var endpoint: String
    var ttsEngine: TTSEngine
    var voice = VoiceSettings()

    var validationMessage: String? {
        if let message = voice.validationMessage { return message }
        if adapterShortcut == bruteShortcut {
            return "Dictation and Brute session shortcuts must be different."
        }
        if provider == .bruteHTTP || voice.enabled {
            let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value),
                let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                let host = url.host, !host.isEmpty
            else {
                return "Enter a valid HTTP or HTTPS transcription URL."
            }
        }
        return nil
    }
}
