import Foundation
import XCTest

@testable import adapter_mac

final class BruteSpeechServiceTests: XCTestCase {
    func testSpeechUsesBackendSettingsAndPreservesBasePath() async throws {
        let audio = Data("audio fixture".utf8)
        let service = BruteSpeechService { request in
            XCTAssertEqual(request.url?.absoluteString, "https://brute.example/api/speech/completion")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertGreaterThan(request.timeoutInterval, 30)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            XCTAssertEqual(body, ["text": "Привет"])
            return (
                audio,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"])!
            )
        }
        let url = try await service.synthesize(text: "Привет", baseURL: URL(string: "https://brute.example/api")!)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: url), audio)
    }

    func testRejectsEmptyAndNonAudioSuccessfulResponses() async throws {
        for (data, contentType) in [(Data(), "audio/wav"), (Data("{}".utf8), "application/json")] {
            let service = BruteSpeechService { request in
                (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": contentType])!
                )
            }
            do {
                _ = try await service.synthesize(text: "Hello", baseURL: URL(string: "http://localhost:5445")!)
                XCTFail("Invalid audio must not reach playback")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Brute returned empty or invalid speech audio.")
            }
        }
    }

    func testHTTPFailurePreservesBackendErrorWithoutRetry() async throws {
        let service = BruteSpeechService { request in
            (
                Data(#"{"error":"Speech model is unavailable"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await service.synthesize(text: "Hello", baseURL: URL(string: "http://localhost:5445")!)
            XCTFail("Must not silently fall back to another voice")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Speech model is unavailable")
        }
    }

    func testRejectsNonHTTPBackendBeforeTransport() async throws {
        let service = BruteSpeechService { _ in
            XCTFail("Invalid URL must not reach the transport")
            throw URLError(.badURL)
        }
        do {
            _ = try await service.synthesize(text: "Hello", baseURL: URL(string: "file:///tmp")!)
            XCTFail("Must reject non-HTTP backend")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("valid Brute HTTP URL"))
        }
    }

    @MainActor
    func testAutomaticIncludingExistingPreferenceUsesBrute() async throws {
        let suite = "BruteSpeechTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = BruteSpeechService { request in
            XCTAssertEqual(request.url?.path, "/speech/completion")
            return (
                Data("audio".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "audio/wav"])!
            )
        }
        let synthesizer = AudioTextToSpeechSynthesizer(speechService: service, defaults: defaults)
        for persisted in [false, true] {
            if persisted { synthesizer.selectTTSEngine(.automatic) }
            XCTAssertEqual(synthesizer.selectedTTSEngine(), .automatic)
            let url = try await synthesizer.synthesizeTextToAudio(
                text: "Hello", baseURL: URL(string: "http://localhost:5445")!)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertEqual(try Data(contentsOf: url), Data("audio".utf8))
        }
    }

    @MainActor
    func testAutomaticDoesNotFallbackOnBackendFailure() async throws {
        let suite = "BruteSpeechTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = BruteSpeechService { _ in throw URLError(.cannotConnectToHost) }
        let synthesizer = AudioTextToSpeechSynthesizer(speechService: service, defaults: defaults)
        do {
            _ = try await synthesizer.synthesizeTextToAudio(
                text: "Hello", baseURL: URL(string: "http://localhost:5445")!)
            XCTFail("Automatic must use Brute, not Edge or system speech")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }
}
