@preconcurrency import AVFoundation
import Foundation
#if canImport(whisper)
import whisper
#endif

final class LocalWhisperCPPModelManager: @unchecked Sendable {
    static let shared = LocalWhisperCPPModelManager()

    private let modelsDirectoryName = "whisper.cpp-models"
    private let bundleFallbackIdentifier = "com.a2gent.adapter-mac"

    var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? bundleFallbackIdentifier
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(modelsDirectoryName, isDirectory: true)
    }

    private init() {
        createModelsDirectoryIfNeeded()
    }

    func resolvedModelURL(for model: WhisperCPPDownloadableModel = LocalWhisperCPPModelSettings.selectedModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName, isDirectory: false)
    }

    func isModelAvailable(_ model: WhisperCPPDownloadableModel = LocalWhisperCPPModelSettings.selectedModel) -> Bool {
        FileManager.default.fileExists(atPath: resolvedModelURL(for: model).path)
    }

    func availableModels() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return []
        }
    }

    func ensureSelectedModelAvailable(progress: ((Double) -> Void)? = nil) async throws -> URL {
        let model = LocalWhisperCPPModelSettings.selectedModel
        let destinationURL = resolvedModelURL(for: model)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            progress?(1.0)
            return destinationURL
        }

        return try await download(model: model, progress: progress)
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create whisper.cpp model directory: \(error)")
        }
    }

    private func download(model: WhisperCPPDownloadableModel, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let destinationURL = resolvedModelURL(for: model)
        let temporaryURL = destinationURL.appendingPathExtension("download")

        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 60 * 30

        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        if response.expectedContentLength > 0 {
            progress?(1.0)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        try FileManager.default.moveItem(at: downloadedURL, to: temporaryURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
            return destinationURL
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        progress?(1.0)
        return destinationURL
    }
}

final class LocalWhisperCPPTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    static let shared = LocalWhisperCPPTranscriptionProvider()

    var apiEndpoint: String {
        let model = LocalWhisperCPPModelSettings.selectedModel
        return "Local whisper.cpp via ggml model \(model.fileName)"
    }

    private let modelManager: LocalWhisperCPPModelManager

    init(modelManager: LocalWhisperCPPModelManager = .shared) {
        self.modelManager = modelManager
    }

    func updateAPIEndpoint(_ endpoint: String?) {
        // Local whisper.cpp does not use a remote endpoint, so this stays a no-op.
    }

    func transcribe(audioURL: URL, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        #if canImport(whisper)
        let modelManager = self.modelManager
        Task.detached {
            do {
                let modelURL = try await modelManager.ensureSelectedModelAvailable()
                let samples = try Self.convertAudioToPCM(fileURL: audioURL)
                let text = try Self.runWhisper(modelURL: modelURL, samples: samples)
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

                if normalized.isEmpty {
                    completion(.failure(NSError(
                        domain: "LocalWhisperCPPTranscriptionProvider",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "No speech detected in the recording."]
                    )))
                    return
                }

                completion(.success(normalized))
            } catch {
                completion(.failure(error))
            }
        }
        #else
        completion(.failure(NSError(
            domain: "LocalWhisperCPPTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "whisper.cpp support is not available in this build."]
        )))
        #endif
    }

    #if canImport(whisper)
    private static func runWhisper(modelURL: URL, samples: [Float]) throws -> String {
        let params = whisper_context_default_params()
        guard let context = modelURL.path.withCString({ whisper_init_from_file_with_params($0, params) }) else {
            throw NSError(
                domain: "LocalWhisperCPPTranscriptionProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize whisper.cpp with model \(modelURL.lastPathComponent)."]
            )
        }
        defer {
            whisper_free(context)
        }

        var fullParams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        fullParams.print_realtime = false
        fullParams.print_progress = false
        fullParams.print_timestamps = false
        fullParams.print_special = false
        fullParams.translate = false
        fullParams.no_context = true
        fullParams.single_segment = false
        fullParams.max_len = 0
        fullParams.n_threads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8)))

        let status = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return -1
            }
            return whisper_full(context, fullParams, baseAddress, Int32(buffer.count))
        }

        guard status == 0 else {
            throw NSError(
                domain: "LocalWhisperCPPTranscriptionProvider",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "whisper.cpp transcription failed with status \(status)."]
            )
        }

        let segmentCount = whisper_full_n_segments(context)
        let segments: [String] = (0..<segmentCount).compactMap { index in
            guard let textPointer = whisper_full_get_segment_text(context, index) else {
                return nil
            }
            return String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return segments
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private final class SingleUseInputProvider: @unchecked Sendable {
        private let inputBuffer: AVAudioPCMBuffer
        private var didProvideInput = false

        init(inputBuffer: AVAudioPCMBuffer) {
            self.inputBuffer = inputBuffer
        }

        func nextBuffer(statusPointer: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !didProvideInput else {
                statusPointer.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }
    }
    #endif

    private static func convertAudioToPCM(fileURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let sourceFormat = audioFile.processingFormat
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "LocalWhisperCPPTranscriptionProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare the recording for whisper.cpp."]
            )
        }

        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let totalFrames = audioFile.length
        let inputChunkSize: AVAudioFrameCount = 65_536
        let outputChunkSize = AVAudioFrameCount(Double(inputChunkSize) * ratio) + 256

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputChunkSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
            throw NSError(
                domain: "LocalWhisperCPPTranscriptionProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffers for whisper.cpp."]
            )
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(totalFrames) * ratio) + 512)

        while audioFile.framePosition < totalFrames {
            inputBuffer.frameLength = 0
            try audioFile.read(into: inputBuffer, frameCount: inputChunkSize)
            if inputBuffer.frameLength == 0 {
                break
            }

            let inputProvider = SingleUseInputProvider(inputBuffer: inputBuffer)
            var conversionError: NSError?

            let outputStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                inputProvider.nextBuffer(statusPointer: outStatus)
            }

            if let conversionError {
                throw conversionError
            }

            if outputStatus == .error {
                throw NSError(
                    domain: "LocalWhisperCPPTranscriptionProvider",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed while preparing whisper.cpp input."]
                )
            }

            appendMixedSamples(from: outputBuffer, to: &samples)
        }

        if samples.isEmpty {
            throw NSError(
                domain: "LocalWhisperCPPTranscriptionProvider",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "No audio samples were produced for whisper.cpp transcription."]
            )
        }

        return samples
    }

    private static func appendMixedSamples(from buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else {
            return
        }

        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            output.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            return
        }

        for frameIndex in 0..<frameCount {
            var mixedSample: Float = 0
            for channelIndex in 0..<channelCount {
                mixedSample += channelData[channelIndex][frameIndex]
            }
            output.append(mixedSample / Float(channelCount))
        }
    }
}
