import Foundation

class WhisperService {
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
    
    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
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
        
        // Add audio file
        if let audioData = try? Data(contentsOf: uploadURL) {
            let filename = uploadURL.lastPathComponent
            let mimeType = mimeType(for: uploadURL)

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
        
        URLSession.shared.dataTask(with: request) { [self] data, response, error in
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
                let message = self.extractErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                completion(.failure(NSError(
                    domain: "WhisperService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )))
                return
            }
            
            if let text = self.parseTranscription(from: data) {
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

    private func prepareAudioForUpload(from audioURL: URL) -> (url: URL, cleanup: () -> Void) {
        guard audioURL.pathExtension.lowercased() != "wav" else {
            return (audioURL, {})
        }

        do {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe_\(UUID().uuidString).wav")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [
                "-f", "WAVE",
                "-d", "LEI16",
                audioURL.path,
                outputURL.path
            ]

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                print("⚠️ afconvert failed with status \(process.terminationStatus)")
                try? FileManager.default.removeItem(at: outputURL)
                return (audioURL, {})
            }

            return (outputURL, {
                try? FileManager.default.removeItem(at: outputURL)
            })
        } catch {
            print("⚠️ Failed to convert audio for upload: \(error)")
            return (audioURL, {})
        }
    }

    private func parseTranscription(from data: Data) -> String? {
        if let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plainText.isEmpty,
           !plainText.hasPrefix("{"),
           !plainText.hasPrefix("[") {
            return plainText
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        return extractText(from: json)
    }

    private func extractText(from json: Any) -> String? {
        if let text = json as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let dictionary = json as? [String: Any] {
            let preferredKeys = ["text", "transcript", "transcription", "output", "response", "result"]

            for key in preferredKeys {
                if let value = dictionary[key],
                   let extracted = extractText(from: value) {
                    return extracted
                }
            }

            if let data = dictionary["data"] {
                return extractText(from: data)
            }

            if let choices = dictionary["choices"] as? [[String: Any]] {
                for choice in choices {
                    if let extracted = extractText(from: choice) {
                        return extracted
                    }
                }
            }
        }

        if let array = json as? [Any] {
            for item in array {
                if let extracted = extractText(from: item) {
                    return extracted
                }
            }
        }

        return nil
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }

        if let dictionary = json as? [String: Any] {
            for key in ["error", "message", "detail"] {
                if let value = dictionary[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }

        return extractText(from: json)
    }

    private func mimeType(for audioURL: URL) -> String {
        switch audioURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "caf":
            return "audio/x-caf"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }
}
