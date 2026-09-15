import Foundation
import XCTest

@testable import adapter_mac

private actor SessionTransportLog {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

final class BruteSessionServiceTests: XCTestCase {
    private let baseURL = URL(string: "http://localhost:5445")!

    func testAudioFlowResolvesKnowledgeBaseAndSendsTranscriptAndImage() async throws {
        let log = SessionTransportLog()
        let service = BruteSessionService { request in
            await log.append(request)
            let response: String
            if request.url?.path == "/projects" {
                response = #"[{"id":"work","name":"Work"},{"id":"system-kb","name":"Knowledge Base"}]"#
            } else {
                response = #"{"id":"session-id","project_id":"system-kb"}"#
            }
            return (
                Data(response.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let project = try await service.knowledgeBaseProject(baseURL: baseURL)
        let payload = try SessionCreationRequest(
            task: "Speech transcript", projectID: project.id,
            images: [SessionImage(pngData: Data([1, 2]))])
        let created = try await service.create(baseURL: baseURL, request: payload)
        XCTAssertEqual(created.id, "session-id")
        let requests = await log.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(json["task"] as? String, "Speech transcript")
        XCTAssertEqual(json["project_id"] as? String, "system-kb")
        XCTAssertEqual((json["images"] as? [Any])?.count, 1)
    }

    func testMissingKnowledgeBaseDoesNotPostSession() async {
        let log = SessionTransportLog()
        let service = BruteSessionService { request in
            await log.append(request)
            return (
                Data("[]".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await service.knowledgeBaseProject(baseURL: baseURL)
            XCTFail("Missing Knowledge Base must not succeed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Knowledge Base")) }
        let requests = await log.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testHTTPErrorPropagatesBackendMessageWithoutRetry() async throws {
        let log = SessionTransportLog()
        let service = BruteSessionService { request in
            await log.append(request)
            return (
                Data(#"{"error":"Project not found"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await service.create(
                baseURL: baseURL, request: SessionCreationRequest(task: "Hi", projectID: "p", images: []))
            XCTFail("HTTP error must not succeed")
        } catch { XCTAssertEqual(error.localizedDescription, "Project not found") }
        let count = await log.requests.count
        XCTAssertEqual(count, 1)
    }

    func testIncompleteResponseIsNotReportedAsSuccess() async throws {
        let service = BruteSessionService { request in
            (
                Data(#"{"id":"orphan"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await service.create(
                baseURL: baseURL, request: SessionCreationRequest(task: "Hi", projectID: "p", images: []))
            XCTFail("Unbound session must not succeed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Check Caesar")) }
    }
}
