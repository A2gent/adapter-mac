import Foundation

struct WhisperCPPDownloadableModel: Equatable {
    let id: String
    let title: String
    let fileName: String
    let downloadURL: URL
    let details: String
}

enum WhisperCPPModelCatalog {
    static let availableModels: [WhisperCPPDownloadableModel] = [
        WhisperCPPDownloadableModel(
            id: "ggml-tiny-en",
            title: "tiny.en",
            fileName: "ggml-tiny.en.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!,
            details: "Smallest English-only ggml model. Fastest download and best default for first offline verification."
        ),
        WhisperCPPDownloadableModel(
            id: "ggml-base-en",
            title: "base.en",
            fileName: "ggml-base.en.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
            details: "English-only ggml model with higher accuracy than tiny.en."
        ),
        WhisperCPPDownloadableModel(
            id: "ggml-small-en",
            title: "small.en",
            fileName: "ggml-small.en.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
            details: "Larger English-only ggml model for better offline quality on Apple Silicon."
        )
    ]

    static let defaultModel = availableModels[0]

    static func model(for id: String?) -> WhisperCPPDownloadableModel {
        guard let id,
              let match = availableModels.first(where: { $0.id == id }) else {
            return defaultModel
        }

        return match
    }
}

enum LocalWhisperCPPModelSettings {
    static let selectedModelIDKey = "selectedLocalWhisperCPPModelID"

    static var selectedModelID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: selectedModelIDKey)
            return WhisperCPPModelCatalog.model(for: stored).id
        }
        set {
            UserDefaults.standard.set(WhisperCPPModelCatalog.model(for: newValue).id, forKey: selectedModelIDKey)
        }
    }

    static var selectedModel: WhisperCPPDownloadableModel {
        WhisperCPPModelCatalog.model(for: selectedModelID)
    }
}
