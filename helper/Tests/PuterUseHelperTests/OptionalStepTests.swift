import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// `optional: true` on an action aimed by target: skipped, and the batch goes on, when nothing in the window shows
/// what it names. Where it can go is checked before the batch runs (`Handlers.optionalProblem`); what skips it at
/// run time is a clean miss of its own target and nothing else (`Handlers.skipsOptional`).
@MainActor
final class OptionalStepTests: XCTestCase {
    /// Every action that names one element by target takes it: no unknown key, nothing refused.
    func testTargetActionsTakeOptional() {
        let ok: [[String: Any]] = [
            ["type": "click", "target": "Accept all", "optional": true],
            ["type": "click", "target": ["text": "Close", "role": "button"], "optional": true, "confirm": true],
            ["type": "double_click", "target": "Row", "optional": true], ["type": "right_click", "target": "Row", "item": "Copy", "optional": true],
            ["type": "left_click", "target": "OK", "optional": true], ["type": "move", "target": "Help", "optional": true],
            ["type": "hover", "target": "Help", "optional": true], ["type": "scroll", "target": "List", "scroll_y": 300, "optional": true],
            ["type": "type", "target": "Coupon", "text": "SAVE10", "optional": true],
            ["type": "select", "target": "Country", "option": "NZ", "optional": true],
            ["type": "set_value", "target": "Volume", "text": "5", "optional": true], ["type": "focus", "target": "Name", "optional": true],
            ["type": "perform", "target": "Details", "name": "expand", "optional": true],
            ["type": "read", "target": "Notes", "optional": true],
        ]
        for a in ok {
            XCTAssertNil(Handlers.invalid(a), "\(a)")
            XCTAssertTrue(Handlers.optionalStep(a), "\(a)")
        }
    }

    /// False or null is the same as leaving it out, on any action.
    func testFalseOrNullIsNoOptional() {
        for a: [String: Any] in [
            ["type": "click", "x": 3, "y": 4, "optional": false], ["type": "keypress", "keys": "cmd+s", "optional": NSNull()],
            ["type": "click", "target": "OK", "optional": false],
        ] {
            XCTAssertNil(Handlers.invalid(a), "\(a)")
            XCTAssertFalse(Handlers.optionalStep(a), "\(a)")
        }
    }

    /// Never by coordinates or an element number (what's at a point is always something), never on an action that
    /// names no element by what it shows, never on a fill's field, and never as anything but true or false.
    func testOptionalIsRefusedWhereItCantGo() {
        let refused: [[String: Any]] = [
            ["type": "click", "x": 3, "y": 4, "optional": true], ["type": "click", "coordinate": [3, 4], "optional": true],
            ["type": "click", "element": 7, "optional": true], ["type": "click", "target": "OK", "x": 3, "y": 4, "optional": true],
            ["type": "click", "optional": true], ["type": "keypress", "keys": "Escape", "optional": true],
            ["type": "navigate", "url": "https://example.com", "optional": true], ["type": "wait_for", "text": "Done", "optional": true],
            ["type": "drag", "path": [[1, 2], [3, 4]], "optional": true],
            ["type": "mouse_down", "target": "Handle", "optional": true], ["type": "mouse_up", "target": "Slot", "optional": true],
            ["type": "fill", "fields": [["target": "Email", "text": "a@b.c"]], "optional": true],
            ["type": "click", "target": "OK", "optional": "yes"],
        ]
        for a in refused {
            XCTAssertNotNil(Handlers.invalid(a), "\(a)")
            XCTAssertFalse(Handlers.optionalStep(a), "\(a)")
        }
        let field: [String: Any] = ["type": "fill", "fields": [["target": "Email", "text": "a"], ["target": "Coupon", "text": "x", "optional": true]]]
        XCTAssertEqual(Handlers.invalid(field)?.hasPrefix("field 2 has optional"), true)
        XCTAssertTrue(Handlers.invalid(["type": "click", "x": 3, "y": 4, "optional": true])?.contains("without target") == true)
    }

    /// The key is known to every action (not refused as unknown before the placement check says why).
    func testOptionalIsAKeyEveryActionHas() {
        XCTAssertTrue(Handlers.everyAction.contains("optional"))
        XCTAssertNil(Handlers.unknownKeys(["type": "keypress", "keys": "a", "optional": true]))
    }

    /// Skipped only for a clean miss (`Missing`) of the step's own target, before anything was found: not for
    /// several matches, one behind a dialog, a refusal, a stop for the user's OK, a search that stopped early, or
    /// anything after the target was found.
    func testOnlyACleanMissOfItsOwnTargetSkips() {
        let step: [String: Any] = ["type": "click", "target": "Accept all", "optional": true]
        let missing = Handlers.Missing(description: "nothing shows \"Accept all\" in the window")
        XCTAssertTrue(Handlers.skipsOptional(step, missing, found: false))
        XCTAssertFalse(Handlers.skipsOptional(step, missing, found: true), "a miss after the target was found")
        XCTAssertFalse(Handlers.skipsOptional(["type": "click", "target": "Accept all"], missing, found: false), "not optional")
        XCTAssertFalse(Handlers.skipsOptional(["type": "click", "x": 1, "y": 2, "optional": true], missing, found: false))
        for other: Error in [
            HelperError("\"OK\" matches 3 elements: …"), Handlers.Behind(description: "\"OK\" is behind a sheet"),
            Policy.NeedsOK(label: "Delete", word: "delete"), HelperError("not allowed: puter-use's policy …"),
            Handlers.NotFound(description: "nothing shows \"OK\" in the window", offScreen: "; the search stopped early"),
        ] {
            XCTAssertFalse(Handlers.skipsOptional(step, other, found: false), "\(other)")
        }
    }

    /// A miss is clean only with nothing off screen showing it and a search that looked everywhere; it reads as
    /// the error it stands for, similar labels and all.
    func testAMissIsMissingOnlyWhenNothingShowsIt() throws {
        let none = Handlers.NotFound(description: "nothing shows \"Accept\" in the window", near: "; similar (…): [3] button \"Allow\"")
        XCTAssertTrue(none.clean)
        let clean = try Handlers.missError(none, "Accept", .screen)
        XCTAssertTrue(clean is Handlers.Missing)
        XCTAssertEqual("\(clean)", "nothing shows \"Accept\" in the window; similar (…): [3] button \"Allow\"")

        let away = Handlers.NotFound(description: "nothing shows \"Accept\" in the window", offScreen: "; off screen: [4] button …")
        XCTAssertFalse(away.clean)
        XCTAssertTrue(try Handlers.missError(away, "Accept", .screen) is HelperError, "candidates off screen: several, or unclear")
        let cut = Handlers.NotFound(description: "nothing shows \"Accept\" in the window", offScreen: "; the search stopped early …")
        XCTAssertTrue(try Handlers.missError(cut, "Accept", .screen) is HelperError, "not everything was looked at")
    }

    /// A lookup says it found its target to the action's tracker, so a later miss isn't taken for the step's own.
    func testTheTrackerIsTheActionsOwn() {
        let mine = TargetLookup()
        TargetLookup.$current.withValue(mine) {
            TargetLookup.current?.found = true
        }
        XCTAssertTrue(mine.found)
        XCTAssertNil(TargetLookup.current, "outside the action, there's none")
    }
}
