import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Routine field edits that accessibility confirms (act's `verify_edits`): which actions count, and the verdict as an
/// act ends. Every edit reads back as it should, never in a password field, nothing stopped or opened, and every
/// change to the picture lies within the edited controls (or the control the last click left hovered).
final class VerifyEditTests: XCTestCase {
    let nameField = CGRect(x: 300, y: 360, width: 190, height: 22)
    let email = CGRect(x: 300, y: 400, width: 190, height: 22)
    let checkbox = CGRect(x: 205, y: 440, width: 15, height: 15)

    func typed(_ frame: CGRect?, _ expected: String?, _ actual: String?, secure: Bool = false) -> VerifyEdit.Edit {
        VerifyEdit.Edit(frame: frame, expected: expected, actual: actual, secure: secure, kind: .typed)
    }

    func verified(_ edits: [VerifyEdit.Edit], changes: [CGRect] = [], lastClicked: CGRect? = nil,
                  ending: VerifyEdit.Ending = VerifyEdit.Ending()) -> Bool {
        VerifyEdit.verified(edits: edits, changes: changes, lastClicked: lastClicked, ending: ending)
    }

    // MARK: - which actions

    /// Text typed into a field (named, by its place, or the focused one), a field's value set, and a fill of text.
    func testTextFieldEditsAreEligible() {
        XCTAssertEqual(VerifyEdit.edits(["type": "type", "text": "Ada"]), 1, "into the focused field")
        XCTAssertEqual(VerifyEdit.edits(["type": "type", "text": "Ada", "target": "Name", "clear": true]), 1)
        XCTAssertEqual(VerifyEdit.edits(["type": "type", "text": "ada@example.org", "element": 7]), 1)
        XCTAssertEqual(VerifyEdit.edits(["type": "type_text", "value": "Ada", "x": 40, "y": 60]), 1, "a field clicked into by its place")
        XCTAssertEqual(VerifyEdit.edits(["type": "type", "text": "Ada", "submit": false]), 1, "submit false sends nothing")
        XCTAssertEqual(VerifyEdit.edits(["type": "set_value", "target": "Name", "value": "Ada"]), 1)
        XCTAssertEqual(VerifyEdit.edits(["type": "fill", "fields": [["target": "Name", "text": "Ada"], ["element": 9, "value": "ada@example.org"]]]), 2)
        XCTAssertEqual(VerifyEdit.edits(["type": "fill", "fields": ["Name": "Ada", "Age": 36]]), 2, "the object form, a number as text")
        XCTAssertEqual(VerifyEdit.edits(["type": "fill", "fields": ["Name": "Ada"], "submit": NSNull()]), 1)
        XCTAssertTrue(VerifyEdit.eligible(actions: [["type": "type", "text": "Ada", "target": "Name"],
                                                    ["type": "set_value", "element": 4, "value": "NZ"]]))
    }

    /// A plain left click on what an element number or target names (an edit once it's found to be a checkbox), and a
    /// fill's true or false.
    func testACheckboxItNamesIsEligible() {
        XCTAssertEqual(VerifyEdit.edits(["type": "click", "target": ["text": "Email me updates", "role": "checkbox"]]), 1)
        XCTAssertEqual(VerifyEdit.edits(["type": "left_click", "element": 12]), 1)
        XCTAssertEqual(VerifyEdit.edits(["type": "fill", "fields": [["target": "Agree", "checked": true]]]), 1)
        XCTAssertEqual(VerifyEdit.edits(["type": "fill", "fields": ["Name": "Ada", "Agree": true]]), 2)
    }

    func testEverythingElseIsNot() {
        let others: [[String: Any]] = [
            ["type": "keypress", "keys": "cmd+a"],
            ["type": "scroll", "scroll_y": 300],
            ["type": "wait_for", "text": "Saved"],
            ["type": "wait", "ms": 500],
            ["type": "navigate", "url": "https://example.org"],
            ["type": "open", "app": "TextEdit"],
            ["type": "menu", "item": "Edit > Paste"],
            ["type": "macro", "name": "sign up"],
            ["type": "paste", "text": "Ada"],
            ["type": "focus", "element": 3],
            ["type": "perform", "element": 3, "name": "press"],
            ["type": "clipboard"],
            ["type": "drag", "from": [1, 2], "to": [3, 4]],
            ["type": "double_click", "element": 3],
            ["type": "right_click", "element": 3],
            ["type": "click", "element": 3, "button": "right"],
            ["type": "click", "element": 3, "count": 2],
            ["type": "click", "x": 40, "y": 60],  // what's there isn't named
            ["type": "click", "target": "Save", "x": 40, "y": 60],
            ["type": "click", "element": 3, "keys": "cmd"],
            ["type": "click", "element": 3, "text": "shift"],  // Anthropic's computer use holds it
            ["type": "fill"],
            ["type": "fill", "fields": [] as [[String: Any]]],
            ["type": "fill", "fields": [["target": "Name"]]],  // nothing to put in it
            ["type": "type"],  // no text
        ]
        for a in others { XCTAssertNil(VerifyEdit.edits(a), "\(a)") }
        XCTAssertFalse(VerifyEdit.eligible(actions: []))
        XCTAssertFalse(VerifyEdit.eligible(actions: [["type": "type", "text": "Ada"], ["type": "keypress", "keys": "Tab"]]),
                       "one that isn't spoils the act")
    }

    /// Nothing with the user's OK on it (the guard stopped it as irreversible): not that action, and not a batch with
    /// one in it, whatever else it does. So it can't be complete either.
    func testABatchWithAConfirmedActionIsNot() {
        XCTAssertNil(VerifyEdit.edits(["type": "click", "target": "Send me updates", "confirm": true]))
        XCTAssertNil(VerifyEdit.edits(["type": "type", "text": "Ada", "target": "Name", "confirm": true]))
        XCTAssertNil(VerifyEdit.edits(["type": "fill", "fields": ["Name": "Ada"], "confirm": true]))
        XCTAssertNil(VerifyEdit.edits(["type": "fill", "fields": [["target": "Agree", "checked": true, "confirm": true]]]))
        XCTAssertEqual(VerifyEdit.edits(["type": "type", "text": "Ada", "confirm": false]), 1)
        let act: [[String: Any]] = [["type": "type", "text": "Ada", "target": "Name"],
                                    ["type": "click", "target": "Send me updates", "confirm": true]]
        XCTAssertFalse(VerifyEdit.eligible(actions: act))
        let tick = VerifyEdit.Edit(frame: checkbox, expected: "1", actual: "1", kind: .checked)
        XCTAssertFalse(VerifyEdit.complete([[typed(nameField, "Ada", "Ada")], [tick]], for: act))
    }

    /// Never a submit: a Return or Tab in what's typed, type's or fill's submit (true, a button's text, an element
    /// number, 0 too, a step), a field's own submit, or the Return key.
    func testASubmitOrReturnIsNot() {
        let sends: [[String: Any]] = [
            ["type": "type", "text": "Ada", "target": "Name", "submit": true],
            ["type": "type", "text": "Ada\n"],
            ["type": "type", "text": "Ada\r"],
            ["type": "type", "text": "Ada\tLovelace"],
            ["type": "fill", "fields": ["Name": "Ada"], "submit": true],
            ["type": "fill", "fields": ["Name": "Ada"], "submit": "Send"],
            ["type": "fill", "fields": ["Name": "Ada"], "submit": 4],
            ["type": "fill", "fields": ["Name": "Ada"], "submit": 0],
            ["type": "fill", "fields": ["Name": "Ada"], "submit": ["target": "Sign up"]],
            ["type": "fill", "fields": [["target": "Name", "text": "Ada", "submit": true]]],
            ["type": "fill", "fields": [["target": "Notes", "text": "one\ntwo"]]],
            ["type": "fill", "fields": ["Notes": "one\ntwo"]],
            ["type": "keypress", "keys": "Return"],
        ]
        for a in sends { XCTAssertNil(VerifyEdit.edits(a), "\(a)") }
        XCTAssertFalse(VerifyEdit.submits(nil))
        XCTAssertFalse(VerifyEdit.submits(NSNull()))
        XCTAssertFalse(VerifyEdit.submits(false))
        XCTAssertTrue(VerifyEdit.submits(true))
        XCTAssertTrue(VerifyEdit.submits(0), "element 0")
    }

    /// No pop-up pick, natively or in a browser: Firefox's `<select>` can't be read back through accessibility, and a
    /// native pop-up's pick moves a status label too. Not as select, as a fill's option, or as a click on its item.
    func testAPopUpPickIsNotEvenInFirefox() {
        XCTAssertNil(VerifyEdit.edits(["type": "select", "target": "Flooding", "option": "Wildlife"]))
        XCTAssertNil(VerifyEdit.edits(["type": "choose", "element": 14, "option": "Wildlife"]))
        XCTAssertNil(VerifyEdit.edits(["type": "fill", "fields": [["target": "Name", "text": "Ada"], ["element": 14, "option": "Wildlife"]]]))
        XCTAssertNil(VerifyEdit.edits(["type": "fill", "fields": [["element": 14, "select": "Wildlife"]]]))
        XCTAssertNil(VerifyEdit.edits(["type": "click", "element": 14, "item": "Wildlife"]))
        // The object form can't tell a pop-up from a field before it looks: a key that named one made no edit, so the
        // act isn't complete.
        let act: [[String: Any]] = [["type": "fill", "fields": ["Name": "Ada", "Topic": "Wildlife"]]]
        XCTAssertFalse(VerifyEdit.complete([[typed(nameField, "Ada", "Ada")]], for: act))
        XCTAssertTrue(VerifyEdit.complete([[typed(nameField, "Ada", "Ada"), typed(email, "Wildlife", "Wildlife")]], for: act))
    }

    func testEachActionMakesJustItsEdits() {
        let act: [[String: Any]] = [["type": "type", "text": "Ada", "target": "Name"], ["type": "click", "element": 12]]
        let ada = typed(nameField, "Ada", "Ada")
        let tick = VerifyEdit.Edit(frame: checkbox, expected: "1", actual: "1", kind: .checked)
        XCTAssertTrue(VerifyEdit.complete([[ada], [tick]], for: act))
        XCTAssertFalse(VerifyEdit.complete([[ada], []], for: act), "the click hit something other than a checkbox")
        XCTAssertFalse(VerifyEdit.complete([[ada, ada], [tick]], for: act), "one more")
        XCTAssertFalse(VerifyEdit.complete([[ada]], for: act), "an action that didn't run")
        XCTAssertFalse(VerifyEdit.complete([[ada], [tick], []], for: act + [["type": "keypress", "keys": "Tab"]]))
    }

    // MARK: - the verdict

    func testEveryEditMustReadBackAsTyped() {
        let ok = typed(email, "ada@example.org", "ada@example.org")
        XCTAssertTrue(verified([ok]))
        let bad = [
            typed(email, "ada@example.org", "ada@example.org.nz"),  // an autocomplete took over
            typed(email, "ada@example.org", "Ada@example.org"),
            typed(email, "ada@example.org", nil),  // not read
            typed(email, nil, "ada@example.org"),  // what it should hold isn't known
            typed(nil, "ada@example.org", "ada@example.org"),  // gone
        ]
        for b in bad { XCTAssertFalse(verified([ok, b]), "\(b)") }
        XCTAssertFalse(verified([VerifyEdit.Edit(frame: checkbox, expected: "1", actual: "0", kind: .checked)]), "it didn't flip")
        XCTAssertTrue(verified([VerifyEdit.Edit(frame: checkbox, expected: "1", actual: "1", kind: .checked)]))
        XCTAssertFalse(verified([]), "no edit at all")
    }

    func testNeverAPasswordField() {
        let secret = typed(email, "hunter2", "hunter2", secure: true)
        XCTAssertFalse(secret.confirmed)
        XCTAssertFalse(verified([typed(nameField, "Ada", "Ada"), secret]))
    }

    /// Never on an error, a stop for the user's OK or before coordinates, a note, a first look at the window, a new
    /// window, sheet or pop-up, or the window moved: each alone rules it out, however good the edits.
    func testNeverAfterAnErrorAStopAFirstLookOrANewWindow() {
        let ok = [typed(email, "Ada", "Ada")]
        XCTAssertTrue(verified(ok))
        let endings: [VerifyEdit.Ending] = [
            VerifyEdit.Ending(failed: true),
            VerifyEdit.Ending(stopped: true),
            VerifyEdit.Ending(noted: true),
            VerifyEdit.Ending(firstLook: true),
            VerifyEdit.Ending(newWindow: true),
            VerifyEdit.Ending(moved: true),
        ]
        for e in endings {
            XCTAssertTrue(e.rulesOut, "\(e)")
            XCTAssertFalse(verified(ok, ending: e), "\(e)")
        }
        XCTAssertFalse(VerifyEdit.Ending().rulesOut)
    }

    /// A picture marked verified is withheld from the agent, so it's never kept as what the agent last saw: the next
    /// reply is compared with the last picture it was shown (a stop for the user's OK then comes with one). A zoom
    /// isn't kept either; any other picture is.
    func testAVerifiedPictureIsNotKeptAsSeen() {
        XCTAssertFalse(VerifyEdit.remembers(zoom: false, verified: true))
        XCTAssertFalse(VerifyEdit.remembers(zoom: true, verified: false))
        XCTAssertTrue(VerifyEdit.remembers(zoom: false, verified: false))
    }

    /// A field the page marks invalid (`aria-invalid`) isn't confirmed, even holding what was typed. A spelling mark
    /// isn't that.
    func testNeverAFieldMarkedInvalid() {
        var marked = typed(email, "ada@", "ada@")
        marked.invalid = true
        XCTAssertFalse(marked.confirmed)
        XCTAssertFalse(verified([marked]))
        XCTAssertTrue(VerifyEdit.invalid("true"))
        XCTAssertTrue(VerifyEdit.invalid(true))
        XCTAssertFalse(VerifyEdit.invalid("false"))
        XCTAssertFalse(VerifyEdit.invalid("spelling"))
        XCTAssertFalse(VerifyEdit.invalid(nil))
    }

    /// Typing into the email field after clicking the checkbox clears the checkbox's hover shade: a change there is
    /// allowed when it's the last-clicked control, and only then. A status label changing elsewhere still isn't.
    func testTheLastClickedControlMayChangeToo() {
        let edits = [typed(email, "ada@example.org", "ada@example.org")]
        let text = CGRect(x: 304, y: 404, width: 96, height: 14)
        let unhovered = CGRect(x: 204, y: 438, width: 18, height: 18)
        XCTAssertTrue(verified(edits, changes: [text]))
        XCTAssertFalse(verified(edits, changes: [text, unhovered]))
        XCTAssertTrue(verified(edits, changes: [text, unhovered], lastClicked: checkbox))
        let label = CGRect(x: 16, y: 600, width: 200, height: 14)
        XCTAssertFalse(verified(edits, changes: [text, unhovered, label], lastClicked: checkbox))
        // One box around both takes in what lies between them, which neither covers: hence the changed cells.
        XCTAssertFalse(verified(edits, changes: [text.union(unhovered)], lastClicked: checkbox))
    }

    func testNoChangeIsContained() {
        XCTAssertTrue(VerifyEdit.contained([], in: []))
        XCTAssertTrue(VerifyEdit.contained([], in: [email]))
        XCTAssertTrue(verified([VerifyEdit.Edit(frame: checkbox, expected: "1", actual: "1", kind: .checked)], changes: []),
                      "a checkbox ticked already")
        XCTAssertFalse(VerifyEdit.contained([CGRect(x: 0, y: 0, width: 4, height: 4)], in: []), "a change, and nowhere allowed")
    }

    func testAFocusRingFitsTheMarginAndNoMore() {
        XCTAssertTrue(VerifyEdit.contained([email.insetBy(dx: -3, dy: -3)], in: [email]))
        XCTAssertTrue(VerifyEdit.contained([email.insetBy(dx: -8, dy: -8)], in: [email]))
        XCTAssertFalse(VerifyEdit.contained([email.insetBy(dx: -9, dy: -9)], in: [email]))
        XCTAssertTrue(VerifyEdit.contained([email.insetBy(dx: -12, dy: -12)], in: [email], margin: 14), "a wider margin")
    }

    /// Fields close enough for their margins to meet cover the gap between them; farther apart, a change there isn't
    /// theirs.
    func testNeighbouringFieldsCoverTheGapBetween() {
        let below = CGRect(x: 300, y: 426, width: 190, height: 22)  // 4 pt under the email field
        let between = CGRect(x: 320, y: 425, width: 40, height: 10)
        XCTAssertTrue(VerifyEdit.contained([between], in: [email, below]))
        XCTAssertFalse(VerifyEdit.contained([between], in: [email]))
        let far = CGRect(x: 300, y: 470, width: 190, height: 22)
        let gap = CGRect(x: 320, y: 440, width: 40, height: 6)
        XCTAssertFalse(VerifyEdit.contained([gap], in: [email, far]))
        XCTAssertTrue(VerifyEdit.contained([gap], in: [email, far], margin: 30))
    }

    /// The cells that changed, each row's run as one area of the screen; a difference within the tolerance isn't one.
    func testChangedCellsAreRunsOnTheScreen() {
        // 4 x 3 cells over a 40 x 30 pt capture at (100, 200): 10 pt a cell.
        let before = [UInt8](repeating: 10, count: 12)
        var now = before
        now[1] = 200
        now[2] = 200  // a run on the first row
        now[8] = 0  // the third row's first
        now[11] = 14  // within the tolerance
        let cells = VerifyEdit.changedCells(now, before, w: 4, h: 3, capture: CGRect(x: 100, y: 200, width: 40, height: 30))
        XCTAssertEqual(cells, [CGRect(x: 110, y: 200, width: 20, height: 10), CGRect(x: 100, y: 220, width: 10, height: 10)])
        XCTAssertEqual(VerifyEdit.changedCells(before, before, w: 4, h: 3, capture: .zero), [])
        XCTAssertNil(VerifyEdit.changedCells(now, before, w: 5, h: 3, capture: .zero), "not that many cells")
    }

    // MARK: - what an edit should show

    func testWhatAFieldShouldHoldOnceTyped() {
        XCTAssertEqual(VerifyEdit.expectedText(old: "Ada", range: CFRange(location: 3, length: 0), typed: " Lovelace"), "Ada Lovelace")
        XCTAssertEqual(VerifyEdit.expectedText(old: "Ada Byron", range: CFRange(location: 4, length: 5), typed: "Lovelace"),
                       "Ada Lovelace", "over a selection")
        XCTAssertEqual(VerifyEdit.expectedText(old: "", range: CFRange(location: 0, length: 0), typed: "Ada"), "Ada")
        XCTAssertEqual(VerifyEdit.expectedText(old: "👋 hi", range: CFRange(location: 2, length: 0), typed: "!"), "👋! hi",
                       "UTF-16 units, as accessibility counts")
        XCTAssertNil(VerifyEdit.expectedText(old: "Ada", range: CFRange(location: 4, length: 0), typed: "x"), "past its end")
        XCTAssertNil(VerifyEdit.expectedText(old: nil, range: CFRange(location: 0, length: 0), typed: "x"))
        XCTAssertNil(VerifyEdit.expectedText(old: "Ada", range: nil, typed: "x"))
    }

    func testACheckboxState() {
        XCTAssertEqual(VerifyEdit.state(NSNumber(value: 1)), "1")
        XCTAssertEqual(VerifyEdit.state(NSNumber(value: 0)), "0")
        XCTAssertEqual(VerifyEdit.state(true), "1")
        XCTAssertNil(VerifyEdit.state(NSNumber(value: 2)), "mixed")
        XCTAssertNil(VerifyEdit.state("1"))
        XCTAssertNil(VerifyEdit.state(nil))
    }
}
