import Foundation

protocol TranscriptionProvider: AnyObject {
    var apiEndpoint: String { get }

    func updateAPIEndpoint(_ endpoint: String?)
    func transcribe(audioURL: URL, completion: @escaping @Sendable (Result<String, Error>) -> Void)
}

enum TranscriptionProviderOption: String, CaseIterable {
    case bruteHTTP = "bruteHTTP"
    case localFluidAudio = "localFluidAudio"
    case localWhisperCPP = "localWhisperCPP"

    var title: String {
        switch self {
        case .bruteHTTP:
            return "Brute HTTP"
        case .localFluidAudio:
            return "Local FluidAudio"
        case .localWhisperCPP:
            return "Local whisper.cpp"
        }
    }
}

enum TranscriptionSettings {
    static let selectedProviderKey = "selectedTranscriptionProvider"

    static var selectedProvider: TranscriptionProviderOption {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: selectedProviderKey),
                  let provider = TranscriptionProviderOption(rawValue: rawValue) else {
                return .bruteHTTP
            }

            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
        }
    }
}

protocol TranscriptionProvidingFactory {
    func makeSelectedProvider() -> TranscriptionProvider
}

struct TranscriptionProviderFactory: TranscriptionProvidingFactory {
    let bruteProvider: TranscriptionProvider
    let localFluidAudioProvider: TranscriptionProvider
    let localWhisperCPPProvider: TranscriptionProvider

    init(
        bruteProvider: TranscriptionProvider = WhisperService.shared,
        localFluidAudioProvider: TranscriptionProvider = LocalFluidAudioTranscriptionProvider.shared,
        localWhisperCPPProvider: TranscriptionProvider = LocalWhisperCPPTranscriptionProvider.shared
    ) {
        self.bruteProvider = bruteProvider
        self.localFluidAudioProvider = localFluidAudioProvider
        self.localWhisperCPPProvider = localWhisperCPPProvider
    }

    func makeSelectedProvider() -> TranscriptionProvider {
        switch TranscriptionSettings.selectedProvider {
        case .bruteHTTP:
            return bruteProvider
        case .localFluidAudio:
            return localFluidAudioProvider
        case .localWhisperCPP:
            return localWhisperCPPProvider
        }
    }
}

private struct PreparedAudioUpload: Sendable {
    let url: URL
    let cleanup: @Sendable () -> Void
}

final class WhisperService: TranscriptionProvider, @unchecked Sendable {
    static let shared = WhisperService()

    private let apiEndpointKey = "transcriptionAPIEndpoint"
    private let defaultAPIEndpoint = "http://localhost:5445/speech/transcribe"

    var apiEndpoint: String {
        let storedValue = UserDefaults.standard.string(forKey: apiEndpointKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedValue, !storedValue.isEmpty {
            return storedValue
        }

        return defaultAPIEndpoint
    }

    func updateAPIEndpoint(_ endpoint: String?) {
        let trimmedEndpoint = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedEndpoint.isEmpty {
            UserDefaults.standard.removeObject(forKey: apiEndpointKey)
        } else {
            UserDefaults.standard.set(trimmedEndpoint, forKey: apiEndpointKey)
        }
    }

    static func apiBaseURL(from endpoint: String) -> URL? {
        guard let endpointURL = URL(string: endpoint),
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let suffix = "/speech/transcribe"
        if components.path.hasSuffix(suffix) {
            components.path = String(components.path.dropLast(suffix.count))
        } else if components.path.hasSuffix("/transcribe") {
            components.path = String(components.path.dropLast("/transcribe".count))
        }

        if components.path.isEmpty {
            components.path = ""
        }

        return components.url
    }

    func apiBaseURL() -> URL? {
        Self.apiBaseURL(from: apiEndpoint)
    }
    
    func transcribe(audioURL: URL, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        let preparedAudio = prepareAudioForUpload(from: audioURL)
        let uploadURL = preparedAudio.url

        guard let endpointURL = URL(string: apiEndpoint) else {
            preparedAudio.cleanup()
            completion(.failure(NSError(
                domain: "WhisperService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid transcription endpoint: \(apiEndpoint)"]
            )))
            return
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Keep the existing multipart request shape so the default brute endpoint
        // continues to receive the same payload while call sites move to the abstraction.
        if let audioData = try? Data(contentsOf: uploadURL) {
            let filename = uploadURL.lastPathComponent
            let mimeType = Self.mimeType(for: uploadURL)

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n".data(using: .utf8)!)
        } else {
            preparedAudio.cleanup()
            completion(.failure(NSError(
                domain: "WhisperService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to read prepared audio file"]
            )))
            return
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer {
                preparedAudio.cleanup()
            }

            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "WhisperService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                let message = Self.extractErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                completion(.failure(NSError(
                    domain: "WhisperService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )))
                return
            }
            
            if let text = Self.parseTranscription(from: data) {
                completion(.success(text))
                return
            }

            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 response>"
            print("❌ Unexpected transcription response: \(bodyPreview)")
            completion(.failure(NSError(
                domain: "WhisperService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )))
        }.resume()
    }

    private func prepareAudioForUpload(from audioURL: URL) -> PreparedAudioUpload {
        // Brute now normalizes common compressed audio formats server-side before
        // whisper.cpp. Uploading the original m4a avoids expanding long recordings
        // into large WAV payloads that can exceed the HTTP size limit.
        PreparedAudioUpload(url: audioURL, cleanup: {})
    }

    private static func parseTranscription(from data: Data) -> String? {
        if let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plainText.isEmpty,
           !plainText.hasPrefix("{") {
            return plainText
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        if let text = dictionary["transcription"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let text = dictionary["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let data = dictionary["data"] as? [String: Any] {
            if let transcription = data["transcription"] as? String,
               !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcription
            }

            if let text = data["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        return nil
    }

    static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let dictionary = object as? [String: Any] {
            if let error = dictionary["error"] as? String,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return error
            }

            if let message = dictionary["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }

            if let detail = dictionary["detail"] as? String,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return detail
            }

            if let data = dictionary["data"] as? [String: Any] {
                if let message = data["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }

                if let error = data["error"] as? String,
                   !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return error
                }
            }
        }

        return nil
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        default:
            return "application/octet-stream"
        }
    }
}

final class BruteSessionService: @unchecked Sendable {
    static let shared = BruteSessionService()

    func startSession(with prompt: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let baseURL = WhisperService.shared.apiBaseURL() else {
            completion(.failure(NSError(
                domain: "WhisperService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Could not derive brute API base URL from the transcription endpoint."]
            )))
            return
        }

        let sessionsURL = baseURL.appendingPathComponent("sessions")
        var request = URLRequest(url: sessionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "prompt": prompt
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let data else {
                completion(.failure(NSError(
                    domain: "WhisperService",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "No data received from brute while creating the session."]
                )))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                let message = WhisperService.extractErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                completion(.failure(NSError(
                    domain: "WhisperService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )))
                return
            }

            completion(.success(()))
        }.resume()
    }
}
