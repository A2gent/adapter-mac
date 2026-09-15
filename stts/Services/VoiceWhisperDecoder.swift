import FluidAudio
import Foundation
import whisper

/// Actor isolation serializes whisper's C context; it stays loaded between commands.
private final class VoiceWhisperContext: @unchecked Sendable {
    // Only VoiceWhisperDecoder accesses this handle; the owner frees it after its last actor use.
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { whisper_free(pointer) }
}

actor VoiceWhisperDecoder {
    private var context: VoiceWhisperContext?
    private var vad: VadManager?
    private var vadState = VadStreamState.initial()
    private let preparation = VoiceModelPreparation()

    func prepare(onProgress: @escaping @Sendable (VoiceModelLoadState) -> Void = { _ in }) async throws {
        try await preparation.prepare { try await self.loadModels(onProgress: onProgress) }
    }

    private func loadModels(onProgress: @escaping @Sendable (VoiceModelLoadState) -> Void) async throws {
        try Task.checkCancellation()
        let directory = LocalWhisperCPPModelManager.shared.modelsDirectory
        let url = directory.appendingPathComponent("ggml-small.bin")
        if !FileManager.default.fileExists(atPath: url.path) {
            onProgress(.loading("Downloading multilingual Whisper model…", nil))
            var request = URLRequest(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!)
            request.timeoutInterval = 1800
            let delegate = VoiceModelDownloadProgress(onProgress: onProgress)
            let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
                    > 1_000_000
            else { throw SessionServiceError.message("Failed to download the multilingual voice model.") }
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
        try Task.checkCancellation()
        if context == nil {
            onProgress(.loading("Loading cached Whisper model into memory…", nil))
            var params = whisper_context_default_params()
            params.use_gpu = true
            // Request GPU acceleration where supported; the pinned whisper.spm currently falls back to Accelerate.
            context = url.path.withCString { whisper_init_from_file_with_params($0, params) }.map(
                VoiceWhisperContext.init)
            guard context != nil else {
                throw SessionServiceError.message("Cannot load multilingual voice model at \(url.path).")
            }
        }
        try Task.checkCancellation()
        if vad == nil {
            onProgress(.loading("Preparing voice activity model…", nil))
            vad = try await VadManager(progressHandler: { progress in
                switch progress.phase {
                case .downloading:
                    onProgress(.loading("Downloading voice activity model…", progress.fractionCompleted))
                case .compiling(let name):
                    onProgress(.loading("Compiling voice activity model: \(name)…", nil))
                default:
                    onProgress(.loading("Preparing voice activity model…", nil))
                }
            })
        }
        try Task.checkCancellation()
    }

    func resetVAD() { vadState = .initial() }

    func speechProbability(_ samples: [Float]) async throws -> Float {
        guard let vad else { throw SessionServiceError.message("Voice activity model is not loaded.") }
        let result = try await vad.processStreamingChunk(samples, state: vadState)
        vadState = result.state
        return result.probability
    }

    func transcribe(_ samples: [Float], language: String, vocabulary: String = "") throws -> String {
        guard let context = context?.pointer, !samples.isEmpty else { return "" }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        params.n_threads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6)))
        let status = vocabulary.withCString { prompt in
            params.initial_prompt = prompt
            return language.withCString { language in
                params.language = language
                return samples.withUnsafeBufferPointer {
                    whisper_full(context, params, $0.baseAddress, Int32($0.count))
                }
            }
        }
        guard status == 0 else { throw SessionServiceError.message("Local voice decoding failed (\(status)).") }
        return (0..<whisper_full_n_segments(context)).compactMap { index in
            whisper_full_get_segment_text(context, index).map { String(cString: $0) }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

struct VoiceSampleBuffer {
    let capacity: Int
    private(set) var samples: [Float] = []
    private(set) var overflowed = false

    mutating func append(_ incoming: [Float]) {
        if samples.count + incoming.count > capacity { overflowed = true }
        samples = Array((samples + incoming).suffix(capacity))
    }

    mutating func drain() -> (samples: [Float], overflowed: Bool) {
        defer {
            samples.removeAll(keepingCapacity: true)
            overflowed = false
        }
        return (samples, overflowed)
    }
}

/// Shares preparation and retains ready models, but propagates cancellation to the actual download task.
actor VoiceModelPreparation {
    private var task: Task<Void, Error>?
    private var generation = UUID()
    private var ready = false

    func prepare(_ load: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        if ready { return }
        if let previous = task, previous.isCancelled {
            let previousID = generation
            _ = try? await previous.value
            if generation == previousID { task = nil }
            return try await prepare(load)
        }
        if task == nil {
            generation = UUID()
            task = Task { try await load() }
        }
        let id = generation
        let current = task!
        do {
            try await withTaskCancellationHandler {
                try await current.value
                try Task.checkCancellation()
            } onCancel: {
                current.cancel()
            }
            if generation == id {
                ready = true
                task = nil
            }
        } catch {
            if generation == id { task = nil }
            throw error
        }
    }
}

private final class VoiceModelDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (VoiceModelLoadState) -> Void

    init(onProgress: @escaping @Sendable (VoiceModelLoadState) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let received = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        let fraction =
            totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        let total =
            totalBytesExpectedToWrite > 0
            ? " of " + ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file) : ""
        let percent = fraction.map { " (\(Int($0 * 100))%)" } ?? ""
        onProgress(.loading("Downloading Whisper: \(received)\(total)\(percent)", fraction))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
