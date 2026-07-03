import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

final class LocalFluidAudioTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    static let shared = LocalFluidAudioTranscriptionProvider()

    var apiEndpoint: String {
        "Local on-device transcription via FluidAudio"
    }

    private init() {}

    func updateAPIEndpoint(_ endpoint: String?) {
        // Local FluidAudio does not use a remote endpoint, so this is intentionally a no-op.
    }

    func transcribe(audioURL: URL, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        #if canImport(FluidAudio)
        guard #available(macOS 14.0, *) else {
            completion(.failure(NSError(
                domain: "LocalFluidAudioTranscriptionProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Local FluidAudio transcription requires macOS 14 or newer."]
            )))
            return
        }

        Task.detached {
            do {
                // Keep local STT self-contained: models are downloaded on demand and cached
                // by FluidAudio, while brute HTTP remains the default provider.
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)

                var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                if text.isEmpty {
                    completion(.failure(NSError(
                        domain: "LocalFluidAudioTranscriptionProvider",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "No speech detected in the recording."]
                    )))
                    return
                }

                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
        #else
        completion(.failure(NSError(
            domain: "LocalFluidAudioTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not available in this build."]
        )))
        #endif
    }
}
