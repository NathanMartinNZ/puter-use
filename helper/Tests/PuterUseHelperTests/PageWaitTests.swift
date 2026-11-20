import XCTest

@testable import PuterUseHelper

/// `navigate`'s waits: the pauses before it looks whether the page has loaded, and the poll for a new
/// window's address bar.
@MainActor
final class PageWaitTests: XCTestCase {
    /// A short first pause only when the window's page is known and the typed address is another one (the
    /// wait for the address to change follows); the same address or nothing known keeps 0.4 s.
    func testFirstPauseIsShortOnlyWhenTheAddressShouldChange() {
        XCTAssertEqual(Handlers.firstPagePause(["http://127.0.0.1:8000/a.html", "A"], "127.0.0.1:8000/b.html"), 0.1)
        XCTAssertEqual(Handlers.firstPagePause(["http://127.0.0.1:8000/a.html", "A"], "127.0.0.1:8000/a.html#part"), 0.1,
                       "a hash is another address")
        XCTAssertEqual(Handlers.firstPagePause([nil, "New Tab"], "example.com"), 0.1, "compared by title")
        XCTAssertEqual(Handlers.firstPagePause(["https://www.example.com/", "Example"], "example.com"), 0.4, "the same address")
        XCTAssertEqual(Handlers.firstPagePause(nil, "example.com"), 0.4, "nothing to compare")
    }

    /// No pause once the page's address has changed; a title change alone (or nothing read) keeps 0.4 s.
    func testSecondPauseOnlyGoesWhenTheAddressChanged() {
        let before: [String?] = ["http://127.0.0.1:8000/a.html", "A"]
        XCTAssertEqual(Handlers.secondPagePause(before, ["http://127.0.0.1:8000/b.html", "A"]), 0)
        XCTAssertEqual(Handlers.secondPagePause(before, ["http://127.0.0.1:8000/b.html", "B"]), 0)
        XCTAssertEqual(Handlers.secondPagePause([nil, "New Tab"], ["http://127.0.0.1:8000/b.html", "New Tab"]), 0)
        XCTAssertEqual(Handlers.secondPagePause(before, ["http://127.0.0.1:8000/a.html", "B"]), 0.4, "only the title")
        XCTAssertEqual(Handlers.secondPagePause(before, [nil, "B"]), 0.4, "no address to go by")
        XCTAssertEqual(Handlers.secondPagePause(before, nil), 0.4)
    }

    /// After navigate in a browser the first frame comes no sooner than the skipped menu poll (0.4 s) plus
    /// settle_ms after the last input; other actions and native apps keep their waits.
    func testFirstFrameAfterNavigateWaitsAsLongAsWithThePoll() {
        func wait(_ full: Bool, _ navigated: Bool, now: Double) -> Double {
            (Handlers.firstFrameWait(full: full, navigated: navigated, settle: 0.25, quiet: 100, now: now) * 1000).rounded() / 1000
        }
        XCTAssertEqual(wait(true, true, now: 100.01), 0.64, "no poll ran: 0.4 + settle from the last input")
        XCTAssertEqual(wait(true, true, now: 100.5), 0.25, "a slow menu check: settle_ms after it, as ever")
        XCTAssertEqual(wait(true, false, now: 100.4), 0.25, "after a poll: settle_ms after it")
        XCTAssertEqual(wait(false, true, now: 100.01), 0.24, "native: settle_ms from the last input")
        XCTAssertTrue(Handlers.navigates(["type": "navigate", "url": "x"]))
        XCTAssertFalse(Handlers.navigates(["type": "click"]))
        XCTAssertFalse(Handlers.navigates(nil))
        XCTAssertFalse(Handlers.menuWait(["type": "navigate", "url": "x"], combo: false), "the poll itself stays skipped")
    }

    /// Ready at once: done after the floor. Ready later: checked every `every` s until it is.
    func testPollEndsOnceReady() async throws {
        var start = Date()
        var checks = 0
        let now = try await Run.pollUntil(floor: 0.05, every: 0.04, cap: 0.6) { checks += 1; return true }
        XCTAssertTrue(now)
        XCTAssertEqual(checks, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.045, "the floor")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)

        start = Date()
        checks = 0
        let later = try await Run.pollUntil(floor: 0.05, every: 0.04, cap: 0.6) { checks += 1; return checks == 4 }
        XCTAssertTrue(later)
        XCTAssertEqual(checks, 4)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05 + 3 * 0.04 - 0.01)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    /// Never ready: false once the cap (from the start, floor included) has passed, with a last check at the end.
    func testPollGivesUpAtTheCap() async throws {
        let start = Date()
        var checks = 0
        let ready = try await Run.pollUntil(floor: 0.05, every: 0.04, cap: 0.3) { checks += 1; return false }
        let took = Date().timeIntervalSince(start)
        XCTAssertFalse(ready)
        XCTAssertGreaterThanOrEqual(took, 0.29)
        XCTAssertLessThan(took, 0.6)
        XCTAssertGreaterThanOrEqual(checks, 4)
        XCTAssertLessThanOrEqual(checks, 8)
    }
}
