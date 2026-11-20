import XCTest

@testable import PuterUseHelper

/// What an act returns at its end (`Handlers.ending`).
final class ActEndingTests: XCTestCase {
    func end(want: Bool = true, always: Bool = false, done: Int = 0, stopped: Bool = false, failed: Bool = true,
             first: Bool = true, moved: Bool = false) -> Handlers.Ending {
        Handlers.ending(wantShot: want, always: always, done: done, stopped: stopped, failed: failed, firstLook: first,
                        moved: moved)
    }

    /// The first action moved the batch to a new window (navigate, open), then failed: that window is the
    /// session's now, so it's shown settled, not the one the batch started on.
    func testAMovedBatchShowsTheWindowItMovedTo() {
        XCTAssertEqual(end(moved: true), .settled)
        XCTAssertEqual(end(first: false, moved: true), .settled)
        XCTAssertEqual(end(want: false, moved: true), .status)  // "never" still means no image
    }

    /// The first action failed on a window the agent hasn't seen: it gets the window with the error.
    func testAFailedFirstLookShowsTheWindow() {
        XCTAssertEqual(end(), .firstLook)
    }

    /// It has seen the window: the error alone, as before. So with screenshot "never", or an empty batch.
    func testOtherwiseAFailedFirstActionShowsNoImage() {
        XCTAssertEqual(end(first: false), .status)
        XCTAssertEqual(end(want: false), .status)
        XCTAssertEqual(end(want: false, done: 2, failed: false), .status)
        XCTAssertEqual(end(failed: false), .status)  // nothing to run
    }

    /// Something ran, the batch stopped, or "always": a settled screenshot, first look or not.
    func testRunsStopsAndAlwaysSettle() {
        for first in [true, false] {
            XCTAssertEqual(end(done: 1, first: first), .settled)
            XCTAssertEqual(end(done: 3, failed: false, first: first), .settled)
            XCTAssertEqual(end(stopped: true, failed: false, first: first), .settled)
            XCTAssertEqual(end(always: true, first: first), .settled)
        }
    }
}
