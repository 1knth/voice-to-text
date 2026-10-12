import XCTest
@testable import WhisperCore

final class HUDVisibilityTests: XCTestCase {
    func testVisibilityTransitionsOnlyAnimateOnce() throws {
        var state = HUDVisibility()
        XCTAssertNil(state.request(visible: false))
        let show = try XCTUnwrap(state.request(visible: true))
        XCTAssertTrue(state.visible)
        XCTAssertNil(state.request(visible: true))
        XCTAssertFalse(state.shouldHide(completedGeneration: show))
        let hide = try XCTUnwrap(state.request(visible: false))
        XCTAssertNil(state.request(visible: false))
        XCTAssertTrue(state.shouldHide(completedGeneration: hide))
    }
    func testOldFadeOutCannotHideNewRecording() throws {
        var state = HUDVisibility()
        _ = state.request(visible: true)
        let oldHide = try XCTUnwrap(state.request(visible: false))
        _ = state.request(visible: true)
        XCTAssertFalse(state.shouldHide(completedGeneration: oldHide))
        let latestHide = try XCTUnwrap(state.request(visible: false))
        XCTAssertFalse(state.shouldHide(completedGeneration: oldHide))
        XCTAssertTrue(state.shouldHide(completedGeneration: latestHide))
    }
    func testPhaseUpdatesDoNotInvalidateFadeOutCompletion() throws {
        var state = HUDVisibility()
        _ = state.request(visible: true)
        XCTAssertNil(state.request(visible: true))
        let hide = try XCTUnwrap(state.request(visible: false))
        XCTAssertNil(state.request(visible: false))
        XCTAssertTrue(state.shouldHide(completedGeneration: hide))
    }
}
