import AVFoundation
import Foundation

final class AudioRecordingController: NSObject {
    var onWaveform: (([Float]) -> Void)?

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

    func cancelRecording() {
        guard isRecording else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.teardownCaptureSession(cancelWriter: true)
        }
    }

    func startRecording(device: AVCaptureDevice, completion: @escaping (Bool) -> Void) {
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

            self.waveformData.append(normalizedLevel)
            if self.waveformData.count > 100 {
                self.waveformData.removeFirst()
            }

            self.onWaveform?(self.waveformData)
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
