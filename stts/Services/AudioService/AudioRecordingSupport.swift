import Foundation

struct AudioRecordingAnalysis: Equatable {
    let duration: TimeInterval
    let fileSizeBytes: Int64
    let averageLevel: Float
    let peakLevel: Float
    let hadAudioSamples: Bool
    let waveformSampleCount: Int
}

enum AudioRecordingIssue: Error, Equatable {
    case unavailableInput
    case failedToStart
    case noCapturedAudio
    case tooShort
    case noSpeechDetected

    var userMessage: String {
        switch self {
        case .unavailableInput:
            return "The selected microphone is unavailable. Reconnect it or switch to System Default."
        case .failedToStart:
            return "Failed to start recording. Check microphone permission and device connection."
        case .noCapturedAudio:
            return "No audio was captured. Check the selected microphone connection and try again."
        case .tooShort:
            return "Recording was too short. Hold the shortcut a bit longer before releasing."
        case .noSpeechDetected:
            return "No speech was detected. Check the selected microphone connection and try again."
        }
    }
}

enum AudioRecordingValidationResult: Equatable {
    case success
    case failure(AudioRecordingIssue)
}

enum AudioInputConnectionKind: String, Equatable {
    case builtIn
    case bluetooth
    case continuity
    case external
    case unknown
}

struct AudioInputDeviceDescriptor: Equatable {
    let id: String
    let name: String
    let isDefault: Bool
    let connectionKind: AudioInputConnectionKind

    var connectionHint: String? {
        Self.connectionHint(for: connectionKind)
    }

    static func classify(name: String) -> AudioInputConnectionKind {
        let loweredName = name.lowercased()

        if loweredName.contains("iphone") || loweredName.contains("continuity") {
            return .continuity
        }

        if loweredName.contains("airpods") || loweredName.contains("bluetooth") || loweredName.contains("beats") {
            return .bluetooth
        }

        if loweredName.contains("macbook") || loweredName.contains("built-in") || loweredName.contains("builtin") {
            return .builtIn
        }

        if loweredName.contains("usb") || loweredName.contains("external") || loweredName.contains("webcam") || loweredName.contains("headset") {
            return .external
        }

        return .unknown
    }

    static func connectionHint(for connectionKind: AudioInputConnectionKind) -> String? {
        switch connectionKind {
        case .continuity:
            return "Continuity microphone detected. Keep the iPhone nearby, unlocked, and with Continuity Camera available."
        case .bluetooth:
            return "Bluetooth microphone detected. If audio drops out, reconnect it or switch to Built-in Microphone."
        case .builtIn, .external, .unknown:
            return nil
        }
    }
}

enum AudioRecordingValidator {
    private static let minimumDuration: TimeInterval = 0.35
    private static let minimumAverageSpeechLevel: Float = 0.008
    private static let minimumPeakSpeechLevel: Float = 0.02
    private static let minimumUsefulFileSizeBytes: Int64 = 4_096

    static func validate(_ analysis: AudioRecordingAnalysis) -> AudioRecordingValidationResult {
        guard analysis.hadAudioSamples,
              analysis.waveformSampleCount > 0,
              analysis.fileSizeBytes >= minimumUsefulFileSizeBytes else {
            return .failure(.noCapturedAudio)
        }

        guard analysis.duration >= minimumDuration else {
            return .failure(.tooShort)
        }

        let hasSpeechLikeSignal = analysis.averageLevel >= minimumAverageSpeechLevel || analysis.peakLevel >= minimumPeakSpeechLevel
        guard hasSpeechLikeSignal else {
            return .failure(.noSpeechDetected)
        }

        return .success
    }
}

enum AudioRecordingState: Equatable {
    case idle
    case preparing(deviceName: String, hint: String?)
    case recording(deviceName: String, hint: String?)
    case finishing
    case transcribing
    case startingBruteSession
    case failed(AudioRecordingIssue)

    var statusText: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Connecting microphone..."
        case .recording:
            return "Recording"
        case .finishing:
            return "Finalizing recording..."
        case .transcribing:
            return "Transcribing audio..."
        case .startingBruteSession:
            return "Starting brute session..."
        case .failed(let issue):
            return issue.userMessage
        }
    }
}

struct AudioRecordingOutcome {
    let fileURL: URL
    let analysis: AudioRecordingAnalysis
}
