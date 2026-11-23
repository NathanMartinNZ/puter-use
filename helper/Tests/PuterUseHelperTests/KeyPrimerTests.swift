import XCTest

@testable import PuterUseHelper

/// The click a keyboard act spends on its window first (`Handlers.keyPrimer`), the act's window being 10.
final class KeyPrimerTests: XCTestCase {
    func primer(_ focused: CGWindowID?, fresh: Bool, agent: Set<CGWindowID> = [], shared: Set<CGWindowID> = [],
                front: Bool = false, quiet: Bool = true) -> Handlers.KeyPrimer {
        Handlers.keyPrimer(focused: focused, wid: 10, fresh: fresh, front: front, quiet: quiet) { id in
            shared.contains(id) ? .shared : agent.contains(id) ? .agent : .user
        }
    }

    /// A new hold: AppKit has no key window although AX names this one, so cmd+a would go nowhere: spend one.
    func testANewHoldOnThisWindowSpendsOne() {
        XCTAssertEqual(primer(10, fresh: true), .freshHold)
        XCTAssertEqual(primer(nil, fresh: true), .freshHold, "no window has the keyboard")
        XCTAssertEqual(primer(10, fresh: true, front: true), .none, "the user's front app is never held")
    }

    /// Once a click has made it key (the hold isn't fresh), nothing to do.
    func testAnEarlierHoldNeedsNone() {
        XCTAssertEqual(primer(10, fresh: false), .none)
        XCTAssertEqual(primer(nil, fresh: false), .none)
    }

    /// Another of the agent's windows has the keyboard: moved here, fresh or not, whoever's window this is. In the
    /// user's front app only while they leave the keyboard and mouse alone.
    func testTheAgentsOtherWindowIsMovedFrom() {
        XCTAssertEqual(primer(11, fresh: false, agent: [11]), .fromAgentWindow)
        XCTAssertEqual(primer(11, fresh: true, agent: [10, 11]), .fromAgentWindow)
        XCTAssertEqual(primer(11, fresh: false, agent: [10, 11], front: true), .fromAgentWindow)
        XCTAssertEqual(primer(11, fresh: false, agent: [10, 11], front: true, quiet: false), .none, "they may be typing there")
    }

    /// A window of the user's has it, and the app is in the background: moved to the agent's own window, never to
    /// one of theirs, nor to one of the agent's they've used.
    func testTheUsersWindowIsMovedFromOnlyInTheBackgroundToTheAgentsOwn() {
        XCTAssertEqual(primer(12, fresh: false, agent: [10]), .fromUserWindow)
        XCTAssertEqual(primer(12, fresh: true, agent: [10]), .fromUserWindow, "the primer ends the new hold too")
        XCTAssertEqual(primer(12, fresh: true), .none, "this one is the user's too")
        XCTAssertEqual(primer(12, fresh: false, agent: [11]), .none)
        XCTAssertEqual(primer(12, fresh: false, agent: [10], shared: [10]), .none, "the user has used this one")
    }

    /// While the app is the user's front app, their keyboard stays where it is.
    func testTheUsersWindowIsNeverTakenFromInTheirFrontApp() {
        XCTAssertEqual(primer(12, fresh: false, agent: [10], front: true), .none)
        XCTAssertEqual(primer(12, fresh: false, agent: [10], front: true, quiet: true), .none)
    }

    /// One of the agent's windows the user has used counts as theirs: never moved off while they may be in the app,
    /// and in the background only to the agent's own window.
    func testAWindowTheUserHasUsedIsTheirsToMoveFrom() {
        XCTAssertEqual(primer(11, fresh: false, agent: [10, 11], shared: [11], front: true), .none)
        XCTAssertEqual(primer(11, fresh: false, agent: [10, 11], shared: [11]), .fromUserWindow)
        XCTAssertEqual(primer(11, fresh: false, agent: [11], shared: [11]), .none, "to the user's window: no")
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
