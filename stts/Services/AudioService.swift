import Foundation
import AppKit
import AVFoundation

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

final class AudioService: NSObject {
    weak var delegate: AudioServiceDelegate?

    private let selectedMicrophoneIDKey = "selectedMicrophoneID"
    private let sessionQueue = DispatchQueue(label: "com.a2gent.parselton.audio.session")
    private let captureQueue = DispatchQueue(label: "com.a2gent.parselton.audio.capture")

    private var captureSession: AVCaptureSession?
    private var captureInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var speechSynthesizer: AVSpeechSynthesizer?
    private var audioPlayer: AVAudioPlayer?
    private var externalPlaybackURL: URL?
    private var playbackTimer: Timer?
    private var fileSpeechSynthesizer: NSSpeechSynthesizer?
    private var fileSpeechCompletion: ((Bool) -> Void)?
    private var fileSpeechOutputURL: URL?

    private var waveformData: [Float] = []
    private var isRecording = false

    private let edgeVoice = "en-US-EmmaMultilingualNeural"
    private let edgeRate = "+0%"
    private let edgePitch = "+0Hz"

    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func captureDevices() -> [AVCaptureDevice] {
        return AVCaptureDevice.devices(for: .audio)
    }

    func availableInputDevices() -> [AudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID

        return captureDevices()
            .map { device in
                AudioInputDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func selectedInputDeviceID() -> String? {
        let storedID = UserDefaults.standard.string(forKey: selectedMicrophoneIDKey)
        guard let storedID else { return nil }

        let exists = availableInputDevices().contains { $0.id == storedID }
        return exists ? storedID : nil
    }

    func selectedInputDevice() -> AudioInputDevice? {
        guard let selectedID = selectedInputDeviceID() else { return nil }
        return availableInputDevices().first { $0.id == selectedID }
    }

    func activeInputDevice() -> AudioInputDevice? {
        if let selected = selectedInputDevice() {
            return selected
        }

        guard let defaultDevice = availableInputDevices().first(where: \.isDefault) else {
            return availableInputDevices().first
        }

        return defaultDevice
    }

    func activeInputDeviceName() -> String {
        activeInputDevice()?.name ?? "No microphone"
    }

    func systemDefaultInputDeviceName() -> String {
        if let systemDefault = availableInputDevices().first(where: \.isDefault) {
            return systemDefault.name
        }

        return activeInputDeviceName()
    }

    func selectInputDevice(id: String?) {
        if let id, availableInputDevices().contains(where: { $0.id == id }) {
            UserDefaults.standard.set(id, forKey: selectedMicrophoneIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedMicrophoneIDKey)
        }
    }

    // MARK: - Recording

    func startRecording(completion: @escaping (Bool) -> Void) {
        guard !isRecording else {
            print("Already recording")
            completion(false)
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("❌ Microphone permission not granted")
            completion(false)
            return
        }

        guard let device = resolvedCaptureDevice() else {
            print("❌ No input device available")
            completion(false)
            return
        }

        waveformData.removeAll()

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.teardownCaptureSession(cancelWriter: true)

            do {
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()

                guard session.canAddInput(input), session.canAddOutput(output) else {
                    print("❌ Failed to attach selected microphone to capture session")
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")

                let writer = try AVAssetWriter(outputURL: tempURL, fileType: .m4a)
                let writerSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000
                ]
                let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
                writerInput.expectsMediaDataInRealTime = true

                guard writer.canAdd(writerInput) else {
                    print("❌ Failed to configure audio writer")
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }

                writer.add(writerInput)

                session.beginConfiguration()
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()

                output.setSampleBufferDelegate(self, queue: self.captureQueue)

                self.captureSession = session
                self.captureInput = input
                self.audioOutput = output
                self.assetWriter = writer
                self.assetWriterInput = writerInput
                self.recordingURL = tempURL
                self.isRecording = true

                session.startRunning()

                print("📱 Input device: \(device.localizedName)")
                print("✅ Recording started")

                DispatchQueue.main.async {
                    completion(true)
                }
            } catch {
                print("❌ Failed to start capture session: \(error)")
                self.teardownCaptureSession(cancelWriter: true)
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.isRecording = false

            self.audioOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.captureSession?.stopRunning()

            let writer = self.assetWriter
            let writerInput = self.assetWriterInput
            let fileURL = self.recordingURL

            self.captureSession = nil
            self.captureInput = nil
            self.audioOutput = nil
            self.assetWriter = nil
            self.assetWriterInput = nil
            self.recordingURL = nil

            guard let writer else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            switch writer.status {
            case .unknown:
                writer.cancelWriting()
                print("🛑 Recording stopped: no audio captured")
                DispatchQueue.main.async {
                    completion(nil)
                }
            case .writing:
                writerInput?.markAsFinished()
                writer.finishWriting {
                    let success = writer.status == .completed ? fileURL : nil
                    print("🛑 Recording stopped: \(success?.path ?? "no file")")
                    DispatchQueue.main.async {
                        completion(success)
                    }
                }
            case .completed:
                print("🛑 Recording stopped: \(fileURL?.path ?? "no file")")
                DispatchQueue.main.async {
                    completion(fileURL)
                }
            default:
                print("❌ Writer failed while stopping: \(writer.error?.localizedDescription ?? "unknown error")")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    private func resolvedCaptureDevice() -> AVCaptureDevice? {
        if let selectedID = selectedInputDeviceID(),
           let selectedDevice = captureDevices().first(where: { $0.uniqueID == selectedID }) {
            return selectedDevice
        }

        return AVCaptureDevice.default(for: .audio) ?? captureDevices().first
    }

    private func teardownCaptureSession(cancelWriter: Bool) {
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureSession?.stopRunning()
        captureSession = nil
        captureInput = nil
        audioOutput = nil

        if cancelWriter {
            assetWriterInput = nil
            if let writer = assetWriter, writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
            assetWriter = nil
            recordingURL = nil
        }
    }

    // MARK: - Text to Speech

    func playTextToSpeech(text: String, completion: @escaping (Bool) -> Void) {
        let speechText = normalizedSpeechText(from: text)
        guard !speechText.isEmpty else {
            completion(false)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioServiceDidBeginPreparingPlayback(self)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let audioURL = self.synthesizeTextToAudio(text: speechText) {
                DispatchQueue.main.async {
                    if self.playExternalAudio(url: audioURL) {
                        completion(true)
                    } else {
                        self.cleanupExternalPlaybackFile()
                        completion(false)
                    }
                }
                return
            }

            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func stopPlayback() {
        DispatchQueue.main.async {
            if let fileSpeechSynthesizer = self.fileSpeechSynthesizer, fileSpeechSynthesizer.isSpeaking {
                fileSpeechSynthesizer.stopSpeaking()
            }
            self.fileSpeechSynthesizer = nil
            let pendingCompletion = self.fileSpeechCompletion
            self.fileSpeechCompletion = nil
            self.fileSpeechOutputURL = nil
            self.audioPlayer?.stop()
            self.audioPlayer = nil
            self.stopPlaybackTimer()
            self.cleanupExternalPlaybackFile()
            pendingCompletion?(false)
            self.delegate?.audioServiceDidFinishPlayback(self)
        }
    }

    func seekPlayback(by delta: TimeInterval) {
        DispatchQueue.main.async {
            guard let player = self.audioPlayer else { return }
            let duration = max(player.duration, 0)
            let nextTime = min(max(0, player.currentTime + delta), duration)
            player.currentTime = nextTime
            self.emitPlaybackPosition(isPlaying: player.isPlaying)
        }
    }

    func seekPlayback(to time: TimeInterval) {
        DispatchQueue.main.async {
            guard let player = self.audioPlayer else { return }
            let duration = max(player.duration, 0)
            player.currentTime = min(max(0, time), duration)
            self.emitPlaybackPosition(isPlaying: player.isPlaying)
        }
    }

    func togglePlaybackPaused() {
        DispatchQueue.main.async {
            guard let player = self.audioPlayer else { return }

            if player.isPlaying {
                player.pause()
                self.stopPlaybackTimer()
            } else {
                guard player.play() else { return }
                self.startPlaybackTimer()
            }

            self.emitPlaybackPosition(isPlaying: player.isPlaying)
        }
    }

    private func synthesizeTextToAudio(text: String) -> URL? {
        if let audioURL = synthesizeWithEdgeIfAvailable(text: text) {
            return audioURL
        }

        return synthesizeWithSystemVoice(text: text)
    }

    private func synthesizeWithSystemVoice(text: String) -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parselton_tts_\(UUID().uuidString).aiff")

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
        let inputURL = tempDir.appendingPathComponent("parselton_tts_\(UUID().uuidString).txt")
        let outputURL = tempDir.appendingPathComponent("parselton_tts_\(UUID().uuidString).mp3")

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

    private func playExternalAudio(url: URL) -> Bool {
        do {
            speechSynthesizer?.stopSpeaking(at: .immediate)
            audioPlayer?.stop()
            stopPlaybackTimer()
            cleanupExternalPlaybackFile()

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()

            guard player.play() else {
                return false
            }

            audioPlayer = player
            externalPlaybackURL = url
            startPlaybackTimer()
            delegate?.audioService(self, didStartPlaybackWithDuration: player.duration)
            emitPlaybackPosition(isPlaying: true)
            return true
        } catch {
            print("❌ Failed to play generated audio: \(error)")
            return false
        }
    }

    private func cleanupExternalPlaybackFile() {
        if let url = externalPlaybackURL {
            try? FileManager.default.removeItem(at: url)
        }
        externalPlaybackURL = nil
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.emitCurrentPlaybackPosition()
        }
        if let playbackTimer {
            RunLoop.main.add(playbackTimer, forMode: .common)
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func emitCurrentPlaybackPosition() {
        guard let player = audioPlayer else { return }
        emitPlaybackPosition(isPlaying: player.isPlaying)
    }

    private func emitPlaybackPosition(isPlaying: Bool) {
        guard let player = audioPlayer else { return }
        delegate?.audioService(
            self,
            didUpdatePlaybackPosition: player.currentTime,
            duration: player.duration,
            isPlaying: isPlaying
        )
    }

    private func normalizedSpeechText(from text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "" }

        output = stripMarkdownTables(from: output)
        output = addHeadingPauses(to: output)
        output = replacing(output, pattern: "(?s)```.*?```", with: " ")
        output = replacing(output, pattern: "`[^`]*`", with: " ")
        output = replacing(output, pattern: "!\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1")
        output = replacing(output, pattern: "\\[([^\\]]+)\\]\\([^\\)]*\\)", with: "$1")
        output = replacing(output, pattern: "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", with: "$2")
        output = replacing(output, pattern: "\\[\\[([^\\]]+)\\]\\]", with: "$1")
        output = replaceURLsWithDomainSpeech(in: output)
        output = replacing(output, pattern: "(?m)^\\s{0,3}#{1,6}\\s*", with: "")
        output = replacing(output, pattern: "(?m)^\\s*([-*+]|\\d+\\.)\\s+", with: "")
        output = output
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "<!--truncate-->", with: " ")
        output = stripEmojiLikeScalars(from: output)
        output = replacing(output, pattern: "(?s)<[^>]*>", with: " ")
        output = replacing(output, pattern: "\\s+", with: " ")

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private func addHeadingPauses(to markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("#") else {
                    return String(line)
                }

                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !heading.isEmpty else { return "" }
                return "\n\n\(heading).\n\n"
            }
            .joined(separator: "\n")
    }

    private func stripMarkdownTables(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0

        while index < lines.count {
            if index + 1 < lines.count,
               looksLikeTableHeader(lines[index]),
               isMarkdownTableSeparatorLine(lines[index + 1]) {
                index += 2
                while index < lines.count {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || !trimmed.contains("|") {
                        index -= 1
                        break
                    }
                    index += 1
                }
            } else {
                output.append(lines[index])
            }
            index += 1
        }

        return output.joined(separator: "\n")
    }

    private func looksLikeTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.contains("|")
    }

    private func isMarkdownTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("-"), trimmed.contains("|") else {
            return false
        }

        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        var validColumnCount = 0

        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if cell.isEmpty {
                continue
            }

            guard let regex = try? NSRegularExpression(pattern: "^:?-{3,}:?$") else {
                return false
            }
            let range = NSRange(cell.startIndex..., in: cell)
            guard regex.firstMatch(in: cell, options: [], range: range) != nil else {
                return false
            }
            validColumnCount += 1
        }

        return validColumnCount >= 2
    }

    private func replaceURLsWithDomainSpeech(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:https?|ftp)://[^\s<>()]+|\bwww\.[^\s<>()]+"#, options: []) else {
            return text
        }

        return regex.replaceMatches(in: text)
    }

    private func stripEmojiLikeScalars(from text: String) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .otherSymbol, .modifierSymbol, .surrogate, .privateUse:
                return false
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(filtered))
    }
}

extension AudioService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioPlayer = nil
        stopPlaybackTimer()
        cleanupExternalPlaybackFile()
        delegate?.audioServiceDidFinishPlayback(self)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error {
            print("❌ Audio decode error: \(error)")
        }
        audioPlayer = nil
        stopPlaybackTimer()
        cleanupExternalPlaybackFile()
        delegate?.audioServiceDidFinishPlayback(self)
    }
}

extension AudioService: NSSpeechSynthesizerDelegate {
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        let completion = fileSpeechCompletion
        fileSpeechCompletion = nil
        fileSpeechSynthesizer = nil
        fileSpeechOutputURL = nil
        completion?(finishedSpeaking)
    }
}

private extension NSRegularExpression {
    func replaceMatches(in text: String) -> String {
        let matches = self.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }

            let raw = String(result[range])
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}\"'"))
            let replacement: String

            if trimmed.isEmpty {
                replacement = " "
            } else {
                let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://\(trimmed)" : trimmed
                if let url = URL(string: candidate), let host = url.host, !host.isEmpty {
                    replacement = " link to \(host.lowercased()) "
                } else {
                    replacement = " link "
                }
            }

            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

extension AudioService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording,
              let writer = assetWriter,
              let writerInput = assetWriterInput else {
            return
        }

        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }

        if writer.status == .writing, writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }

        updateWaveform(from: sampleBuffer)
    }

    private func updateWaveform(from sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr,
              let buffer = UnsafeMutableAudioBufferListPointer(&audioBufferList).first,
              let data = buffer.mData else {
            return
        }

        let rms: Float
        let isFloat = (streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        if isFloat {
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }

            let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
            var sum: Float = 0
            for index in 0..<sampleCount {
                let sample = samples[index]
                sum += sample * sample
            }
            rms = sqrt(sum / Float(sampleCount))
        } else {
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return }

            let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
            var sum: Float = 0
            for index in 0..<sampleCount {
                let sample = Float(samples[index]) / Float(Int16.max)
                sum += sample * sample
            }
            rms = sqrt(sum / Float(sampleCount))
        }

        let normalizedLevel = normalizedWaveformLevel(from: rms)
        let delegate = delegate
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }

            self.waveformData.append(normalizedLevel)
            if self.waveformData.count > 100 {
                self.waveformData.removeFirst()
            }

            delegate?.audioService(self, didUpdateWaveform: self.waveformData)
        }
    }

    private func normalizedWaveformLevel(from rms: Float) -> Float {
        let noiseFloor: Float = 0.008
        let ceiling: Float = 0.12
        let clamped = max(0, min(1, (rms - noiseFloor) / (ceiling - noiseFloor)))

        // Lift quiet speech while keeping louder sounds from pinning the meter.
        return pow(clamped, 0.5)
    }
}
