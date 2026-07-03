@preconcurrency import AVFoundation
import Foundation

// Recording state is coordinated by sessionQueue/captureQueue rather than MainActor.
// Swift cannot infer that queue confinement, so the controller opts into Sendable manually.
final class AudioRecordingController: NSObject, @unchecked Sendable {
    var onWaveform: (([Float]) -> Void)?
    var onStateChange: ((AudioRecordingState) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.a2gent.adapter-mac.audio.session")
    private let captureQueue = DispatchQueue(label: "com.a2gent.adapter-mac.audio.capture")

    private var captureSession: AVCaptureSession?
    private var captureInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var waveformData: [Float] = []
    private var isRecording = false

    private var recordingStartedAt: Date?
    private var waveformLevelSum: Float = 0
    private var waveformLevelPeak: Float = 0
    private var waveformSampleCount = 0
    private var hasCapturedAudioSamples = false

    func cancelRecording() {
        guard isRecording else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.emitState(.idle)
            self.teardownCaptureSession(cancelWriter: true)
            self.resetRecordingMetrics()
        }
    }

    func startRecording(device: AVCaptureDevice, completion: @escaping @MainActor @Sendable (Result<Void, AudioRecordingIssue>) -> Void) {
        guard !isRecording else {
            Task { @MainActor in
                completion(.failure(.failedToStart))
            }
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("❌ Microphone permission not granted")
            Task { @MainActor in
                completion(.failure(.failedToStart))
            }
            return
        }

        waveformData.removeAll()
        resetRecordingMetrics()
        emitState(.preparing(
            deviceName: device.localizedName,
            hint: AudioInputDeviceDescriptor.connectionHint(
                for: AudioInputDeviceDescriptor.classify(name: device.localizedName)
            )
        ))

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.teardownCaptureSession(cancelWriter: true)

            do {
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()

                guard session.canAddInput(input), session.canAddOutput(output) else {
                    print("❌ Failed to attach selected microphone to capture session")
                    self.emitState(.failed(.unavailableInput))
                    DispatchQueue.main.async {
                        completion(.failure(.unavailableInput))
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
                    self.emitState(.failed(.failedToStart))
                    DispatchQueue.main.async {
                        completion(.failure(.failedToStart))
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
                self.recordingStartedAt = Date()
                self.isRecording = true

                session.startRunning()

                print("📱 Input device: \(device.localizedName)")
                print("✅ Recording started")
                self.emitState(.recording(
                    deviceName: device.localizedName,
                    hint: AudioInputDeviceDescriptor.connectionHint(
                        for: AudioInputDeviceDescriptor.classify(name: device.localizedName)
                    )
                ))

                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                print("❌ Failed to start capture session: \(error)")
                self.teardownCaptureSession(cancelWriter: true)
                self.resetRecordingMetrics()
                self.emitState(.failed(.failedToStart))
                DispatchQueue.main.async {
                    completion(.failure(.failedToStart))
                }
            }
        }
    }

    func stopRecording(completion: @escaping @MainActor @Sendable (Result<AudioRecordingOutcome, AudioRecordingIssue>) -> Void) {
        guard isRecording else {
            Task { @MainActor in
                completion(.failure(.noCapturedAudio))
            }
            return
        }

        emitState(.finishing)

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.isRecording = false

            self.audioOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.captureSession?.stopRunning()

            let writer = self.assetWriter
            let writerInput = self.assetWriterInput
            let fileURL = self.recordingURL
            let analysis = self.makeRecordingAnalysis(fileURL: fileURL)

            self.captureSession = nil
            self.captureInput = nil
            self.audioOutput = nil
            self.assetWriter = nil
            self.assetWriterInput = nil
            self.recordingURL = nil

            guard let writer else {
                self.resetRecordingMetrics()
                self.emitState(.failed(.noCapturedAudio))
                DispatchQueue.main.async {
                    completion(.failure(.noCapturedAudio))
                }
                return
            }

            let finish: @Sendable (URL?) -> Void = { finalURL in
                let result = self.finalizeRecording(fileURL: finalURL, analysis: analysis)
                DispatchQueue.main.async {
                    completion(result)
                }
            }

            switch writer.status {
            case .unknown:
                writer.cancelWriting()
                print("🛑 Recording stopped: no audio captured")
                finish(nil)
            case .writing:
                writerInput?.markAsFinished()
                nonisolated(unsafe) let finishWriter = writer
                writer.finishWriting {
                    let successURL = finishWriter.status == .completed ? fileURL : nil
                    print("🛑 Recording stopped: \(successURL?.path ?? "no file")")
                    finish(successURL)
                }
            case .completed:
                print("🛑 Recording stopped: \(fileURL?.path ?? "no file")")
                finish(fileURL)
            default:
                print("❌ Writer failed while stopping: \(writer.error?.localizedDescription ?? "unknown error")")
                finish(nil)
            }
        }
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

    private func handleWaveformLevel(_ normalizedLevel: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }

            self.waveformLevelSum += normalizedLevel
            self.waveformLevelPeak = max(self.waveformLevelPeak, normalizedLevel)
            self.waveformSampleCount += 1

            self.waveformData.append(normalizedLevel)
            if self.waveformData.count > 100 {
                self.waveformData.removeFirst()
            }

            self.onWaveform?(self.waveformData)
        }
    }

    private func makeRecordingAnalysis(fileURL: URL?) -> AudioRecordingAnalysis {
        let duration = max(0, Date().timeIntervalSince(recordingStartedAt ?? Date()))
        let averageLevel = waveformSampleCount > 0 ? (waveformLevelSum / Float(waveformSampleCount)) : 0
        let fileSizeBytes = fileURL.flatMap { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        } ?? 0

        return AudioRecordingAnalysis(
            duration: duration,
            fileSizeBytes: fileSizeBytes,
            averageLevel: averageLevel,
            peakLevel: waveformLevelPeak,
            hadAudioSamples: hasCapturedAudioSamples,
            waveformSampleCount: waveformSampleCount
        )
    }

    private func finalizeRecording(fileURL: URL?, analysis: AudioRecordingAnalysis) -> Result<AudioRecordingOutcome, AudioRecordingIssue> {
        defer {
            resetRecordingMetrics()
        }

        guard let fileURL else {
            emitState(.failed(.noCapturedAudio))
            return .failure(.noCapturedAudio)
        }

        switch AudioRecordingValidator.validate(analysis) {
        case .success:
            emitState(.idle)
            return .success(AudioRecordingOutcome(fileURL: fileURL, analysis: analysis))
        case .failure(let issue):
            try? FileManager.default.removeItem(at: fileURL)
            emitState(.failed(issue))
            return .failure(issue)
        }
    }

    private func resetRecordingMetrics() {
        recordingStartedAt = nil
        waveformLevelSum = 0
        waveformLevelPeak = 0
        waveformSampleCount = 0
        hasCapturedAudioSamples = false
    }

    private func emitState(_ state: AudioRecordingState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }
}

extension AudioRecordingController: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording,
              let writer = assetWriter,
              let writerInput = assetWriterInput else {
            return
        }

        hasCapturedAudioSamples = true

        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }

        if writer.status == .writing, writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }

        guard let normalizedLevel = AudioWaveformExtractor.normalizedLevel(from: sampleBuffer) else {
            return
        }
        handleWaveformLevel(normalizedLevel)
    }
}
