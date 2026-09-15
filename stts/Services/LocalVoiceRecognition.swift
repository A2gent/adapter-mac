@preconcurrency import AVFoundation
import Foundation

/// Capture and bounded PCM writes share one queue. No audio files are created.
private final class VoiceMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.a2gent.voice.capture")
    private var session: AVCaptureSession?
    private var buffer = VoiceSampleBuffer(capacity: 16_000 * 20)
    private var formatError = false

    func start(deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.stopOnQueue()
                    let devices = AVCaptureDevice.DiscoverySession(
                        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
                    ).devices
                    let device =
                        deviceID.flatMap { id in devices.first { $0.uniqueID == id } }
                        ?? AVCaptureDevice.default(for: .audio)
                    guard let device else { throw SessionServiceError.message("No microphone available.") }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                    ]
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        throw SessionServiceError.message("Cannot connect the microphone.")
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.session = session
                    session.startRunning()
                    guard session.isRunning else {
                        self.stopOnQueue()
                        throw SessionServiceError.message("Microphone capture did not start.")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func drain() async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = self.buffer.drain()
                if result.overflowed || self.formatError {
                    continuation.resume(
                        throwing: SessionServiceError.message(
                            self.formatError
                                ? "Microphone did not provide 16 kHz mono PCM. Choose another input."
                                : "Local recognition cannot keep up. Capture stopped rather than dropping your command."
                        ))
                } else {
                    continuation.resume(returning: result.samples)
                }
            }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        session?.stopRunning()
        session = nil
        buffer = VoiceSampleBuffer(capacity: 16_000 * 20)
        formatError = false
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            format.pointee.mSampleRate == 16_000, format.pointee.mChannelsPerFrame == 1,
            format.pointee.mBitsPerChannel == 32, format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            let data = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            formatError = true
            return
        }
        let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard status == noErr else {
            formatError = true
            return
        }
        buffer.append(samples)
    }
}

@MainActor
final class LocalVoiceRecognition {
    var onText: ((String) -> Void)?
    var onSegmentEnd: (() -> Void)?
    var onSpeech: (() -> Void)?
    var onError: ((String) -> Void)?
    private let microphone = VoiceMicrophone()
    private let decoder = VoiceWhisperDecoder()
    private var processing: Task<Void, Never>?
    private var generation = UUID()
    private(set) var decoding = false

    func start(
        settings: VoiceSettings, deviceID: String?,
        onProgress: @escaping @Sendable (VoiceModelLoadState) -> Void = { _ in }
    ) async throws {
        stop()
        let generation = self.generation
        let allowed = await withCheckedContinuation { continuation in
            AudioService.requestMicrophonePermission { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard generation == self.generation else { return }
        guard allowed else { throw SessionServiceError.message("Allow microphone access in macOS Privacy & Security.") }
        try await decoder.prepare(onProgress: onProgress)
        guard generation == self.generation, !Task.isCancelled else { return }
        await decoder.resetVAD()
        guard generation == self.generation, !Task.isCancelled else { return }
        try await microphone.start(deviceID: deviceID)
        guard generation == self.generation else { return }
        processing = Task { [weak self] in
            await self?.process(
                generation: generation, language: settings.localeIdentifier.hasPrefix("ru") ? "ru" : "en",
                vocabulary: settings.agentName + ". " + settings.endPhrases)
        }
    }

    func stop() {
        generation = UUID()
        processing?.cancel()
        processing = nil
        decoding = false
        microphone.stop()
    }

    private func process(generation: UUID, language: String, vocabulary: String) async {
        var pending: [Float] = []
        var preRoll: [Float] = []
        var utterance: [Float] = []
        var silenceChunks = 0
        var lastDecodedSize = 0
        var lastAudio = ProcessInfo.processInfo.systemUptime
        do {
            while !Task.isCancelled, generation == self.generation {
                let incoming = try await microphone.drain()
                if !incoming.isEmpty { lastAudio = ProcessInfo.processInfo.systemUptime }
                guard ProcessInfo.processInfo.systemUptime - lastAudio < 5 else {
                    throw SessionServiceError.message(
                        "No audio received. Check the microphone and press Retry in voice settings.")
                }
                pending.append(contentsOf: incoming)
                while pending.count >= 4096 {
                    let chunk = Array(pending.prefix(4096))
                    pending.removeFirst(4096)
                    let probability = try await decoder.speechProbability(chunk)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    let speech = probability >= 0.6
                    if speech {
                        onSpeech?()
                        if utterance.isEmpty { utterance = preRoll }
                        silenceChunks = 0
                    } else {
                        silenceChunks += 1
                    }
                    preRoll = Array((preRoll + chunk).suffix(8192))
                    if speech || !utterance.isEmpty { utterance.append(contentsOf: chunk) }
                    let final = !utterance.isEmpty && (silenceChunks >= 3 || utterance.count >= 16_000 * 15)
                    let partial = !utterance.isEmpty && utterance.count - lastDecodedSize >= 16_000 * 2
                    if final || partial {
                        decoding = true
                        let text = try await decoder.transcribe(utterance, language: language, vocabulary: vocabulary)
                        guard generation == self.generation, !Task.isCancelled else { return }
                        decoding = false
                        onText?(text)
                        guard generation == self.generation else { return }
                        lastDecodedSize = utterance.count
                        if final {
                            onSegmentEnd?()
                            utterance.removeAll(keepingCapacity: true)
                            lastDecodedSize = 0
                            preRoll.removeAll(keepingCapacity: true)
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            stop()
            onError?(error.localizedDescription)
        }
    }
}
