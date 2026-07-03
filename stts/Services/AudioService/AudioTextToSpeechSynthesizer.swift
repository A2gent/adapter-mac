import AVFoundation
import Foundation

@MainActor
final class AudioTextToSpeechSynthesizer: NSObject {
    private let selectedTTSEngineKey = "selectedTTSEngine"
    private let edgeVoice = "en-US-EmmaMultilingualNeural"
    private let edgeRate = "+0%"
    private let edgePitch = "+0Hz"

    private var fileSpeechSynthesizer: AVSpeechSynthesizer?
    private var fileSpeechCompletion: ((Bool) -> Void)?
    private var fileSpeechOutputURL: URL?
    private var didResumeFileSpeechCompletion = false

    nonisolated func selectedTTSEngine() -> TTSEngine {
        guard let rawValue = UserDefaults.standard.string(forKey: selectedTTSEngineKey),
              let engine = TTSEngine(rawValue: rawValue) else {
            return .automatic
        }

        return engine
    }

    func selectTTSEngine(_ engine: TTSEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: selectedTTSEngineKey)
    }

    func ttsEngineAvailabilitySummary() -> String {
        let availability = TTSEngine.allCases.map { engine in
            "\(engine.title): \(ttsEngineStatus(for: engine))"
        }

        return availability.joined(separator: " | ")
    }

    func synthesizeTextToAudio(text: String) async -> URL? {
        switch selectedTTSEngine() {
        case .automatic:
            if let audioURL = synthesizeWithEdgeIfAvailable(text: text) {
                return audioURL
            }

            return await synthesizeWithSystemVoice(text: text)
        case .system:
            return await synthesizeWithSystemVoice(text: text)
        case .edge:
            if let audioURL = synthesizeWithEdgeIfAvailable(text: text) {
                return audioURL
            }

            return await synthesizeWithSystemVoice(text: text)
        }
    }

    func cancelFileSynthesis() -> Bool {
        guard let synthesizer = fileSpeechSynthesizer, synthesizer.isSpeaking else {
            fileSpeechSynthesizer = nil
            fileSpeechCompletion = nil
            fileSpeechOutputURL = nil
            didResumeFileSpeechCompletion = false
            return false
        }

        synthesizer.stopSpeaking(at: .immediate)
        completeFileSpeech(success: false)
        return true
    }

    private func synthesizeWithSystemVoice(text: String) async -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter_mac_tts_\(UUID().uuidString).caf")

        return await withCheckedContinuation { continuation in
            var outputFile: AVAudioFile?
            var didWriteAudio = false
            var didFinish = false

            fileSpeechOutputURL = outputURL
            didResumeFileSpeechCompletion = false
            fileSpeechCompletion = { success in
                guard !didFinish else { return }
                didFinish = true
                continuation.resume(returning: success ? outputURL : nil)
            }

            let synthesizer = AVSpeechSynthesizer()
            fileSpeechSynthesizer = synthesizer

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    Task { @MainActor in
                        self?.completeFileSpeech(success: false)
                    }
                    return
                }

                guard pcmBuffer.frameLength > 0 else {
                    Task { @MainActor in
                        self?.completeFileSpeech(success: didWriteAudio)
                    }
                    return
                }

                do {
                    if outputFile == nil {
                        outputFile = try AVAudioFile(forWriting: outputURL, settings: pcmBuffer.format.settings)
                    }
                    try outputFile?.write(from: pcmBuffer)
                    didWriteAudio = true
                } catch {
                    print("❌ Failed to write system TTS audio: \(error)")
                    Task { @MainActor in
                        self?.completeFileSpeech(success: false)
                    }
                }
            }
        }
    }

    private func completeFileSpeech(success: Bool) {
        guard !didResumeFileSpeechCompletion else { return }
        didResumeFileSpeechCompletion = true

        let completion = fileSpeechCompletion
        let outputURL = fileSpeechOutputURL
        fileSpeechCompletion = nil
        fileSpeechSynthesizer = nil
        fileSpeechOutputURL = nil

        if !success, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }

        completion?(success)
    }

    private func synthesizeWithEdgeIfAvailable(text: String) -> URL? {
        guard let binaryURL = edgeBinaryURL() else {
            print("ℹ️ edge-tts not found, falling back to system speech")
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("adapter_mac_tts_\(UUID().uuidString).txt")
        let outputURL = tempDir.appendingPathComponent("adapter_mac_tts_\(UUID().uuidString).mp3")

        do {
            try text.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            print("❌ Failed to write TTS input file: \(error)")
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: inputURL)
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--voice", edgeVoice,
            "--rate", edgeRate,
            "--pitch", edgePitch,
            "--file", inputURL.path,
            "--write-media", outputURL.path
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("❌ Failed to run edge-tts: \(error)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData + outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            print("❌ edge-tts failed: \(message.isEmpty ? "unknown error" : message)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        guard (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else {
            print("❌ edge-tts did not produce audio output")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        return outputURL
    }

    private func edgeBinaryURL() -> URL? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirectories = envPath
            .split(separator: ":")
            .map(String.init)

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/Library/Python/3.9/bin",
            "\(homeDirectory)/Library/Python/3.10/bin",
            "\(homeDirectory)/Library/Python/3.11/bin",
            "\(homeDirectory)/Library/Python/3.12/bin",
            "\(homeDirectory)/Library/Python/3.13/bin"
        ]

        let allDirectories = Array(Set(pathDirectories + fallbackDirectories))
        for directory in allDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("edge-tts")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func ttsEngineStatus(for engine: TTSEngine) -> String {
        switch engine {
        case .automatic:
            return "prefers edge-tts, then system"
        case .system:
            return "available"
        case .edge:
            return edgeBinaryURL() == nil ? "not found" : "available"
        }
    }
}
