import Foundation

@MainActor
protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float])
    func audioService(_ service: AudioService, didUpdateRecordingState state: AudioRecordingState)
    func audioServiceDidBeginPreparingPlayback(_ service: AudioService)
    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval)
    func audioService(_ service: AudioService, didUpdatePlaybackPosition currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool)
    func audioServiceDidFinishPlayback(_ service: AudioService)
}

extension AudioServiceDelegate {
    func audioService(_ service: AudioService, didUpdateRecordingState state: AudioRecordingState) {}
    func audioServiceDidBeginPreparingPlayback(_ service: AudioService) {}
    func audioService(_ service: AudioService, didStartPlaybackWithDuration duration: TimeInterval) {}
    func audioService(_ service: AudioService, didUpdatePlaybackPosition currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {}
    func audioServiceDidFinishPlayback(_ service: AudioService) {}
}

struct AudioInputDevice: Equatable {
    let id: String
    let name: String
    let isDefault: Bool
    let connectionKind: AudioInputConnectionKind

    var connectionHint: String? {
        AudioInputDeviceDescriptor.connectionHint(for: connectionKind)
    }
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
