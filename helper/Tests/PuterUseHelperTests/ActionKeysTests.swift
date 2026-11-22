import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The check act makes of each action as the agent gave it, before any of the batch runs (`Handlers.invalid`):
/// a kind no action has, a key its kind doesn't read (in fill's fields too), or a scroll of 0 px, each named
/// with what it most likely meant. Every way an action is written still passes: the docs', the MCP schema's,
/// the CLI's and api.py's, OpenAI's and Anthropic's computer-use shapes, older names, a saved macro step's
/// keys, and what an agent notes on an action for itself.
final class ActionKeysTests: XCTestCase {
    /// Each action as the docs and the MCP schema write it.
    static let documented: [[String: Any]] = [
        ["type": "click", "x": 10, "y": 20, "button": "right", "keys": ["shift"], "item": "Red"],
        ["type": "click", "target": ["text": "Save", "role": "button", "nth": 2], "confirm": true],
        ["type": "click", "element": 4, "count": 2],
        ["type": "double_click", "element": 4], ["type": "triple_click", "x": 1, "y": 2],
        ["type": "right_click", "target": "Row", "item": "Copy"], ["type": "middle_click", "x": 1, "y": 2],
        ["type": "move", "x": 1, "y": 2], ["type": "drag", "path": [[1, 2], [3, 4]], "button": "left", "keys": "option"],
        ["type": "scroll", "x": 1, "y": 2, "scroll_y": 300], ["type": "scroll", "target": "List", "scroll_x": -40],
        ["type": "scroll", "element": 7, "scroll_y": 120],
        ["type": "type", "text": "hi"], ["type": "type", "text": "hi", "target": "Name", "clear": true, "submit": true],
        ["type": "type", "text": "x", "element": 3], ["type": "type", "text": "x", "x": 3, "y": 4],
        ["type": "type", "text": "example.com\n", "timeout_ms": 20000],
        ["type": "keypress", "keys": "cmd+t", "repeat": 3], ["type": "keypress", "keys": ["ctrl", "a"]],
    ]

    static let documented2: [[String: Any]] = [
        ["type": "key_down", "keys": "shift"], ["type": "key_up"], ["type": "key_up", "keys": "shift"],
        ["type": "hold_key", "keys": "shift", "ms": 500],
        ["type": "mouse_down", "x": 1, "y": 2, "keys": "shift", "button": "left"], ["type": "mouse_up"],
        ["type": "mouse_up", "x": 3, "y": 4], ["type": "mouse_up", "button": "right"],
        ["type": "menu", "item": "File > Export as PDF…"], ["type": "menu", "item": ["View", "Zoom In"]],
        ["type": "select", "target": "Country", "option": "NZ"],
        ["type": "navigate", "url": "https://example.com", "new_window": false, "timeout_ms": 20000],
        ["type": "open", "url": "https://example.com"], ["type": "open", "path": "~/a.pdf", "app": "Preview"],
        ["type": "wait_for", "text": "Done", "role": "text", "gone": true, "timeout_ms": 900],
        ["type": "wait_for", "change": true, "timeout_ms": 4000],
        ["type": "clipboard"], ["type": "clipboard", "offset": 10000, "limit": 2000], ["type": "clipboard", "text": "hi"],
    ]

    static let documented3: [[String: Any]] = [
        ["type": "paste", "text": "hi"], ["type": "set_value", "element": 3, "text": "5"], ["type": "focus", "target": "Name"],
        ["type": "perform", "element": 3, "name": "expand"], ["type": "wait", "ms": 500], ["type": "activate"],
        ["type": "close_window"], ["type": "macro", "name": "export pdf", "vars": ["file": "q4.pdf"], "confirm": true],
        ["type": "fill", "fields": [["target": "Email", "text": "a@b.c"], ["element": 5, "option": "NZ"],
                                    ["target": "Agree", "checked": true], ["target": "Name", "text": "Ada", "clear": false]],
         "submit": "Send"],
        ["type": "fill", "fields": [["element": 3, "value": "Ada"], ["element": 4, "select": "Blue", "confirm": true]],
         "submit": true, "confirm": true],
        ["type": "fill", "fields": [["type": "type", "target": "Name", "text": "Ada"]], "submit": 9],
    ]

    /// Anthropic's and OpenAI's computer-use shapes.
    static let computerUse: [[String: Any]] = [
        ["action": "left_click", "coordinate": [10, 20]], ["action": "double_click", "coordinate": [1, 2]],
        ["action": "triple_click", "coordinate": [1, 2]], ["action": "right_click", "coordinate": [1, 2]],
        ["action": "middle_click", "coordinate": [1, 2]], ["action": "mouse_move", "coordinate": [1, 2]],
        ["action": "left_click_drag", "start_coordinate": [1, 2], "coordinate": [3, 4]],
        ["action": "scroll", "coordinate": [1, 2], "scroll_direction": "down", "scroll_amount": 5],
        ["action": "key", "text": "ctrl+s"], ["action": "type", "text": "hi"],
        ["action": "hold_key", "text": "shift", "duration": 1], ["action": "wait", "duration": 1], ["action": "screenshot"],
        ["type": "click", "action": "left_click", "x": 1, "y": 2],  // a translated call, its kind kept as action too
        ["type": "click", "button": "left", "x": 1, "y": 2], ["type": "double_click", "x": 1, "y": 2],
        ["type": "drag", "path": [["x": 1, "y": 2], ["x": 3, "y": 4]]], ["type": "keypress", "keys": ["CTRL", "A"]],
        ["type": "scroll", "x": 1, "y": 2, "scroll_x": 0, "scroll_y": 300], ["type": "type", "text": "hi"],
        ["type": "wait"], ["type": "screenshot"], ["type": "move", "x": 1, "y": 2],
        // Anthropic's click holds the modifier keys in its text; OpenAI's scroll and move carry keys (empty: none).
        ["action": "left_click", "coordinate": [10, 20], "text": "shift"], ["action": "right_click", "coordinate": [1, 2], "text": "ctrl"],
        ["action": "double_click", "coordinate": [1, 2], "text": "alt"], ["action": "triple_click", "coordinate": [1, 2], "text": "super"],
        ["action": "middle_click", "coordinate": [1, 2], "text": "shift+ctrl"], ["type": "click", "x": 1, "y": 2, "text": "cmd"],
        ["type": "scroll", "x": 1, "y": 2, "scroll_x": 0, "scroll_y": 300, "keys": [] as [Any]],
        ["type": "move", "x": 1, "y": 2, "keys": [] as [Any]], ["type": "move", "x": 1, "y": 2, "keys": ["shift"]],
    ]

    /// What an agent notes on an action for itself, on any kind and in a fill's fields: read by nothing.
    static let notes: [[String: Any]] = [
        ["type": "click", "target": "Save", "reason": "save the draft"],
        ["action": "left_click", "coordinate": [1, 2], "description": "the Save button"],
        ["type": "scroll", "scroll_y": 300, "comment": "to the end of the list"], ["type": "keypress", "keys": "cmd+s", "note": "save"],
        ["type": "activate", "reason": "focus it"], ["type": "wait", "ms": 500, "reason": "let it load", "note": ["slow": true]],
        ["type": "fill", "fields": [["target": "Name", "text": "Ada", "comment": "first name"]], "description": "the form"],
    ]

    /// Other names the helper reads them by.
    static let aliases: [[String: Any]] = [
        ["type": "scroll", "dy": 100], ["type": "scroll", "dx": -100], ["type": "scroll", "direction": "up", "amount": 2],
        ["type": "keypress", "key": "Return", "times": 2], ["type": "key", "text": "Tab"], ["type": "key_down", "key": "cmd"],
        ["type": "hold", "keys": "a", "seconds": 1], ["type": "hold_key", "keys": "a", "duration": 0.5],
        ["type": "menu", "path": ["View", "Zoom In"]], ["type": "menu_item", "text": "Copy"],
        ["type": "choose", "element": 2, "value": "Blue"], ["type": "select", "element": 2, "text": "Blue"],
        ["type": "goto", "url": "x.com"], ["type": "go_to", "url": "x.com"], ["type": "open_url", "url": "https://a.b"],
        ["type": "launch", "app": "Notes"], ["type": "open", "file": "/tmp/a.txt"],
        ["type": "waitfor", "label": "Done", "ms": 500], ["type": "type_text", "value": "hi"], ["type": "type", "value": "hi"],
    ]

    static let aliases2: [[String: Any]] = [
        ["type": "click", "clicks": 2, "modifiers": "cmd", "coordinate": [1, 2]], ["type": "left_click", "x": 1, "y": 2],
        ["type": "drag", "from": [1, 2], "to": [3, 4]], ["type": "drag", "start": [1, 2], "end": [3, 4], "modifiers": "option"],
        ["type": "drag", "x": 1, "y": 2, "to": [3, 4]], ["type": "left_click_drag", "start_coordinate": [1, 2], "coordinate": [3, 4]],
        ["type": "ax", "element": 1, "ax_action": "AXShowMenu"], ["type": "secondary", "target": "x"],
        ["type": "set_value", "target": "Size", "value": "12"], ["type": "sleep", "seconds": 1], ["type": "wait", "duration": 2],
        ["type": "raise"], ["type": "focus_window"], ["type": "close"], ["type": "macro", "macro": "x"],
        ["type": "hover", "element": 2], ["type": "mouse_move", "x": 1, "y": 2], ["type": "press_key", "keys": "a"],
        ["type": "hotkey", "keys": "cmd+s"], ["type": "keyup", "keys": "a"], ["type": "keydown", "keys": "a"],
        ["type": "mouse_down", "element": 3, "modifiers": "shift"], ["type": "Click", "x": 1, "y": 2],
    ]

    /// The CLI's and api.py's.
    static let clients: [[String: Any]] = [
        ["type": "click", "button": "middle", "keys": ["cmd", "shift"], "item": "Font > Bold", "confirm": true, "element": 3],
        ["type": "scroll", "scroll_y": 10, "scroll_x": 0, "x": 1.5, "y": 2.5],
        ["type": "scroll", "scroll_y": 0, "scroll_x": 20, "target": "List"],
        ["type": "wait_for", "timeout_ms": 5000, "text": "Done", "gone": true, "role": "button"],
        ["type": "perform", "element": 1, "name": "showmenu", "confirm": true],
        ["type": "macro", "name": "x", "vars": ["a": "1"], "confirm": true],
        ["type": "fill", "fields": [["target": "Subscribe", "checked": true], ["target": "Name", "text": "Ada"]], "submit": "Go",
         "confirm": true],
    ]

    /// What a saved macro step adds, and puter-use's own keys.
    static let saved: [[String: Any]] = [
        ["type": "click", "target": ["text": "Save", "role": "button"], "x": 120.5, "y": 40, "units": "pt", "spot": true],
        ["type": "click", "x": 120.5, "y": 40, "units": "pt", "over": 0],
        ["type": "scroll", "x": 1, "y": 2, "units": "pt", "over": 1, "scroll_y": 300],
        ["type": "drag", "path": [[1, 2], [3, 4]], "units": "pt", "over": 0],
        ["type": "drag", "from": [1, 2], "to": [3, 4], "units": "pt", "over": 2],
        ["type": "type", "text": "x", "target": ["text": "Name", "role": "field"], "x": 1, "y": 2, "units": "pt", "spot": true],
        ["type": "select", "target": ["text": "Size", "role": "popup"], "x": 1, "y": 2, "units": "pt", "option": "{{size}}"],
        ["type": "set_value", "x": 1, "y": 2, "units": "pt", "over": 0, "text": "5"],
        ["type": "fill", "fields": [["target": ["text": "Name", "role": "field"], "x": 1, "y": 2, "units": "pt", "spot": true,
                                     "text": "{{name}}"], ["x": 1, "y": 2, "units": "pt", "over": 0, "text": "a"]],
         "submit": ["target": ["text": "Send", "role": "button"], "x": 1, "y": 2, "units": "pt"]],
        ["type": "menu", "item": "View > Toggle Thing"],
        ["type": "click", "x": 1, "y": 2, "_last": true, "_node": 1, "_pointer": true],  // (a client's are dropped)
    ]

    /// A key nothing reads, with a value that says nothing (a client filling in every field).
    static let emptyValues: [[String: Any]] = [
        ["type": "click", "x": 1, "y": 2, "text": "", "fields": [] as [Any], "vars": [:] as [String: Any], "path": NSNull()],
        ["type": "scroll", "scroll_y": 300, "keys": [] as [Any]],
    ]

    func testEveryWayAnActionIsWrittenPasses() {
        let groups = [Self.documented, Self.documented2, Self.documented3, Self.computerUse, Self.aliases, Self.aliases2,
                      Self.clients, Self.saved, Self.emptyValues, Self.notes]
        for a in groups.joined() { XCTAssertNil(Handlers.invalid(a), "\(a)") }
    }

    /// A key the kind doesn't read is refused, named, with the key it most likely meant and what the kind takes.
    func testAKeyItsKindDoesntReadIsNamedWithWhatItMeant() {
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "delta_y": 500]),
                       "has an unknown key \"delta_y\" (did you mean scroll_y?): scroll takes x, y, element, target, scroll_x, "
                           + "scroll_y, direction, amount, until, max_scrolls")
        XCTAssertEqual(Handlers.invalid(["type": "click", "target": "Sort", "menu_item": "Date"]),
                       "has an unknown key \"menu_item\" (did you mean item?): click takes x, y, element, target, button, keys, item")
        let meant: [([String: Any], String)] = [
            (["type": "click", "text": "Save"], "target"), (["type": "click", "label": "Save"], "target"),
            (["action": "left_click", "coordinate": [1, 2], "text": "shift+a"], "target"),  // not modifier keys alone
            (["type": "left_click", "id": 4], "element"), (["type": "click", "coordinates": [1, 2]], "coordinate"),
            (["type": "click", "x": 1, "y": 2, "key": "cmd"], "keys"), (["type": "click", "x": 1, "y": 2, "modifier": "cmd"], "modifiers"),
            (["type": "click", "target": "Sort", "option": "Date"], "item"),
            (["type": "type", "txt": "hi"], "text"), (["type": "type", "text": "hi", "into": "Name"], "target"),
            (["type": "type", "text": "hi", "press_enter": true], "submit"), (["type": "type", "text": "hi", "clear_first": true], "clear"),
            (["type": "keypress", "combo": "cmd+s"], "keys"), (["type": "keypress", "keys": "Tab", "count": 3], "repeat"),
            (["type": "hold_key", "keys": "a", "timeout": 500], "ms"), (["type": "wait", "time": 500], "ms"),
            (["type": "wait", "timeout": 5], "ms"),
            (["type": "navigate", "address": "x.com"], "url"), (["type": "navigate", "url": "x.com", "new_tab": true], "new_window"),
            (["type": "navigate", "url": "x.com", "timeout": 9000], "timeout_ms"),
            (["type": "open", "application": "Notes"], "app"), (["type": "select", "target": "Size", "item": "12"], "option"),
            (["type": "fill", "form": [["target": "Name", "text": "Ada"]]], "fields"),
            (["type": "macro", "name": "x", "variables": ["a": "1"]], "vars"),
            (["type": "menu", "menu_item": "Copy"], "item"),
            (["type": "scroll", "scroll_y": 3, "dir": "down"], "direction"),
            (["type": "perform", "element": 3, "action": "expand"], "name"),
        ]
        for (a, want) in meant {
            let why = Handlers.invalid(a) ?? ""
            XCTAssertTrue(why.hasPrefix("has an unknown key ") && why.contains("(did you mean \(want)?)"), "\(a): \(why)")
        }
    }

    /// No guess when nothing is close; one of act's own parameters is said to be act's; several are listed in order.
    func testNoGuessForAKeyNothingIsCloseTo() {
        XCTAssertEqual(Handlers.invalid(["type": "keypress", "keys": "Return", "x": 10, "y": 20]),
                       "has unknown keys \"x\", \"y\": keypress takes keys, repeat")
        XCTAssertEqual(Handlers.invalid(["type": "click", "x": 1, "y": 2, "window": "Safari"]),
                       "has an unknown key \"window\" (that's act's own parameter): click takes x, y, element, target, button, keys, item")
        XCTAssertEqual(Handlers.invalid(["type": "activate", "app": "Safari"]),
                       "has an unknown key \"app\": activate takes no keys")
        XCTAssertEqual(Handlers.invalid(["type": "drag", "target": "File", "to": [1, 2]]),
                       "has an unknown key \"target\": drag takes path, from, to, button, keys", "a drag goes by points")
        XCTAssertEqual(Handlers.invalid(["type": "move", "x": 1, "y": 2, "button": "left"]),
                       "has an unknown key \"button\": move takes x, y, element, target, keys")
        XCTAssertEqual(Handlers.invalid(["type": "key_down", "keys": "shift", "ms": 500]),
                       "has an unknown key \"ms\": key_down takes keys", "only hold_key holds for a time")
    }

    /// Notes (reason, description, comment, note) pass on every kind and change nothing: a typo beside one is
    /// still refused, and one never counts as keys held.
    func testNotesPassOnEveryKindAndChangeNothing() {
        for k in Handlers.actionKinds {
            var a: [String: Any] = ["type": k, "reason": "r", "description": "d", "comment": "c", "note": "n"]
            if k == "scroll" { a["scroll_y"] = 100 }
            XCTAssertNil(Handlers.invalid(a), k)
        }
        XCTAssertEqual(Handlers.invalid(["type": "scroll", "delta_y": 500, "reason": "to the end"]),
                       "has an unknown key \"delta_y\" (did you mean scroll_y?): scroll takes x, y, element, target, scroll_x, "
                           + "scroll_y, direction, amount, until, max_scrolls")
        let noted: [String: Any] = ["type": "click", "x": 1, "y": 2, "reason": "shift", "note": "cmd", "comment": "a", "description": "b"]
        XCTAssertNil(Handlers.modifierKeys(noted))
        XCTAssertFalse(Handlers.actsOnKeyboardFocus(noted))
    }

    /// A click's text that names modifier keys and nothing else is the keys it holds, as Anthropic's computer use
    /// gives them; keys win over it, and no other kind's text is read so.
    @MainActor func testAClicksModifierTextIsTheKeysItHolds() {
        func flags(_ a: [String: Any]) -> CGEventFlags { Handlers.modifierFlags(Handlers.modifierKeys(a)) }
        let shiftClick: [String: Any] = ["action": "left_click", "coordinate": [10, 20], "text": "shift"]
        XCTAssertNil(Handlers.invalid(shiftClick))
        XCTAssertEqual(flags(shiftClick), .maskShift)
        XCTAssertTrue(Handlers.actsOnKeyboardFocus(shiftClick), "the window gets the keyboard for them, as for keys")
        XCTAssertEqual(flags(["type": "right_click", "x": 1, "y": 2, "text": "ctrl+alt"]), [.maskControl, .maskAlternate])
        XCTAssertEqual(flags(["type": "double_click", "x": 1, "y": 2, "text": ["super", "Shift"]]), [.maskCommand, .maskShift])
        XCTAssertEqual(flags(["type": "click", "x": 1, "y": 2, "keys": "cmd", "text": "shift"]), .maskCommand, "keys win")
        XCTAssertEqual(flags(["type": "click", "x": 1, "y": 2, "keys": [] as [Any], "text": "shift"]), .maskShift, "empty keys say nothing")
        XCTAssertNil(Handlers.invalid(["type": "click", "x": 1, "y": 2, "keys": "cmd", "text": "shift"]))
        // Not modifier keys alone, or not a click: its text isn't keys held.
        XCTAssertNil(Handlers.modifierText(["type": "click", "x": 1, "y": 2, "text": "Save"]))
        XCTAssertNil(Handlers.modifierText(["type": "click", "x": 1, "y": 2, "text": "shift+a"]))
        XCTAssertNil(Handlers.modifierKeys(["type": "type", "text": "shift"]))
        XCTAssertNil(Handlers.modifierKeys(["type": "key_down", "text": "shift"]), "key_down reads its text as its own keys")
        XCTAssertNil(Handlers.modifierKeys(["type": "mouse_down", "x": 1, "y": 2, "text": "shift"]))
        XCTAssertFalse(Handlers.actsOnKeyboardFocus(["type": "click", "x": 1, "y": 2, "text": ""]))
    }

    /// A scroll can't hold keys (its events don't carry them): keys or modifiers on one are refused with what such
    /// a scroll is usually for. None (absent, null, empty, as OpenAI's computer use sends them) is a plain scroll.
    func testAScrollHoldingKeysIsRefusedWithWhatItsFor() {
        let hint = "can't hold keys: to scroll sideways give scroll_x (or direction left/right); to zoom use the app's zoom "
            + "shortcut or menu"
        for a in [["type": "scroll", "x": 1, "y": 2, "scroll_x": 0, "scroll_y": 300, "keys": ["shift"]],
                  ["type": "scroll", "scroll_y": 300, "keys": "cmd"], ["type": "scroll", "scroll_x": 50, "modifiers": "option"],
                  ["type": "scroll", "keys": ["ctrl"]]] as [[String: Any]] {
            XCTAssertEqual(Handlers.invalid(a), hint, "\(a)")
        }
        for a in [["type": "scroll", "scroll_y": 300], ["type": "scroll", "scroll_y": 300, "keys": NSNull()],
                  ["type": "scroll", "scroll_y": 300, "keys": ""], ["type": "scroll", "scroll_y": 300, "keys": [] as [Any]]]
            as [[String: Any]] {
            XCTAssertNil(Handlers.invalid(a), "\(a)")
        }
    }

    /// A move holds its keys on the way (OpenAI's computer use), as a click does, and the window gets the keyboard
    /// for them; with none it's a plain move.
    @MainActor func testAMoveHoldsItsKeys() {
        for a in [["type": "move", "x": 1, "y": 2, "keys": ["shift"]], ["type": "mouse_move", "coordinate": [1, 2], "keys": "cmd"],
                  ["type": "hover", "element": 2, "modifiers": "option"]] as [[String: Any]] {
            XCTAssertNil(Handlers.invalid(a), "\(a)")
            XCTAssertTrue(Handlers.actsOnKeyboardFocus(a), "\(a)")
        }
        XCTAssertEqual(Handlers.modifierFlags(Handlers.modifierKeys(["type": "move", "x": 1, "y": 2, "keys": ["shift", "cmd"]])),
                       [.maskShift, .maskCommand])
        for a in [["type": "move", "x": 1, "y": 2], ["type": "move", "x": 1, "y": 2, "keys": [] as [Any]],
                  ["type": "move", "x": 1, "y": 2, "keys": NSNull()], ["type": "move", "x": 1, "y": 2, "keys": ["a"]]] as [[String: Any]] {
            XCTAssertNil(Handlers.invalid(a), "\(a)")
            XCTAssertFalse(Handlers.actsOnKeyboardFocus(a), "no modifier to hold: \(a)")
        }
    }

    /// A fill's fields are checked too: a field with a key it doesn't read stops the batch before any field is filled.
    func testAFieldWithAKeyItDoesntReadIsNamed() {
        XCTAssertEqual(Handlers.invalid(["type": "fill", "fields": [["target": "Name", "text": "Ada"], ["target": "Email", "txt": "a@b"]]]),
                       "field 2 has an unknown key \"txt\" (did you mean text?): a field takes element, target, text, option, checked, clear")
        for (field, want) in [(["label": "Email", "text": "a"], "target"), (["target": "Agree", "check": true], "checked"),
                              (["target": "Name", "text": "Ada", "clear_first": false], "clear")] as [([String: Any], String)] {
            let why = Handlers.invalid(["type": "fill", "fields": [field]]) ?? ""
            XCTAssertTrue(why.hasPrefix("field 1 has an unknown key ") && why.contains("(did you mean \(want)?)"), "\(field): \(why)")
        }
        XCTAssertEqual(Handlers.invalid(["type": "fill", "fields": [["target": "Name", "role": "field", "text": "Ada"]]]),
                       "field 1 has an unknown key \"role\" (it goes in target: {\"text\": …, \"role\": …}): a field takes element, "
                           + "target, text, option, checked, clear")
    }

    /// A role or nth beside target belongs in it.
    func testARoleBesideTargetIsSaidToGoInIt() {
        XCTAssertEqual(Handlers.invalid(["type": "click", "target": "Save", "role": "button"]),
                       "has an unknown key \"role\" (it goes in target: {\"text\": …, \"role\": …}): click takes x, y, element, "
                           + "target, button, keys, item")
        XCTAssertTrue(Handlers.invalid(["type": "type", "target": "Name", "nth": 2, "text": "x"])?
            .contains("\"nth\" (it goes in target: {\"text\": …, \"nth\": …})") == true)
        XCTAssertNil(Handlers.invalid(["type": "wait_for", "text": "Done", "role": "button"]), "wait_for takes role itself")
    }

    /// A kind no action has (or none at all) is refused before anything runs, with the kind it most likely meant.
    func testAnUnknownKindIsNamedWithWhatItMeant() {
        XCTAssertEqual(Handlers.invalid(["type": "clik", "x": 1, "y": 2]), "is an unknown action type (did you mean click?)")
        XCTAssertEqual(Handlers.invalid(["action": "left_mouse_down", "coordinate": [1, 2]]),
                       "is an unknown action type (did you mean mouse_down?)")
        XCTAssertEqual(Handlers.invalid(["type": "doubleclick"]), "is an unknown action type (did you mean double_click?)")
        XCTAssertEqual(Handlers.invalid(["type": "scroll_down"]), "is an unknown action type (did you mean scroll?)")
        XCTAssertEqual(Handlers.invalid(["type": "zoom", "region": [0, 0, 9, 9]]), "is an unknown action type")
        XCTAssertEqual(Handlers.invalid(["x": 1, "y": 2]), "has no type: say what it does, e.g. {\"type\": \"click\", \"target\": \"Save\"}")
    }

    /// A scroll that moves nothing is refused: no distance at all, a distance of 0, or an amount with no direction.
    func testAScrollOfNothingIsRefused() {
        let none = "would scroll 0 px: give scroll_y (pixels, positive = down) and/or scroll_x, or direction (up, down, left, right) "
            + "with amount"
        for a in [["type": "scroll"], ["type": "scroll", "x": 1, "y": 2, "scroll_y": 0, "scroll_x": 0],
                  ["type": "scroll", "direction": "down", "amount": 0], ["type": "scroll", "amount": 3],
                  ["type": "scroll", "scroll_y": "lots"], ["action": "scroll", "coordinate": [1, 2]]] as [[String: Any]] {
            XCTAssertEqual(Handlers.invalid(a), none, "\(a)")
        }
        XCTAssertTrue(Handlers.invalid(["type": "scroll", "delta_y": 500])?.contains("did you mean scroll_y?") == true,
                      "the unknown key is what's named")
    }

    /// How far a scroll goes, by every name (what `perform` sends).
    func testScrollDistances() {
        func d(_ a: [String: Any]) -> [Double] { let s = Handlers.scrollDelta(a); return [s.dx, s.dy] }
        XCTAssertEqual(d(["scroll_y": 300]), [0, 300])
        XCTAssertEqual(d(["scroll_x": -40, "scroll_y": "12"]), [-40, 12])
        XCTAssertEqual(d(["dx": 5, "dy": -7]), [5, -7])
        XCTAssertEqual(d(["direction": "down"]), [0, 300])
        XCTAssertEqual(d(["scroll_direction": "up", "scroll_amount": 2]), [0, -200])
        XCTAssertEqual(d(["direction": "left", "amount": 1]), [-100, 0])
        XCTAssertEqual(d(["direction": "right", "amount": 4, "scroll_y": 50]), [400, 50])
        XCTAssertEqual(d([:]), [0, 0])
    }

    /// Every kind has its keys, and a documented kind is its own name.
    func testEveryKindHasItsKeys() {
        for k in Handlers.actionKinds { XCTAssertNotNil(Handlers.actionKeys(k), k) }
        for k in ["click", "double_click", "scroll", "type", "keypress", "fill", "wait_for", "macro", "screenshot"] {
            XCTAssertEqual(Handlers.actionKeys(k)?.name, k)
        }
        XCTAssertEqual(Handlers.actionKeys("left_click")?.name, "click")
        XCTAssertEqual(Handlers.actionKeys("waitfor")?.name, "wait_for")
        XCTAssertNil(Handlers.actionKeys("find"))
    }
}
