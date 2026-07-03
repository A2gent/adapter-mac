import XCTest
@testable import adapter_mac

final class ShortcutBehaviorTests: XCTestCase {
    private let holdToRecordEnabledKey = "adapterMacHoldToRecordEnabled"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: holdToRecordEnabledKey)
        super.tearDown()
    }

    func testHoldToRecordDefaultsToDisabled() {
        XCTAssertFalse(RecordingShortcutSettings.holdToRecordEnabled)
    }

    func testHoldToRecordPersistsEnabledValue() {
        RecordingShortcutSettings.holdToRecordEnabled = true

        XCTAssertTrue(RecordingShortcutSettings.holdToRecordEnabled)
    }

    func testHoldToRecordReleaseBeforeThresholdDoesNotSubmitRecording() {
        let gesture = HoldToRecordGesture(threshold: 0.3)

        XCTAssertFalse(gesture.shouldStopRecordingOnKeyUp(pressDuration: 0.29))
    }

    func testHoldToRecordReleaseAtOrAfterThresholdStopsRecording() {
        let gesture = HoldToRecordGesture(threshold: 0.3)

        XCTAssertTrue(gesture.shouldStopRecordingOnKeyUp(pressDuration: 0.3))
        XCTAssertTrue(gesture.shouldStopRecordingOnKeyUp(pressDuration: 0.8))
    }
}
