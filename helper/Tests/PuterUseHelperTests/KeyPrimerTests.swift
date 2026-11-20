import XCTest

@testable import PuterUseHelper

/// The click a keyboard act on a held background app spends on its window first (`Handlers.keyPrimer`).
final class KeyPrimerTests: XCTestCase {
    func primer(_ focused: CGWindowID?, fresh: Bool, agent: Set<CGWindowID> = []) -> Handlers.KeyPrimer {
        Handlers.keyPrimer(focused: focused, wid: 10, fresh: fresh, agentWindows: agent)
    }

    /// A new hold: AppKit has no key window although AX names this one, so cmd+a would go nowhere: spend one.
    func testANewHoldOnThisWindowSpendsOne() {
        XCTAssertEqual(primer(10, fresh: true), .freshHold)
        XCTAssertEqual(primer(nil, fresh: true), .freshHold, "no window has the keyboard")
    }

    /// Once a click has made it key (the hold isn't fresh), nothing to do.
    func testAnEarlierHoldNeedsNone() {
        XCTAssertEqual(primer(10, fresh: false), .none)
        XCTAssertEqual(primer(nil, fresh: false), .none)
    }

    /// Another of the agent's windows has the keyboard: moved here, fresh or not.
    func testTheAgentsOtherWindowIsMovedFrom() {
        XCTAssertEqual(primer(11, fresh: false, agent: [11]), .fromAgentWindow)
        XCTAssertEqual(primer(11, fresh: true, agent: [10, 11]), .fromAgentWindow)
    }

    /// A window of the user's has it: never taken, even on a new hold (guardKeyboard stops the keys).
    func testTheUsersWindowIsNeverTakenFrom() {
        XCTAssertEqual(primer(12, fresh: true), .none)
        XCTAssertEqual(primer(12, fresh: false, agent: [11]), .none)
    }
}

/// The new hold's click (`Handlers.primeKeys`), spent where the first key or menu command goes out (after its
/// checks), not at the start of the batch. Events go to `Input.sink`, not to an app.
@MainActor final class PrimeKeysTests: XCTestCase {
    /// What `primeKeys` sends for `r` with the app held on `held` (a new hold if `fresh`), called `times` times.
    func sent(_ r: Route, held: CGWindowID?, fresh: Bool, times: Int = 1) async -> (types: [CGEventType], freshAfter: Bool) {
        let saved = (Hold.held, Hold.fresh)
        defer { (Hold.held, Hold.fresh) = saved }
        Hold.held[r.pid] = held
        if fresh { Hold.fresh.insert(r.pid) } else { Hold.fresh.remove(r.pid) }
        var types: [CGEventType] = []
        Input.sink = { types.append($0.type) }
        defer { Input.sink = nil }
        for _ in 0..<times { await Handlers.primeKeys(r) }
        return (types, Hold.fresh.contains(r.pid))
    }

    func route(_ wid: CGWindowID, foreground: Bool = false, primer: Bool = true) -> Route {
        Route(pid: 424_301, wid: wid, frame: CGRect(x: 100, y: 200, width: 300, height: 300), foreground: foreground,
              primer: primer)
    }

    /// A new hold on this window: one click (down, up), once; it ends the new hold.
    func testANewHoldClicksOnceBeforeTheFirstKey() async {
        let (types, freshAfter) = await sent(route(91), held: 91, fresh: true, times: 3)
        XCTAssertEqual(types, [.leftMouseDown, .leftMouseUp])
        XCTAssertFalse(freshAfter)
    }

    /// Nothing for an earlier hold, a hold on another window, a foreground action, or a menu's own route.
    func testOtherwiseNothingIsClicked() async {
        let none: [CGEventType] = []
        var r = await sent(route(92), held: 92, fresh: false)
        XCTAssertEqual(r.types, none, "an earlier hold: its window is key")
        r = await sent(route(93), held: 94, fresh: true)
        XCTAssertEqual(r.types, none, "held on another window")
        r = await sent(route(95), held: nil, fresh: true)
        XCTAssertEqual(r.types, none, "not held (the user's front app)")
        r = await sent(route(96, foreground: true), held: 96, fresh: true)
        XCTAssertEqual(r.types, none, "foreground: the real keyboard")
        r = await sent(route(97, primer: false), held: 97, fresh: true)
        XCTAssertEqual(r.types, none, "a menu or popover's route")
    }
}
