import Foundation
import AVFoundation

protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float])
}

struct AudioInputDevice: Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

final class AudioService: NSObject {
    weak var delegate: AudioServiceDelegate?

    private let selectedMicrophoneIDKey = "selectedMicrophoneID"
    private let sessionQueue = DispatchQueue(label: "com.a2gent.scribe.audio.session")
    private let captureQueue = DispatchQueue(label: "com.a2gent.scribe.audio.capture")

    private var captureSession: AVCaptureSession?
    private var captureInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var speechSynthesizer: AVSpeechSynthesizer?

    private var waveformData: [Float] = []
    private var isRecording = false

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
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }

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
        speechSynthesizer = AVSpeechSynthesizer()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5

        speechSynthesizer?.speak(utterance)
        completion(true)
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
