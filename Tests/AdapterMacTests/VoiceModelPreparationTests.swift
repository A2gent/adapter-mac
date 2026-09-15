import XCTest

@testable import adapter_mac

private actor ModelLoadProbe {
    var calls = 0
    var cancellations = 0
    func load() async throws {
        calls += 1
        do { try await Task.sleep(for: .seconds(60)) } catch {
            cancellations += 1
            throw error
        }
    }
    func count() -> Int { calls }
    func cancelledCount() -> Int { cancellations }
}

final class VoiceModelPreparationTests: XCTestCase {
    func testSuccessfulPreparationIsReused() async throws {
        let preparation = VoiceModelPreparation()
        let probe = ModelLoadProbe()
        try await preparation.prepare { _ = await probe.count() }
        try await preparation.prepare { XCTFail("Ready models must not reload") }
    }

    func testCancellationReachesLoaderAndRetryStartsFresh() async throws {
        let preparation = VoiceModelPreparation()
        let probe = ModelLoadProbe()
        let first = Task { try await preparation.prepare { try await probe.load() } }
        while await probe.count() == 0 { await Task.yield() }
        first.cancel()
        do {
            try await first.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let cancelled = await probe.cancelledCount()
        XCTAssertEqual(cancelled, 1)
        try await preparation.prepare {}
        try await preparation.prepare { XCTFail("Retry result should be cached") }
    }

    func testImmediateRetryWaitsForCancelledLoadToFinish() async throws {
        let preparation = VoiceModelPreparation()
        let probe = ModelLoadProbe()
        let first = Task { try await preparation.prepare { try await probe.load() } }
        while await probe.count() == 0 { await Task.yield() }
        first.cancel()
        try await preparation.prepare {
            let cancelled = await probe.cancelledCount()
            XCTAssertEqual(cancelled, 1, "Retry must not overlap the cancelled load")
        }
        _ = try? await first.value
    }

    func testFailureCanBeRetried() async throws {
        let preparation = VoiceModelPreparation()
        do {
            try await preparation.prepare { throw URLError(.notConnectedToInternet) }
            XCTFail("Expected download failure")
        } catch {}
        try await preparation.prepare {}
    }
}

@MainActor
final class VoiceConfigurationTests: XCTestCase {
    func testUnchangedConfigurationDoesNotRestartVoice() {
        let controller = VoiceConversationController()
        var statuses: [String] = []
        controller.onStatus = { status, _ in statuses.append(status) }
        controller.configure(VoiceSettings(), deviceID: nil)
        controller.configure(VoiceSettings(), deviceID: nil)
        XCTAssertEqual(statuses, ["Voice listening off"])
        controller.configure(VoiceSettings(), deviceID: "another-microphone")
        XCTAssertEqual(statuses.count, 2)
    }
}
