import AVFoundation
import Foundation

@MainActor
final class AudioService: NSObject {
    weak var delegate: AudioServiceDelegate?

    private let inputDeviceManager = AudioInputDeviceManager()
    private let recorder = AudioRecordingController()
    private let playbackController = AudioPlaybackController()
    private let textToSpeechSynthesizer: AudioTextToSpeechSynthesizer
    private var synthesisTask: Task<Void, Never>?
    private var playbackGeneration = UUID()

    init(textToSpeechSynthesizer: AudioTextToSpeechSynthesizer? = nil) {
        self.textToSpeechSynthesizer = textToSpeechSynthesizer ?? AudioTextToSpeechSynthesizer()
        super.init()
        wireDelegates()
    }

    static func requestMicrophonePermission(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        AudioInputDeviceManager.requestMicrophonePermission(completion: completion)
    }

    func availableInputDevices() -> [AudioInputDevice] {
        inputDeviceManager.availableInputDevices()
    }

    func selectedInputDeviceID() -> String? {
        inputDeviceManager.selectedInputDeviceID()
    }

    func selectedInputDevice() -> AudioInputDevice? {
        inputDeviceManager.selectedInputDevice()
    }

    func activeInputDevice() -> AudioInputDevice? {
        inputDeviceManager.activeInputDevice()
    }

    func activeInputDeviceName() -> String {
        inputDeviceManager.activeInputDeviceName()
    }

    func activeInputDeviceConnectionHint() -> String? {
        inputDeviceManager.activeInputDeviceConnectionHint()
    }

    func systemDefaultInputDeviceName() -> String {
        inputDeviceManager.systemDefaultInputDeviceName()
    }

    func selectInputDevice(id: String?) {
        inputDeviceManager.selectInputDevice(id: id)
    }

    func selectedTTSEngine() -> TTSEngine {
        textToSpeechSynthesizer.selectedTTSEngine()
    }

    func selectTTSEngine(_ engine: TTSEngine) {
        textToSpeechSynthesizer.selectTTSEngine(engine)
    }

    func ttsEngineAvailabilitySummary() -> String {
        textToSpeechSynthesizer.ttsEngineAvailabilitySummary()
    }

    func startRecording(completion: @escaping @MainActor @Sendable (Result<Void, AudioRecordingIssue>) -> Void) {
        guard let device = inputDeviceManager.resolvedCaptureDevice() else {
            print("❌ No input device available")
            completion(.failure(.unavailableInput))
            return
        }

        recorder.startRecording(device: device, completion: completion)
    }

    func stopRecording(
        completion: @escaping @MainActor @Sendable (Result<AudioRecordingOutcome, AudioRecordingIssue>) -> Void
    ) {
        recorder.stopRecording(completion: completion)
    }

    func cancelRecording() {
        recorder.cancelRecording()
    }

    func playTextToSpeech(text: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let speechText = AudioTextNormalizer.normalizedSpeechText(from: text)
        guard !speechText.isEmpty else {
            completion(false)
            return
        }

        delegate?.audioServiceDidBeginPreparingPlayback(self)

        synthesisTask?.cancel()
        _ = textToSpeechSynthesizer.cancelFileSynthesis()
        playbackGeneration = UUID()
        let generation = playbackGeneration
        synthesisTask = Task { [weak self, speechText] in
            guard let self else { return }
            do {
                let audioURL = try await self.textToSpeechSynthesizer.synthesizeTextToAudio(text: speechText)
                guard generation == self.playbackGeneration, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: audioURL)
                    return
                }
                self.synthesisTask = nil
                let started = self.playbackController.playGeneratedAudio(url: audioURL)
                if !started { try? FileManager.default.removeItem(at: audioURL) }
                completion(started)
            } catch {
                guard generation == self.playbackGeneration, !Task.isCancelled else { return }
                self.synthesisTask = nil
                print("❌ Speech generation failed: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    func stopPlayback() {
        playbackGeneration = UUID()
        let wasSynthesizing = synthesisTask != nil
        synthesisTask?.cancel()
        synthesisTask = nil
        let didCancelFileSynthesis = textToSpeechSynthesizer.cancelFileSynthesis()
        playbackController.stop()
        if wasSynthesizing || didCancelFileSynthesis {
            delegate?.audioServiceDidFinishPlayback(self)
        }
    }

    func seekPlayback(by delta: TimeInterval) {
        DispatchQueue.main.async {
            self.playbackController.seekPlayback(by: delta)
        }
    }

    func seekPlayback(to time: TimeInterval) {
        DispatchQueue.main.async {
            self.playbackController.seekPlayback(to: time)
        }
    }

    func togglePlaybackPaused() {
        DispatchQueue.main.async {
            self.playbackController.togglePlaybackPaused()
        }
    }

    private func wireDelegates() {
        recorder.onWaveform = { [weak self] data in
            guard let self else { return }
            self.delegate?.audioService(self, didUpdateWaveform: data)
        }

        recorder.onStateChange = { [weak self] state in
            guard let self else { return }
            self.delegate?.audioService(self, didUpdateRecordingState: state)
        }

        playbackController.onStartPlayback = { [weak self] duration in
            guard let self else { return }
            self.delegate?.audioService(self, didStartPlaybackWithDuration: duration)
        }

        playbackController.onUpdatePlaybackPosition = { [weak self] currentTime, duration, isPlaying in
            guard let self else { return }
            self.delegate?.audioService(
                self,
                didUpdatePlaybackPosition: currentTime,
                duration: duration,
                isPlaying: isPlaying
            )
        }

        playbackController.onFinishPlayback = { [weak self] in
            guard let self else { return }
            self.delegate?.audioServiceDidFinishPlayback(self)
        }
    }
}
