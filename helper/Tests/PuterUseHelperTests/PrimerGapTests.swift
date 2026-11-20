import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The primer click doesn't wait after itself: the next button or key going down waits out whatever is
/// left of its 60 ms (`Input.afterPrimer`), so the pointer's way to the spot counts toward it. Events go to
/// `Input.sink`, not to an app.
@MainActor final class PrimerGapTests: XCTestCase {
    func testGapLeft() {
        let gap = Input.primerGap
        XCTAssertEqual(gap, 0.06)
        XCTAssertEqual(Input.gapLeft(since: nil, now: 100), 0, "no primer yet")
        XCTAssertEqual(Input.gapLeft(since: 100, now: 100), gap, accuracy: 1e-9, "right after it: all of it")
        XCTAssertEqual(Input.gapLeft(since: 100, now: 100.02), 0.04, accuracy: 1e-9, "a short way there: the rest")
        XCTAssertEqual(Input.gapLeft(since: 100, now: 100.06), 0, accuracy: 1e-9)
        XCTAssertEqual(Input.gapLeft(since: 100, now: 100.2), 0, "the pointer's travel covered it")
        XCTAssertEqual(Input.gapLeft(since: 100, now: 99), gap, "never more than the gap")
    }

    /// Posts a primer, then `then` at once; returns when each event went out (system uptime) and when the
    /// primer returned.
    func record(_ then: (Route) async -> Void) async -> (events: [(type: CGEventType, t: TimeInterval)], primerDone: TimeInterval) {
        let route = Route(pid: 424_301, wid: 424_302, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let saved = (Input.primed[route.wid], Input.primerUp, Hold.held[route.pid])
        defer { (Input.primed[route.wid], Input.primerUp, Hold.held[route.pid]) = saved }
        Input.primed[route.wid] = nil
        Hold.held[route.pid] = nil
        var events: [(type: CGEventType, t: TimeInterval)] = []
        Input.sink = { events.append(($0.type, ProcessInfo.processInfo.systemUptime)) }
        defer { Input.sink = nil }
        await Input.primer(route)
        let primerDone = ProcessInfo.processInfo.systemUptime
        await then(route)
        return (events, primerDone)
    }

    func testAClickRightAfterThePrimerWaitsForTheGap() async {
        let (events, primerDone) = await record { r in
            await Input.press(CGPoint(x: 200, y: 200), r, typist: Typist(wpm: 0))
        }
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        let up = events[1].t
        XCTAssertLessThan(primerDone - up, 0.03, "the primer doesn't wait after its click")
        XCTAssertGreaterThanOrEqual(events[2].t - up, Input.primerGap - 0.002, "the real click waited for the gap")
    }

    func testModifierKeysRightAfterThePrimerWaitForTheGap() async {
        if Keys.layout.isEmpty { Keys.prepare() }
        let saved = Input.held
        defer { Input.held = saved }
        Input.held = []
        let (events, _) = await record { r in
            let mods = await Input.pressModifiers(.maskShift, r, typist: Typist(wpm: 0))
            await Input.releaseModifiers(mods, r, typist: Typist(wpm: 0))
        }
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .flagsChanged, .flagsChanged])
        XCTAssertGreaterThanOrEqual(events[2].t - events[1].t, Input.primerGap - 0.002, "Shift waited for the gap")
    }

    func testTimeSpentOnTheWayCountsTowardTheGap() async {
        var waited: TimeInterval = -1
        let (events, _) = await record { r in
            await Input.sleep(0.08)  // the pointer's travel and aim
            let t0 = ProcessInfo.processInfo.systemUptime
            await Input.afterPrimer()
            waited = ProcessInfo.processInfo.systemUptime - t0
            await Input.press(CGPoint(x: 200, y: 200), r, typist: Typist(wpm: 0))
        }
        XCTAssertEqual(events.count, 4)
        XCTAssertLessThan(waited, 0.01, "nothing left to wait")
    }
}
