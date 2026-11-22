import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// scroll {until}: when it stops and what it says (`ScrollUntil`), how far a step goes, and how a step is told to
/// have moved anything. No app needed.
final class ScrollUntilTests: XCTestCase {
    let want = "button \"Load more\""
    let row = "[12] button \"Load more\" at (340,512)"

    /// Looks taken in turn, each (found, moved): where it stops, and its note.
    func run(_ looks: [(Bool, Bool)], limit: Int? = nil, start: Bool = false) -> ScrollUntil {
        var s = ScrollUntil(maxScrolls: limit)
        guard s.start(found: start) == nil else { return s }
        for (found, moved) in looks where s.stop == nil { _ = s.observe(found: found, moved: moved) }
        return s
    }

    /// Shown already: nothing is scrolled.
    func testInViewAlreadyScrollsNothing() {
        let s = run([(true, true)], start: true)
        XCTAssertEqual(s.stop, .found)
        XCTAssertEqual(s.steps, 0)
        XCTAssertEqual(s.note(want, end: "the bottom", found: row),
                       "found [12] button \"Load more\" at (340,512) (in view already: nothing was scrolled)")
    }

    /// Found after a few steps: how many, and what it is, numbered for the next action.
    func testFoundAfterSteps() {
        let s = run([(false, true), (false, true), (true, true), (false, true)])
        XCTAssertEqual(s.stop, .found)
        XCTAssertEqual(s.steps, 3)
        XCTAssertEqual(s.note(want, end: "the bottom", found: row), "scrolled 3 times; found [12] button \"Load more\" at (340,512)")
        XCTAssertEqual(run([(true, true)]).note(want, end: "the bottom", found: row),
                       "scrolled once; found [12] button \"Load more\" at (340,512)")
    }

    /// A step that moves nothing is the end, counting only the steps that moved.
    func testAStepThatMovesNothingIsTheEnd() {
        let s = run([(false, true), (false, true), (false, false), (false, true)])
        XCTAssertEqual(s.stop, .end)
        XCTAssertEqual(s.steps, 3)
        XCTAssertEqual(s.scrolls, 2)
        XCTAssertEqual(s.note(want, end: "the bottom", found: nil), "reached the bottom after 2 scrolls; button \"Load more\" not found")
        XCTAssertEqual(run([(false, true), (false, false)]).note("\"Q3\"", end: "the top", found: nil),
                       "reached the top after 1 scroll; \"Q3\" not found")
    }

    /// Nothing moved at all: at the end already, or nothing scrolls there.
    func testNothingMovesAtAll() {
        let s = run([(false, false)])
        XCTAssertEqual(s.stop, .end)
        XCTAssertEqual(s.scrolls, 0)
        XCTAssertEqual(s.note(want, end: "the bottom", found: nil),
                       "the scroll moved nothing (at the bottom already, or nothing scrolls there); button \"Load more\" not found")
    }

    /// The scroll bar left at its end ends it then, that step counted (no step more to find out).
    func testTheScrollBarAtItsEndEndsIt() {
        var s = ScrollUntil(maxScrolls: nil)
        XCTAssertNil(s.observe(found: false, moved: true))
        XCTAssertEqual(s.observe(found: false, moved: true, atEnd: true), .end)
        XCTAssertEqual(s.note(want, end: "the bottom", found: nil), "reached the bottom after 2 scrolls; button \"Load more\" not found")
    }

    /// Found beats the end: what the last step showed counts, moved or not.
    func testFoundWinsOverTheEnd() {
        var s = ScrollUntil(maxScrolls: nil)
        XCTAssertEqual(s.observe(found: true, moved: false, atEnd: true, late: true), .found)
        XCTAssertEqual(s.note(want, end: "the bottom", found: row), "scrolled once; found [12] button \"Load more\" at (340,512)")
    }

    /// At most max_scrolls steps (10 when not given).
    func testItStopsAtMaxScrolls() {
        let s = run(Array(repeating: (false, true), count: 20), limit: 3)
        XCTAssertEqual(s.stop, .limit)
        XCTAssertEqual(s.steps, 3)
        XCTAssertEqual(s.note(want, end: "the bottom", found: nil), "stopped after 3 scrolls; button \"Load more\" not found")
        let d = run(Array(repeating: (false, true), count: 20))
        XCTAssertEqual(d.steps, 10)
        XCTAssertEqual(d.note("\"X\"", end: "the bottom", found: nil), "stopped after 10 scrolls; \"X\" not found")
    }

    /// The time is up: after the step under way.
    func testItStopsWhenTheTimeIsUp() {
        var s = ScrollUntil(maxScrolls: nil)
        XCTAssertNil(s.observe(found: false, moved: true))
        XCTAssertEqual(s.observe(found: false, moved: true, late: true), .time)
        XCTAssertEqual(s.note("\"X\"", end: "the bottom", found: nil), "stopped after 2 scrolls (15 s); \"X\" not found")
        XCTAssertEqual(s.observe(found: true, moved: true), .time, "stopped is stopped")
        XCTAssertEqual(s.steps, 2)
    }

    /// max_scrolls as given: 1-15, 10 when not given or not a number.
    func testMaxScrollsIsCapped() {
        XCTAssertEqual(ScrollUntil.maxScrolls(nil), 10)
        XCTAssertEqual(ScrollUntil.maxScrolls(NSNull()), 10)
        XCTAssertEqual(ScrollUntil.maxScrolls("lots"), 10)
        XCTAssertEqual(ScrollUntil.maxScrolls(4), 4)
        XCTAssertEqual(ScrollUntil.maxScrolls(0), 1)
        XCTAssertEqual(ScrollUntil.maxScrolls(99), 15)
        XCTAssertEqual(ScrollUntil(maxScrolls: 15).limit, 15)
        XCTAssertEqual(ScrollUntil(maxScrolls: "4").limit, 4, "a number as text")
    }

    // MARK: - how far a step goes

    let view = CGSize(width: 600, height: 800)

    /// No amount: the shown part less a tenth, down unless told otherwise.
    func testAStepIsAViewportLessATenth() {
        func step(_ a: [String: Any]) -> [Double] { let s = ScrollUntil.step(a, viewport: view, ptPerPx: 0.5); return [s.dx, s.dy] }
        XCTAssertEqual(step(["type": "scroll", "until": "X"]), [0, 720])
        XCTAssertEqual(step(["type": "scroll", "until": "X", "direction": "up"]), [0, -720])
        XCTAssertEqual(step(["type": "scroll", "until": "X", "direction": "left"]), [-540, 0])
        XCTAssertEqual(step(["type": "scroll", "until": "X", "scroll_direction": "right"]), [540, 0])
        XCTAssertEqual(step(["type": "scroll", "until": "X", "direction": "down", "amount": NSNull()]), [0, 720], "null is no amount")
        XCTAssertEqual(ScrollUntil.step(["until": "X"], viewport: CGSize(width: 10, height: 10), ptPerPx: 1).dy, 20, "never under 20 pt")
    }

    /// An amount is the step, as a plain scroll goes (screenshot pixels, made points).
    func testAnAmountIsTheStep() {
        func step(_ a: [String: Any]) -> [Double] { let s = ScrollUntil.step(a, viewport: view, ptPerPx: 0.5); return [s.dx, s.dy] }
        XCTAssertEqual(step(["until": "X", "scroll_y": 300]), [0, 150])
        XCTAssertEqual(step(["until": "X", "scroll_y": -300]), [0, -150])
        XCTAssertEqual(step(["until": "X", "scroll_x": 400]), [200, 0])
        XCTAssertEqual(step(["until": "X", "direction": "down", "amount": 5]), [0, 250])
        XCTAssertEqual(step(["until": "X", "direction": "up", "scroll_amount": 2]), [0, -100])
        XCTAssertEqual(step(["until": "X", "scroll_y": 0]), [0, 720], "an amount of 0 px: a viewport after all")
    }

    // MARK: - whether a step moved anything

    let a = AXUIElementCreateApplication(424_301), b = AXUIElementCreateApplication(424_302)
    let f = CGRect(x: 0, y: 300, width: 200, height: 20)

    func g(_ el: AXUIElement, _ frame: CGRect, _ text: String?) -> ScrollWatch.Glance {
        ScrollWatch.Glance(spot: ScrollWatch.Spot(element: el, frame: frame), text: text)
    }

    /// Under the pointer: the same thing, where it was, saying the same, is still; anything else moved. Nothing
    /// there either time can't tell.
    func testGlancesTellAMove() {
        XCTAssertEqual(ScrollWatch.changed([g(a, f, "Row 3")], [g(a, f, "Row 3")]), false)
        XCTAssertEqual(ScrollWatch.changed([g(a, f, "Row 3")], [g(a, f.offsetBy(dx: 0, dy: -720), "Row 3")]), true)
        XCTAssertEqual(ScrollWatch.changed([g(a, f, "Row 3")], [g(b, f, "Row 27")]), true, "another element there")
        XCTAssertEqual(ScrollWatch.changed([g(a, f, "Row 3")], [g(a, f, "Row 27")]), true, "a row reused for another")
        XCTAssertEqual(ScrollWatch.changed([g(a, f, "Row 3")], [g(a, f.offsetBy(dx: 0, dy: 0.4), "Row 3")]), false, "under a point")
        XCTAssertEqual(ScrollWatch.changed([g(a, f, nil), nil], [nil, nil]), true, "gone from under a point")
        XCTAssertEqual(ScrollWatch.changed([nil, g(a, f, "Row 3")], [nil, g(a, f, "Row 3")]), false)
        XCTAssertNil(ScrollWatch.changed([nil, nil], [nil, nil]))
    }

    /// The scroll bar says first where there's one; else what's under the pointer; with neither, it's taken to
    /// have moved (the step count and the time end it).
    func testWhetherAStepMoved() {
        XCTAssertTrue(ScrollUntil.moved(bar: (0.2, 0.35), glances: false))
        XCTAssertTrue(ScrollUntil.moved(bar: (0.2, 0.2), glances: true), "another scroll area's bar, around the one scrolled")
        XCTAssertFalse(ScrollUntil.moved(bar: (1, 1), glances: false))
        XCTAssertFalse(ScrollUntil.moved(bar: (1, 1), glances: nil))
        XCTAssertFalse(ScrollUntil.moved(bar: (nil, nil), glances: false))
        XCTAssertTrue(ScrollUntil.moved(bar: (nil, nil), glances: true))
        XCTAssertTrue(ScrollUntil.moved(bar: (nil, nil), glances: nil), "nothing to tell by")
    }

    /// The bar at the end it's going to, having moved there this step.
    func testTheBarAtItsEnd() {
        XCTAssertTrue(ScrollUntil.atEnd(bar: (0.8, 1), forward: true))
        XCTAssertFalse(ScrollUntil.atEnd(bar: (0.5, 0.8), forward: true))
        XCTAssertFalse(ScrollUntil.atEnd(bar: (1, 1), forward: true), "it didn't move: maybe not the bar of what's scrolled")
        XCTAssertTrue(ScrollUntil.atEnd(bar: (0.3, 0), forward: false))
        XCTAssertFalse(ScrollUntil.atEnd(bar: (0.8, 1), forward: false))
        XCTAssertFalse(ScrollUntil.atEnd(bar: (nil, 1), forward: true))
    }

    // MARK: - where one aimed nowhere scrolls

    /// Aimed nowhere: the scroll area holding the text out of view (the probe's long list, not Notes under the
    /// window's middle); else the window's largest scroll area or web page; else nil (the window's middle).
    func testWhereAScrollUntilAimedNowhereScrolls() {
        let notes = CGRect(x: 16, y: 146, width: 688, height: 150), list = CGRect(x: 716, y: 146, width: 80, height: 426)
        XCTAssertEqual(Handlers.untilAim(holders: [list], areas: [notes, list]), CGPoint(x: list.midX, y: list.midY))
        XCTAssertEqual(Handlers.untilAim(holders: [], areas: [list, notes]), CGPoint(x: notes.midX, y: notes.midY), "the largest")
        XCTAssertNil(Handlers.untilAim(holders: [], areas: []))
    }

    final class Fake {
        let element: AXUIElement
        let role: String
        let frame: CGRect
        let kids: [Fake]
        init(_ id: Int, _ role: String, _ frame: CGRect, _ kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(940_000 + id))  // a distinct element; never asked anything
            (self.role, self.frame, self.kids) = (role, frame, kids)
        }
    }

    /// The probe's window: Notes (a text view in a scroll area), and the long list, whose "Row 60" is far below the
    /// window. The row's scroll area is the list's; the window's scroll areas are what's shown of each.
    func testTheScrollAreaHoldingARowAndTheWindowsScrollAreas() {
        let row60 = Fake(5, "AXButton", CGRect(x: 716, y: 1680, width: 64, height: 22))
        let list = Fake(4, "AXScrollArea", CGRect(x: 716, y: 146, width: 80, height: 426), [Fake(6, "AXGroup", CGRect(x: 716, y: 146, width: 64, height: 2200), [row60])])
        let notes = Fake(2, "AXScrollArea", CGRect(x: 16, y: 146, width: 688, height: 150),
                         [Fake(3, "AXTextArea", CGRect(x: 16, y: -2800, width: 670, height: 4200))])
        let off = Fake(7, "AXScrollArea", CGRect(x: 2000, y: 146, width: 300, height: 300))  // outside the window
        let tiny = Fake(8, "AXScrollArea", CGRect(x: 600, y: 20, width: 10, height: 10))
        let win = Fake(1, "AXWindow", CGRect(x: 0, y: 0, width: 804, height: 588), [notes, list, off, tiny])
        var all: [Fake] = []
        var parents: [AXUIElement: AXUIElement] = [:]
        func collect(_ f: Fake) {
            all.append(f)
            for k in f.kids { parents[k.element] = f.element; collect(k) }
        }
        collect(win)
        func fake(_ el: AXUIElement) -> Fake? { all.first { CFEqual($0.element, el) } }
        let holder = AX.scroller(of: row60.element, parent: { parents[$0] }, role: { fake($0)?.role })
        XCTAssertTrue(holder.map { CFEqual($0, list.element) } == true)
        XCTAssertNil(AX.scroller(of: notes.element, parent: { parents[$0] }, role: { fake($0)?.role }), "none above it")
        let read: (AXUIElement) -> [AnyObject]? = { el in
            guard let f = fake(el) else { return nil }
            var pos = f.frame.origin, size = f.frame.size
            let none = NSNull()
            return [f.role as NSString, none, none, none, none, f.kids.map(\.element) as NSArray, AXValueCreate(.cgPoint, &pos)!,
                    AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, none, none, none, none]
        }
        let areas = AX.scrollers(in: win.element, window: win.frame, now: { 0 }, read: read)
        XCTAssertEqual(areas, [notes.frame, list.frame])
        XCTAssertEqual(Handlers.untilAim(holders: [], areas: areas), CGPoint(x: notes.frame.midX, y: notes.frame.midY))
    }
}
