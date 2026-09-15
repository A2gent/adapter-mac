import Foundation
import XCTest

@testable import adapter_mac

final class SessionRequestTests: XCTestCase {
    func testTaskAndProjectUseBackendContractNotPrompt() throws {
        let request = try SessionCreationRequest(task: "  Fix this game  ", projectID: "game-project", images: [])
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["task"] as? String, "Fix this game")
        XCTAssertEqual(json["project_id"] as? String, "game-project")
        XCTAssertEqual(json["agent_id"] as? String, "build")
        XCTAssertEqual(json["queue_mode"] as? String, "serial")
        XCTAssertEqual(json["queued"] as? Bool, true)
        XCTAssertNil(json["prompt"])
    }

    func testEmptyTaskOrProjectCannotCreateOrphanSession() {
        XCTAssertThrowsError(try SessionCreationRequest(task: " \n", projectID: "p", images: []))
        XCTAssertThrowsError(try SessionCreationRequest(task: "hello", projectID: " ", images: []))
    }

    func testScreenshotUsesSameImageContractAsChromeAdapter() throws {
        let image = SessionImage(pngData: Data([1, 2, 3]))
        let request = try SessionCreationRequest(task: "Look", projectID: "p", images: [image])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["media_type"] as? String, "image/png")
        XCTAssertEqual(images.first?["data_base64"] as? String, "AQID")
    }

    func testKnowledgeBaseUsesSystemIDBeforeNameAndNeverAnotherProject() {
        let projects = [
            SessionProject(id: "a", name: "Work", folder: nil),
            SessionProject(id: "legacy", name: " knowledge base ", folder: nil),
            SessionProject(id: "system-kb", name: "Renamed", folder: nil),
        ]
        XCTAssertEqual(SessionProject.knowledgeBase(in: projects)?.id, "system-kb")
        XCTAssertEqual(SessionProject.knowledgeBase(in: Array(projects.prefix(2)))?.id, "legacy")
        XCTAssertNil(SessionProject.knowledgeBase(in: [projects[0]]))
    }
}
