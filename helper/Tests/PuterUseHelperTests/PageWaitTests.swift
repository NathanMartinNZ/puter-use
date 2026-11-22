import ApplicationServices
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

    // MARK: - after a link or a submit

    /// The watch for a new page with a made-up clock (each pause 0.1 s): what the page shows at each look.
    func sign(_ seen: [Handlers.PageSeen], watch: Double = 1, cap: Double = 10) async throws -> (Handlers.PageSign, looks: Int) {
        var ticks = 0, looks = 0  // (tenths counted whole: 0.1 added up drifts below 1.0)
        let sign = try await Handlers.awaitPageSign(watch: watch, cap: cap, look: {
            defer { looks += 1 }
            return seen[min(looks, seen.count - 1)]
        }, pause: { ticks += 1 }, clock: { Double(ticks) * 0.1 })
        return (sign, looks)
    }

    /// No sign of a new page within the watch: the page stays (a press that did something in place), and it costs
    /// the watch, no more.
    func testNoSignWithinTheWatchIsQuiet() async throws {
        let (s, looks) = try await sign([.same], watch: 1)
        XCTAssertEqual(s, .quiet)
        XCTAssertEqual(looks, 11, "a look every 0.1 s through the watch")
        let button = try await sign([.same], watch: 0.5)
        XCTAssertEqual(button.0, .quiet)
        XCTAssertEqual(button.looks, 6)
    }

    /// A new page in place (replaced, at another address, another title) ends the watch at once: its load is
    /// waited for next.
    func testANewPageEndsTheWatch() async throws {
        let (s, looks) = try await sign([.same, .same, .changed])
        XCTAssertEqual(s, .changed)
        XCTAssertEqual(looks, 3)
        let (late, _) = try await sign([.loading, .loading, .loading, .changed], watch: 0.1)
        XCTAssertEqual(late, .changed, "loading carries the watch past its end")
    }

    /// Loading that stops with no new page (a download, a cancelled request) ends it: nothing to wait for.
    func testLoadingThatStopsWithNoNewPageEndsIt() async throws {
        let (s, looks) = try await sign([.loading, .loading, .same])
        XCTAssertEqual(s, .ended)
        XCTAssertEqual(looks, 3)
    }

    /// A page still loading at the cap: that's said (a note), not waited for longer.
    func testStillLoadingAtTheCapGivesUp() async throws {
        let (s, looks) = try await sign([.loading], watch: 1, cap: 2)
        XCTAssertEqual(s, .stillLoading)
        XCTAssertEqual(looks, 21)
    }

    // MARK: - the browser's Reload button, while a slow server hasn't answered

    /// A Reload button's label: Stop while a page loads (Firefox's "Stop", Chrome's and Safari's "Stop loading this
    /// page"), Reload or Refresh otherwise; anything else says nothing.
    func testTheReloadButtonsLabelSaysWhetherAPageLoads() {
        for loading in ["Stop", "Stop loading this page", "Stop loading", " stop ", "Stop (Esc)"] {
            XCTAssertEqual(AX.loadState(loading), true, loading)
        }
        for idle in ["Reload", "Reload this page", "Reload page", "Refresh"] {
            XCTAssertEqual(AX.loadState(idle), false, idle)
        }
        for other in ["Back", "Stopwatch", "Stop sharing", "Home", ""] {
            XCTAssertNil(AX.loadState(other), other)
        }
    }

    /// At its address and title, a page is loading when it says so, or when the window's Reload button reads Stop
    /// (the old page stays, loaded and not busy, while a slow server hasn't answered); else it's the same.
    func testAStopButtonIsLoadingThoughTheOldPageSaysItsLoaded() {
        XCTAssertEqual(Handlers.pageSeen(loaded: true, busy: false, stop: true), .loading)
        XCTAssertEqual(Handlers.pageSeen(loaded: true, busy: false, stop: false), .same)
        XCTAssertEqual(Handlers.pageSeen(loaded: true, busy: false, stop: nil), .same, "no button to go by")
        XCTAssertEqual(Handlers.pageSeen(loaded: false, busy: nil, stop: false), .loading)
        XCTAssertEqual(Handlers.pageSeen(loaded: nil, busy: true, stop: nil), .loading)
        XCTAssertEqual(Handlers.pageSeen(loaded: nil, busy: nil, stop: nil), .same)
    }

    /// A link to a page whose server answers after 3 s: the old page stays as it was, the Reload button reads Stop
    /// all the while. The watch goes on past its 1 s until the new page is there; with nothing reading Stop it would
    /// have ended quiet on the old page. The page stopping with no new one (a download) ends it; one never there gives
    /// up at the cap.
    func testASlowServersPageIsWaitedForWhileTheReloadButtonReadsStop() async throws {
        let waiting = Handlers.pageSeen(loaded: true, busy: false, stop: true)
        let (s, looks) = try await sign(Array(repeating: waiting, count: 30) + [.changed], watch: 1)
        XCTAssertEqual(s, .changed)
        XCTAssertEqual(looks, 31)
        let unseen = Handlers.pageSeen(loaded: true, busy: false, stop: nil)
        let (before, beforeLooks) = try await sign(Array(repeating: unseen, count: 30) + [.changed], watch: 1)
        XCTAssertEqual(before, .quiet, "without the button")
        XCTAssertEqual(beforeLooks, 11)
        let done = Handlers.pageSeen(loaded: true, busy: false, stop: false)
        let (ended, _) = try await sign(Array(repeating: waiting, count: 5) + [done], watch: 1)
        XCTAssertEqual(ended, .ended)
        let (capped, _) = try await sign([waiting], watch: 1, cap: Handlers.pageCap)
        XCTAssertEqual(capped, .stillLoading)
    }

    /// Made-up accessibility elements: a role, a label (as its description) and children.
    final class Fake {
        let element: AXUIElement
        let role: String
        let label: String?
        var kids: [Fake]
        init(_ id: Int, _ role: String, _ label: String? = nil, kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(948_000 + id))  // a distinct element; never asked anything
            (self.role, self.label, self.kids) = (role, label, kids)
        }
    }

    /// An element's `AX.attrs` as the app would give them, from the live ones (`all`); nil for one that's gone.
    func attrs(_ el: AXUIElement, _ all: [Fake]) -> [AnyObject]? {
        guard let f = all.first(where: { CFEqual($0.element, el) }) else { return nil }
        let none = NSNull()
        return [f.role as NSString, none, none, (f.label as NSString?) ?? none, none, f.kids.map(\.element) as NSArray,
                none, none, none, kCFBooleanTrue, none, none, none, none]
    }

    func everything(_ f: Fake) -> [Fake] { [f] + f.kids.flatMap(everything) }

    /// The window's own Reload button, found breadth first; a button in the page by that name isn't it, however near.
    func testTheReloadButtonIsTheWindowsOwnNeverOneInThePage() throws {
        let reload = Fake(5, "AXButton", "Reload")
        let toolbar = Fake(2, "AXToolbar", kids: [Fake(3, "AXButton", "Back"), Fake(4, "AXButton", "Forward"), reload])
        let page = Fake(6, "AXWebArea", kids: [Fake(7, "AXButton", "Refresh")])
        let win = Fake(1, "AXWindow", kids: [page, Fake(8, "AXGroup", kids: [toolbar])])
        let all = everything(win)
        let found = try XCTUnwrap(AX.reloadButton(in: win.element, read: { self.attrs($0, all) }))
        XCTAssertTrue(CFEqual(found.button, reload.element))
        XCTAssertTrue(CFEqual(try XCTUnwrap(found.parent), toolbar.element))
        let none = Fake(9, "AXWindow", kids: [page])
        XCTAssertNil(AX.reloadButton(in: none.element, read: { self.attrs($0, self.everything(none)) }), "only the page's")
        XCTAssertNil(AX.reloadButton(in: win.element, visits: 3, read: { self.attrs($0, all) }), "past its visits")
    }

    /// Its label read again each look. Firefox's Reload button goes and a Stop button comes in its place while a page
    /// loads, then the other way round: the one beside it is read then, and kept for the next look.
    func testTheReloadButtonIsFollowedAsFirefoxSwapsItForStop() {
        let reload = Fake(11, "AXButton", "Reload"), stop = Fake(12, "AXButton", "Stop")
        let toolbar = Fake(10, "AXToolbar", kids: [Fake(13, "AXButton", "Back"), reload])
        let b = Handlers.ReloadButton(reload.element, parent: toolbar.element)
        XCTAssertEqual(AX.loading(b, read: { self.attrs($0, self.everything(toolbar)) }), false)
        toolbar.kids = [toolbar.kids[0], stop]  // loading: the Reload button is gone
        XCTAssertEqual(AX.loading(b, read: { self.attrs($0, self.everything(toolbar)) }), true)
        XCTAssertTrue(CFEqual(b.button, stop.element), "kept")
        let back = Fake(14, "AXButton", "Reload")
        toolbar.kids = [toolbar.kids[0], back]  // loaded: a new Reload button
        XCTAssertEqual(AX.loading(b, read: { self.attrs($0, self.everything(toolbar)) }), false)
        XCTAssertTrue(CFEqual(b.button, back.element))
        toolbar.kids = [toolbar.kids[0]]
        XCTAssertNil(AX.loading(b, read: { self.attrs($0, self.everything(toolbar)) }), "none to go by")
        XCTAssertNil(AX.loading(Handlers.ReloadButton(reload.element, parent: nil), read: { _ in nil }))
    }

    /// Watched after a press on a link (or what's in one) longest, a button (or its text) less; a field, a checkbox
    /// or a pop-up, plain text or a picture by itself not at all.
    func testWhatAPressIsWatchedFor() {
        XCTAssertEqual(Handlers.pageWatch(["AXLink", "AXGroup"]), Handlers.linkWatch)
        XCTAssertEqual(Handlers.pageWatch(["AXStaticText", "AXLink"]), Handlers.linkWatch)
        XCTAssertEqual(Handlers.pageWatch(["AXImage", "AXGroup", "AXLink"]), Handlers.linkWatch)
        XCTAssertEqual(Handlers.pageWatch(["AXButton", "AXGroup"]), Handlers.buttonWatch)
        XCTAssertEqual(Handlers.pageWatch(["AXStaticText", "AXButton"]), Handlers.buttonWatch)
        XCTAssertNil(Handlers.pageWatch(["AXTextField", "AXLink"]), "a field in a link still only takes the caret")
        XCTAssertNil(Handlers.pageWatch(["AXCheckBox", "AXGroup"]))
        XCTAssertNil(Handlers.pageWatch(["AXPopUpButton"]))
        XCTAssertNil(Handlers.pageWatch(["AXStaticText", "AXGroup", "AXGroup"]))
        XCTAssertNil(Handlers.pageWatch(["AXImage"]))
        XCTAssertNil(Handlers.pageWatch([]))
        XCTAssertLessThanOrEqual(Handlers.linkWatch, 1.5, "a press that stays costs this much")
        XCTAssertGreaterThanOrEqual(Handlers.pageCap, 5)
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
