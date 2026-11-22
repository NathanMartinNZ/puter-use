import Foundation
import XCTest

@testable import PuterUseHelper

/// The check act makes of a scroll until a text shows (`until`, with `max_scrolls`) before any of the batch runs
/// (`Handlers.invalid`): it needs no distance, but an until it can't read, a max_scrolls outside 1-15 or without until,
/// optional, or keys held are refused, each with a one-line reason.
final class ScrollUntilKeysTests: XCTestCase {
    let unreadable = "has an until it can't read: until is the text to scroll until it shows, \"Total\" or "
        + "{\"text\": \"Total\", \"role\": \"button\"}"
    let none = "would scroll 0 px: give scroll_y (pixels, positive = down) and/or scroll_x, or direction (up, down, left, right) "
        + "with amount"

    /// Every way it's written passes: until as text or {text, role}, with max_scrolls, a direction, a distance, an aim.
    func testAScrollUntilPasses() {
        let ok: [[String: Any]] = [
            ["type": "scroll", "until": "Total"],
            ["type": "scroll", "until": ["text": "Total", "role": "button"]],
            ["type": "scroll", "until": ["text": "Total"], "max_scrolls": 1],
            ["type": "scroll", "until": "Total", "max_scrolls": 15],
            ["type": "scroll", "until": "Total", "max_scrolls": 10, "direction": "up"],
            ["type": "scroll", "until": "Total", "scroll_y": 600, "target": "Results"],
            ["type": "scroll", "until": "Total", "element": 7, "direction": "down", "amount": 5],
            ["type": "scroll", "until": ["text": "Total", "role": NSNull()], "max_scrolls": NSNull()],
            ["type": "scroll", "until": "Total", "keys": [] as [Any]],
        ]
        for a in ok { XCTAssertNil(Handlers.invalid(a), "\(a)") }
        let json = (try? JSONSerialization.jsonObject(with: Data(#"{"type": "scroll", "until": "Total", "max_scrolls": 3}"#.utf8)))
            as? [String: Any] ?? [:]
        XCTAssertNil(Handlers.invalid(json))
    }

    /// A scroll without until is checked as before: no distance is still 0 px, and a null until is none.
    func testWithoutUntilAScrollStillNeedsADistance() {
        XCTAssertEqual(Handlers.invalid(["type": "scroll"]), none)
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "until": NSNull()]), none)
        XCTAssertNil(Handlers.invalid(["type": "scroll", "until": NSNull(), "scroll_y": 300]))
    }

    /// A distance given with until still has to move: 0, or an amount with no direction, is refused as ever.
    func testADistanceGivenWithUntilStillHasToMove() {
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "until": "Total", "scroll_y": 0]), none)
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "until": "Total", "amount": 3]), none)
    }

    /// An until that isn't non-empty text or {text, role?} with non-empty text and a text role is refused.
    func testAnUntilItCantReadIsRefused() {
        let bad: [Any] = ["", "   ", 5, true, ["Total"], ["role": "button"], ["text": ""], ["text": 5], ["text": "Total", "role": 3],
                         ["text": "Total", "nth": 2]]
        for u in bad { XCTAssertEqual(Handlers.invalid(["type": "scroll", "until": u]), unreadable, "\(u)") }
    }

    /// max_scrolls is a whole number from 1 to 15, and only with until.
    func testMaxScrollsIsAWholeNumberFromOneToFifteen() {
        func why(_ m: Any) -> String? { Handlers.invalid(["type": "scroll", "until": "Total", "max_scrolls": m]) }
        XCTAssertEqual(why(0), "has max_scrolls 0: it's a whole number from 1 to 15")
        XCTAssertEqual(why(16), "has max_scrolls 16: it's a whole number from 1 to 15")
        XCTAssertEqual(why(-1), "has max_scrolls -1: it's a whole number from 1 to 15")
        XCTAssertEqual(why(2.5), "has max_scrolls 2.5: it's a whole number from 1 to 15")
        XCTAssertEqual(why("5"), "has max_scrolls \"5\": it's a whole number from 1 to 15")
        XCTAssertTrue(why(true)?.hasSuffix(": it's a whole number from 1 to 15") == true, "true isn't a number")
        XCTAssertNil(why(15.0), "a whole number written with .0")
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "scroll_y": 300, "max_scrolls": 5]),
                       "has max_scrolls without until: it's how many times a scroll until a text shows may scroll")
    }

    /// A scroll until a text shows can't be optional (what it looks for isn't there yet), so it's never skipped.
    func testUntilWithOptionalIsRefused() {
        let both: [String: Any] = ["type": "scroll", "target": "Results", "until": "Total", "optional": true]
        XCTAssertEqual(Handlers.invalid(both), "can't be optional with until: optional skips a step whose target isn't there, and "
            + "until scrolls to find text that isn't there yet")
        XCTAssertFalse(Handlers.optionalStep(both), "a saved macro's step with both runs as a plain step")
        XCTAssertNil(Handlers.invalid(["type": "scroll", "target": "Results", "until": "Total", "optional": false]))
    }

    /// Keys held are refused for it as for any scroll.
    func testUntilWithKeysIsRefused() {
        let hint = "can't hold keys: to scroll sideways give scroll_x (or direction left/right); to zoom use the app's zoom "
            + "shortcut or menu"
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "until": "Total", "keys": ["shift"]]), hint)
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "until": "Total", "modifiers": "cmd"]), hint)
    }

    /// A typo of its keys is named with what it meant; the keys a scroll's error lists include until and max_scrolls.
    func testATypoIsNamedWithWhatItMeant() {
        XCTAssertTrue(Handlers.invalid(["type": "scroll", "untill": "Total"])?.contains("(did you mean until?)") == true)
        XCTAssertTrue(Handlers.invalid(["type": "scroll", "until": "Total", "max_scroll": 3])?.contains("(did you mean max_scrolls?)") == true)
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "delta_y": 500]),
                       "has an unknown key \"delta_y\" (did you mean scroll_y?): scroll takes x, y, element, target, scroll_x, "
                           + "scroll_y, direction, amount, until, max_scrolls")
    }
}
