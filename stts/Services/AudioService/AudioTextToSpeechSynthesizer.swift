import AppKit
import Foundation

final class AudioTextToSpeechSynthesizer: NSObject {
    private let selectedTTSEngineKey = "selectedTTSEngine"
    private let edgeVoice = "en-US-EmmaMultilingualNeural"
    private let edgeRate = "+0%"
    private let edgePitch = "+0Hz"

    private var fileSpeechSynthesizer: NSSpeechSynthesizer?
    private var fileSpeechCompletion: ((Bool) -> Void)?
    private var fileSpeechOutputURL: URL?

    func selectedTTSEngine() -> TTSEngine {
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

    func synthesizeTextToAudio(text: String) -> URL? {
        switch selectedTTSEngine() {
        case .automatic:
            if let audioURL = synthesizeWithEdgeIfAvailable(text: text) {
                return audioURL
            }

            return synthesizeWithSystemVoice(text: text)
        case .system:
            return synthesizeWithSystemVoice(text: text)
        case .edge:
            return synthesizeWithEdgeIfAvailable(text: text) ?? synthesizeWithSystemVoice(text: text)
        }
    }

    func cancelFileSynthesis() -> Bool {
        guard let synthesizer = fileSpeechSynthesizer, synthesizer.isSpeaking else {
            fileSpeechSynthesizer = nil
            fileSpeechCompletion = nil
            fileSpeechOutputURL = nil
            return false
        }

        synthesizer.stopSpeaking()
        fileSpeechSynthesizer = nil
        let pendingCompletion = fileSpeechCompletion
        fileSpeechCompletion = nil
        fileSpeechOutputURL = nil
        pendingCompletion?(false)
        return true
    }

    private func synthesizeWithSystemVoice(text: String) -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter_mac_tts_\(UUID().uuidString).aiff")

        let semaphore = DispatchSemaphore(value: 0)
        var didFinishSuccessfully = false

        DispatchQueue.main.async {
            self.fileSpeechOutputURL = outputURL
            self.fileSpeechCompletion = { success in
                didFinishSuccessfully = success
                semaphore.signal()
            }

            let synthesizer = NSSpeechSynthesizer(
                voice: NSSpeechSynthesizer.VoiceName(rawValue: "com.apple.speech.synthesis.voice.Alex")
            )
            synthesizer?.delegate = self
            self.fileSpeechSynthesizer = synthesizer

            guard let synthesizer, synthesizer.startSpeaking(text, to: outputURL) else {
                self.fileSpeechSynthesizer = nil
                self.fileSpeechOutputURL = nil
                let completion = self.fileSpeechCompletion
                self.fileSpeechCompletion = nil
                completion?(false)
                return
            }
        }

        _ = semaphore.wait(timeout: .now() + 300)

        guard didFinishSuccessfully,
              (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        return outputURL
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

extension AudioTextToSpeechSynthesizer: NSSpeechSynthesizerDelegate {
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        let completion = fileSpeechCompletion
        fileSpeechCompletion = nil
        fileSpeechSynthesizer = nil
        fileSpeechOutputURL = nil
        completion?(finishedSpeaking)
    }
}
