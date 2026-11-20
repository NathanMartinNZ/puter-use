import XCTest

@testable import PuterUseHelper

/// The wait before an act with no screenshot looks for a window its actions opened (`Handlers.followWait`).
final class FollowWaitTests: XCTestCase {
    func wait(_ actions: [[String: Any]], done: Int? = nil, failed: Bool = false) -> Double {
        Handlers.followWait(actions, done: done ?? actions.count, failed: failed)
    }

    /// Nothing ran: there's nothing to follow, so no wait, whatever the action was.
    func testNothingRanWaitsNot() {
        XCTAssertEqual(wait([["type": "click", "target": "No such button"]], done: 0, failed: true), 0)
        XCTAssertEqual(wait([["type": "keypress", "keys": "cmd+n"]], done: 0, failed: true), 0)
    }

    /// Actions that can't open anything leave only a short gap.
    func testActionsThatCantOpenAWindowWaitBriefly() {
        for a: [String: Any] in [
            ["type": "type", "target": "Name", "text": "Ada"], ["type": "scroll", "direction": "down"],
            ["type": "set_value", "target": "Name", "value": "x"], ["type": "clipboard"],
            ["type": "wait_for", "text": "Done"], ["type": "keypress", "keys": "a"],
        ] {
            XCTAssertEqual(wait([a]), 0.05, "\(a)")
        }
    }

    /// A click, a shortcut or Return may open a window: long enough for it to show up and be followed.
    func testActionsThatMayOpenAWindowWaitLonger() {
        for a: [String: Any] in [
            ["type": "click", "target": "New Window"], ["type": "keypress", "keys": "cmd+n"],
            ["type": "type", "text": "x", "submit": true], ["type": "menu", "path": "File > New"],
        ] {
            XCTAssertEqual(wait([["type": "type", "text": "a"], a]), 0.2, "\(a)")
        }
    }

    /// key_down cmd, then n, opens a window although none of the three actions is a shortcut by itself.
    func testHeldKeysCountAsAShortcut() {
        let chord: [[String: Any]] = [
            ["type": "key_down", "keys": "cmd"], ["type": "keypress", "keys": "n"], ["type": "key_up", "keys": "cmd"],
        ]
        XCTAssertEqual(wait(chord), 0.2)
    }

    /// Only what ran counts, plus an action that failed partway (it may have pressed something first).
    func testOnlyWhatRanCounts() {
        let batch: [[String: Any]] = [["type": "type", "text": "a"], ["type": "click", "target": "Open"]]
        XCTAssertEqual(wait(batch, done: 1), 0.05, "stopped before the click")
        XCTAssertEqual(wait(batch, done: 1, failed: true), 0.2, "the click failed partway")
    }
}
