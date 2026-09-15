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
    private var preparation: Task<Void, Error>?

    func prepare() async throws {
        if context != nil, vad != nil { return }
        if let preparation { return try await preparation.value }
        let task = Task { try await self.loadModels() }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }

    private func loadModels() async throws {
        let directory = LocalWhisperCPPModelManager.shared.modelsDirectory
        let url = directory.appendingPathComponent("ggml-small.bin")
        if !FileManager.default.fileExists(atPath: url.path) {
            var request = URLRequest(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!)
            request.timeoutInterval = 1800
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
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
            var params = whisper_context_default_params()
            params.use_gpu = true
            // Request GPU acceleration where supported; the pinned whisper.spm currently falls back to Accelerate.
            context = url.path.withCString { whisper_init_from_file_with_params($0, params) }.map(
                VoiceWhisperContext.init)
            guard context != nil else {
                throw SessionServiceError.message("Cannot load multilingual voice model at \(url.path).")
            }
        }
        vad = try await VadManager()
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
