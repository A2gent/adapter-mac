import AppKit
import XCTest

@testable import adapter_mac

@MainActor
final class SessionComposerTests: XCTestCase {
    private let baseURL = URL(string: "http://localhost:5445")!

    func testSubmitNeedsTextValidProjectAndCompletedCapture() {
        let model = SessionComposerModel(baseURL: baseURL)
        model.text = "Investigate"
        model.projectID = "p"
        XCTAssertFalse(model.canSubmit)
        model.projects = [SessionProject(id: "p", name: "Project", folder: nil)]
        XCTAssertTrue(model.canSubmit)
        model.capturing = true
        XCTAssertFalse(model.canSubmit)
        model.capturing = false
        model.text = " \n"
        XCTAssertFalse(model.canSubmit)
    }

    func testFailedSubmissionKeepsDraftAndProject() async {
        let service = BruteSessionService { _ in throw URLError(.notConnectedToInternet) }
        let model = SessionComposerModel(baseURL: baseURL, service: service)
        model.projects = [SessionProject(id: "p", name: "Project", folder: nil)]
        model.projectID = "p"
        model.text = "Keep this transcript"
        model.marks = [ScreenMark(kind: .arrow, points: [.zero, CGPoint(x: 1, y: 1)])]
        await model.submit()
        XCTAssertEqual(model.text, "Keep this transcript")
        XCTAssertEqual(model.projectID, "p")
        XCTAssertEqual(model.marks.count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.created)
        XCTAssertFalse(model.submitting)
    }

    func testCreatedSessionCannotBeSubmittedAgain() async {
        let service = BruteSessionService { request in
            (
                Data(#"{"id":"created","project_id":"p"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            )
        }
        let model = SessionComposerModel(baseURL: baseURL, service: service)
        model.projects = [SessionProject(id: "p", name: "Project", folder: nil)]
        model.projectID = "p"
        model.text = "Task"
        await model.submit()
        XCTAssertEqual(model.created?.id, "created")
        XCTAssertFalse(model.canSubmit)
    }

    func testAnnotationCoordinatesClampAndScale() {
        XCTAssertEqual(
            ScreenMark.point(CGPoint(x: 500, y: -10), in: CGSize(width: 200, height: 100)), CGPoint(x: 1, y: 0))
        let mark = ScreenMark(kind: .rectangle, points: [CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.25)])
        XCTAssertEqual(
            mark.path(in: CGSize(width: 400, height: 200)).boundingBox, CGRect(x: 100, y: 50, width: 200, height: 100))
    }

    func testExportBurnsAnnotationsIntoPNGAtCorrectOrientation() throws {
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let mark = ScreenMark(kind: .pen, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)])
        let plain = try ScreenshotRenderer.png(image: image, marks: [])
        let annotated = try ScreenshotRenderer.png(image: image, marks: [mark])
        XCTAssertNotEqual(plain, annotated)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: annotated))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 100)
        let midX = bitmap.pixelsWide / 2
        let topY = bitmap.pixelsHigh / 5
        let bottomY = bitmap.pixelsHigh * 4 / 5
        let top = try XCTUnwrap(bitmap.colorAt(x: midX, y: topY)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: midX, y: bottomY)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, top.greenComponent)
        XCTAssertEqual(bottom.greenComponent, 1, accuracy: 0.01)
    }
}
