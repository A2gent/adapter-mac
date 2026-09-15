import Foundation
import XCTest

@testable import adapter_mac

final class VoiceSessionTests: XCTestCase {
    func testContinueUsesChatMessageNotTaskAndReturnsReply() async throws {
        let service = BruteSessionService { request in
            XCTAssertEqual(request.url?.path, "/sessions/voice-id/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            XCTAssertEqual(body, ["message": "продолжай"])
            XCTAssertGreaterThan(request.timeoutInterval, 30)
            return (
                Data(#"{"content":"Готово","status":"completed"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let reply = try await service.voiceChat(
            baseURL: URL(string: "http://localhost:5445")!, sessionID: "voice-id", message: "продолжай")
        XCTAssertEqual(reply.content, "Готово")
    }

    func testOnlyAssistantAfterLastUserIsSpoken() throws {
        let snapshot = try JSONDecoder().decode(
            VoiceSessionSnapshot.self,
            from: Data(
                #"{"id":"s","status":"completed","messages":[{"role":"assistant","content":"old"},{"role":"user","content":"new"},{"role":"tool","content":"secret tool output"},{"role":"assistant","content":"new answer"}]}"#
                    .utf8))
        XCTAssertEqual(snapshot.reply, "new answer")
        XCTAssertTrue(snapshot.finished)
        let running = try JSONDecoder().decode(
            VoiceSessionSnapshot.self, from: Data(#"{"id":"s","status":"running","messages":[]}"#.utf8))
        XCTAssertFalse(running.finished)
    }

    func testHTTPFailureIsNotRetried() async throws {
        let service = BruteSessionService { request in
            (
                Data(#"{"error":"Session is busy"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await service.voiceChat(
                baseURL: URL(string: "http://localhost:5445")!, sessionID: "s", message: "go")
            XCTFail("Must preserve the error")
        } catch { XCTAssertEqual(error.localizedDescription, "Session is busy") }
    }
}
