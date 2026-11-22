import XCTest

@testable import PuterUseHelper

/// What an act returns at its end (`Handlers.ending`).
final class ActEndingTests: XCTestCase {
    func end(want: Bool = true, always: Bool = false, done: Int = 0, stopped: Bool = false, confirm: Bool = false,
             failed: Bool = true, first: Bool = true, moved: Bool = false, clipboard: Bool = false) -> Handlers.Ending {
        Handlers.ending(wantShot: want, always: always, done: done, stopped: stopped, confirm: confirm, failed: failed,
                        firstLook: first, moved: moved, clipboardOnly: clipboard)
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

    /// It has seen the window: one quick look, sent only if the window changed since its last image (a page
    /// that loaded meanwhile, a dialog that came up), else the error alone. With screenshot "never", or an
    /// empty batch, the status alone.
    func testOtherwiseAFailedFirstActionGetsAQuickLook() {
        XCTAssertEqual(end(first: false), .check)
        XCTAssertEqual(end(want: false), .status)
        XCTAssertEqual(end(want: false, first: false), .status)
        XCTAssertEqual(end(want: false, done: 2, failed: false), .status)
        XCTAssertEqual(end(failed: false), .status)  // nothing to run
        XCTAssertEqual(end(failed: false, first: false), .status)
    }

    /// Something ran, the batch stopped before coordinates (something opened over the window, or there's no
    /// picture to read them from), or "always": a settled screenshot, first look or not.
    func testRunsCoordinateStopsAndAlwaysSettle() {
        for first in [true, false] {
            XCTAssertEqual(end(done: 1, first: first), .settled)
            XCTAssertEqual(end(done: 3, failed: false, first: first), .settled)
            XCTAssertEqual(end(stopped: true, failed: false, first: first), .settled)
            XCTAssertEqual(end(always: true, first: first), .settled)
        }
    }

    /// A stop for the user's OK before anything ran waits for nothing: a window the agent hasn't seen is
    /// shown (it was captured anyway), else one quick look, sent only if the window changed. After earlier
    /// actions ran, it settles as ever (and `act` sends the image only if they changed something). "always"
    /// and a move to a new window still settle; "never" still sends none.
    func testAStopForTheUsersOKSettlesOnlyAfterSomethingRan() {
        XCTAssertEqual(end(stopped: true, confirm: true, failed: false, first: false), .check)
        XCTAssertEqual(end(stopped: true, confirm: true, failed: false), .firstLook)
        XCTAssertEqual(end(done: 2, stopped: true, confirm: true, failed: false, first: false), .settled)
        XCTAssertEqual(end(done: 2, stopped: true, confirm: true, failed: false), .settled)
        XCTAssertEqual(end(always: true, stopped: true, confirm: true, failed: false, first: false), .settled)
        XCTAssertEqual(end(stopped: true, confirm: true, failed: false, first: false, moved: true), .settled)
        XCTAssertEqual(end(want: false, stopped: true, confirm: true, failed: false), .status)
    }

    /// Only the clipboard: the status alone, whether it ran or failed, first look or not, unless "always".
    func testAClipboardBatchShowsNoImage() {
        for first in [true, false] {
            XCTAssertEqual(end(done: 1, failed: false, first: first, clipboard: true), .status)
            XCTAssertEqual(end(done: 2, failed: false, first: first, clipboard: true), .status)
            XCTAssertEqual(end(first: first, clipboard: true), .status)  // a read that failed
            XCTAssertEqual(end(always: true, done: 1, failed: false, first: first, clipboard: true), .settled)
        }
    }

    /// A batch of clipboard reads and writes only (by type or action, paged or not); not one with keys or a
    /// paste in it, not an empty one, and not with "always".
    func testWhatCountsAsOnlyTheClipboard() {
        let read: [String: Any] = ["type": "clipboard"], write: [String: Any] = ["type": "clipboard", "text": "hi"]
        XCTAssertTrue(Handlers.onlyClipboard([read], always: false))
        XCTAssertTrue(Handlers.onlyClipboard([write, read], always: false))
        XCTAssertTrue(Handlers.onlyClipboard([["action": "clipboard", "offset": 4000, "limit": 2000]], always: false))
        XCTAssertFalse(Handlers.onlyClipboard([read], always: true))
        XCTAssertFalse(Handlers.onlyClipboard([], always: false))
        XCTAssertFalse(Handlers.onlyClipboard([["type": "key", "keys": "cmd+c"], read], always: false))
        XCTAssertFalse(Handlers.onlyClipboard([["type": "paste", "text": "hi"]], always: false))
        XCTAssertFalse(Handlers.onlyClipboard([read, ["type": "activate"]], always: false))
    }
}
