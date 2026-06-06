import Foundation

protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float])
    func audioServiceDidBeginPreparingPlayback(_ service: AudioService)
    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval)
    func audioService(_ service: AudioService, didUpdatePlaybackPosition currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool)
    func audioServiceDidFinishPlayback(_ service: AudioService)
}

extension AudioServiceDelegate {
    func audioServiceDidBeginPreparingPlayback(_ service: AudioService) {}
    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval) {}
    func audioService(_ service: AudioService, didUpdatePlaybackPosition currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {}
    func audioServiceDidFinishPlayback(_ service: AudioService) {}
}

struct AudioInputDevice: Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum TTSEngine: String, CaseIterable {
    case automatic
    case system
    case edge

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .system:
            return "System Voice"
        case .edge:
            return "edge-tts"
        }
    }
}
