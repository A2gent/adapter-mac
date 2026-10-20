import Foundation

struct BruteSpeechService: Sendable {
    private let transport: BruteSessionService.Transport

    init(
        transport: @escaping BruteSessionService.Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw SessionServiceError.message("Brute returned an invalid speech response.")
            }
            return (data, response)
        }
    ) {
        self.transport = transport
    }

    func synthesize(text: String, baseURL: URL) async throws -> URL {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
            let host = baseURL.host, !host.isEmpty
        else {
            throw SessionServiceError.message("Configure a valid Brute HTTP URL in Audio & speech settings.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("speech/completion"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Omit model and language so Brute's Speech settings remain the source of truth.
        request.httpBody = try JSONEncoder().encode(["text": text])
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            throw SessionServiceError.message(
                WhisperService.extractErrorMessage(from: data) ?? "Brute speech returned HTTP \(response.statusCode).")
        }
        guard !data.isEmpty, response.mimeType?.hasPrefix("audio/") == true else {
            throw SessionServiceError.message("Brute returned empty or invalid speech audio.")
        }
        let fileExtension: String
        switch response.mimeType {
        case "audio/mpeg", "audio/mp3": fileExtension = "mp3"
        case "audio/mp4", "audio/x-m4a": fileExtension = "m4a"
        case "audio/aac": fileExtension = "aac"
        case "audio/ogg": fileExtension = "ogg"
        case "audio/flac", "audio/x-flac": fileExtension = "flac"
        default: fileExtension = "wav"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter_mac_tts_\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
