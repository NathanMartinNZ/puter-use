import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// Undoing the agent's own toggle doesn't ask: "Remove from saved" on the very button it pressed as "Save" a moment
/// ago, still called what that press made it. Narrowly: "remove" must be the only confirm word, the labels must be one
/// toggle's, and the earlier press can't have asked or been risky itself. Anything else asks as ever.
@MainActor
final class UndoOwnPressTests: XCTestCase {
    let confirm = Policy.defaultConfirm.map(Policy.phrase)

    /// The rule, with the earlier press of the same control `before` → `after`, `age` seconds ago.
    func undoes(_ before: String?, _ after: String?, now label: String, asked: Bool = false, age: TimeInterval = 60) -> Bool {
        Policy.undoes(label, risky: Policy.riskyWords(label, in: confirm), before: before, after: after, asked: asked, age: age,
                      confirm: confirm)
    }

    /// Its own save or add, undone: no need to ask.
    func testUndoingItsOwnToggleDoesntAsk() {
        XCTAssertTrue(undoes("Save", "Remove from saved", now: "Remove from saved"))
        XCTAssertTrue(undoes("Add to cart", "Remove from cart", now: "Remove from cart"))
        XCTAssertTrue(undoes("Add", "Remove", now: "Remove"))
        XCTAssertTrue(undoes("Add bookmark", "Remove bookmark", now: "Remove bookmark"))
        XCTAssertTrue(undoes("Add to Favorites", "Remove from Favorites", now: "Remove from Favorites"))
        XCTAssertTrue(undoes("Save", "Remove (unsave)", now: "Remove (unsave)"), "a leading \"un\" is dropped")
        XCTAssertTrue(undoes("Save", "Remove from saved", now: "Remove from saved", age: 9 * 60))
    }

    /// A wizard's next step, or a control that became something else, still asks: "Archive" then "Delete permanently",
    /// "Continue" then "Place order", "Continue" then "Remove item".
    func testAnotherCommandOnTheSameControlStillAsks() {
        XCTAssertFalse(undoes("Archive", "Delete permanently", now: "Delete permanently"))
        XCTAssertFalse(undoes("Continue", "Place order", now: "Place order"))
        XCTAssertFalse(undoes("Continue", "Remove item", now: "Remove item"), "the labels aren't one toggle's")
        XCTAssertFalse(undoes("Add to cart", "Remove from wishlist", now: "Remove from wishlist"))
        XCTAssertFalse(undoes("Bookmark", "Remove bookmark", now: "Remove bookmark"), "it neither added nor saved")
        XCTAssertFalse(undoes("Item 3", "Remove item 3", now: "Remove item 3"))
    }

    /// Only a press that adds or saves is one the undo rule pairs, so only its label is read again after it.
    func testOnlyAPressThatAddsOrSavesIsWatched() {
        for label in ["Save", "Add", "Add to cart", "Saved", "Unsave", "Adding…", "Save for later", "ADD TO BAG", "Save-as"] {
            XCTAssertTrue(Policy.undoable(label), label)
        }
        for label in ["Bookmark", "Open", "Continue", "Address", "Saver", "", "Learn more"] {
            XCTAssertFalse(Policy.undoable(label), label)
        }
        XCTAssertFalse(Policy.undoable(nil))
    }

    /// Text read off the screen (no element to ask) is judged by the whole line it was found in, as a control called
    /// that would be; the user's OK lets it through.
    func testAPressOnTextReadOffTheScreenAsks() {
        XCTAssertEqual(Policy.readPressWord("Delete", confirm: confirm, ok: false), "delete")
        XCTAssertEqual(Policy.readPressWord("Delete account", confirm: confirm, ok: false), "delete", "a click on \"account\"")
        XCTAssertNil(Policy.readPressWord("Delete", confirm: confirm, ok: true))
        XCTAssertNil(Policy.readPressWord("Save draft", confirm: confirm, ok: false))
        XCTAssertNil(Policy.readPressWord("Send to Back", confirm: confirm, ok: false), "only looks risky")
        XCTAssertNil(Policy.readPressWord("Delete", confirm: [], ok: false), "confirmation turned off")
    }

    func testAPressOnTextReadOffTheScreenStopsThroughThePolicy() throws {
        try XCTSkipUnless(Policy.config.confirm.contains("delete"), "the user's policy file has no \"delete\" confirm")
        XCTAssertThrowsError(try Policy.checkReadPress(["type": "click", "target": "Delete"], read: "Delete")) { e in
            XCTAssertEqual("\(e)", "\"Delete\" looks like it can't be undone (delete)")
        }
        XCTAssertNoThrow(try Policy.checkReadPress(["type": "click", "target": "Delete", "confirm": true], read: "Delete"))
        XCTAssertNoThrow(try Policy.checkReadPress(["type": "click", "target": "Open"], read: "Open"))
    }

    /// Only "remove", and only alone: never delete, send, pay, buy, publish or any other confirm word beside it.
    func testOnlyRemoveAloneIsLetThrough() {
        for label in ["Delete", "Send", "Pay", "Buy", "Publish", "Discard", "Remove and delete", "Remove and send"] {
            XCTAssertFalse(undoes("Save", label, now: label), label)
        }
        XCTAssertEqual(Policy.riskyWords("Remove and delete", in: confirm), ["delete", "remove"])
        XCTAssertEqual(Policy.riskyWords("Send to Back", in: confirm), [], "only looks risky, as ever")
        // A policy file whose list names the whole label wants it to ask.
        let mine = confirm + ["remove from saved"]
        XCTAssertFalse(Policy.undoes("Remove from saved", risky: Policy.riskyWords("Remove from saved", in: mine), before: "Save",
                                     after: "Remove from saved", asked: false, age: 60, confirm: mine))
    }

    /// The earlier press didn't ask and wasn't risky (an undo isn't undone in turn), was within 10 minutes, and the
    /// control hasn't been relabelled since.
    func testTheEarlierPressMustBeAPlainRecentOne() {
        XCTAssertFalse(undoes("Save", "Remove from saved", now: "Remove from saved", asked: true), "it carried the user's OK")
        XCTAssertFalse(undoes("Remove draft", "Remove from drafts", now: "Remove from drafts"), "it was risky itself")
        XCTAssertFalse(undoes("Delete draft", "Remove draft", now: "Remove draft"))
        XCTAssertFalse(undoes("Save", "Remove from saved", now: "Remove from saved", age: 11 * 60), "too long ago")
        XCTAssertFalse(undoes("Save", "Remove from saved", now: "Remove from cart"), "relabelled since")
        XCTAssertFalse(undoes("Save", "Save", now: "Remove from saved"), "not what that press made it")
        XCTAssertFalse(undoes("Save", nil, now: "Remove from saved"), "what it became isn't known")
        XCTAssertFalse(undoes(nil, "Remove", now: "Remove"), "what it was isn't known")
    }

    func testHowLongAgoIsSaid() {
        XCTAssertEqual(Policy.agoText(0.4), "1 s")
        XCTAssertEqual(Policy.agoText(42), "42 s")
        XCTAssertEqual(Policy.agoText(61), "1 min")
        XCTAssertEqual(Policy.agoText(599), "9 min")
    }

    // MARK: - through checkPress, in a session

    /// A button no app answers for: called what it was numbered with.
    func button(_ element: AXUIElement, _ label: String) -> AX.Node {
        AX.Node(element: element, frame: nil, role: "AXButton", label: label, name: "button")
    }

    /// What `press`'s control was called a moment after it, as the app would have said (no app answers for these).
    func read(_ press: Policy.Press?, _ after: String) {
        press?.after = after
        press?.afterRead = true
    }

    /// The press of "Save" is kept once its action is done; "Remove from saved" on that same button then goes through
    /// with a note, while the same label on another button, or one pressed with the user's OK last, still asks.
    func testAPressKeptByItsSessionLetsItsUndoThrough() throws {
        try XCTSkipUnless(Policy.config.confirm.contains("remove"), "the user's policy file has no \"remove\" confirm")
        let session = Session(id: "undo-test", ordinal: 0)
        let saved = AXUIElementCreateApplication(963_001), other = AXUIElementCreateApplication(963_002)
        try Session.$current.withValue(session) {
            session.notes = []
            try Policy.checkPress(["type": "click"], node: button(saved, "Save"), at: nil, pid: 963_001)
            try Policy.checkPress(["type": "click"], node: button(saved, "Save"), at: nil, pid: 963_001)  // checked twice
            XCTAssertTrue(session.presses.isEmpty, "kept only once its action is done")
            Policy.pressesMade()
            XCTAssertEqual(session.presses.count, 1, "checked twice, pressed once")
            XCTAssertTrue(session.pressing.isEmpty)
            read(session.presses[0], "Remove from saved")

            XCTAssertThrowsError(try Policy.checkPress(["type": "click"], node: button(other, "Remove from saved"), at: nil,
                                                       pid: 963_002)) { XCTAssertTrue($0 is Policy.NeedsOK) }
            session.pressing = []
            try Policy.checkPress(["type": "click"], node: button(saved, "Remove from saved"), at: nil, pid: 963_001)
            XCTAssertTrue(session.notes.isEmpty, "said once it's pressed")
            Policy.pressesMade()
            XCTAssertEqual(session.notes, ["pressed \"Remove from saved\" without asking: it undoes your own \"Save\" from 1 s ago"])
            // That undo was risky: pressing "Remove from saved" again (relabelled back, say) asks.
            read(session.presses.last, "Remove from saved")
            XCTAssertThrowsError(try Policy.checkPress(["type": "click"], node: button(saved, "Remove from saved"), at: nil,
                                                       pid: 963_001)) { XCTAssertTrue($0 is Policy.NeedsOK) }

            // A press with the user's OK is kept as one that asked: its control's undo asks.
            session.pressing = []
            try Policy.checkPress(["type": "click", "confirm": true], node: button(other, "Add"), at: nil, pid: 963_002)
            Policy.pressesMade()
            read(session.presses.last, "Remove")
            XCTAssertThrowsError(try Policy.checkPress(["type": "click"], node: button(other, "Remove"), at: nil, pid: 963_002))
        }
    }

    /// A session keeps its last 20 presses.
    func testASessionKeepsItsLastPresses() throws {
        try XCTSkipIf(Policy.config.confirm.isEmpty, "the user's policy file turns confirmation off")
        let session = Session(id: "undo-keep", ordinal: 0)
        Session.$current.withValue(session) {
            for i in 0..<25 {
                try? Policy.checkPress(["type": "click"], node: button(AXUIElementCreateApplication(pid_t(964_000 + i)), "Open \(i)"),
                                       at: nil, pid: pid_t(964_000 + i))
                Policy.pressesMade()
            }
        }
        XCTAssertEqual(session.presses.count, Policy.pressesKept)
        XCTAssertEqual(session.presses.first?.before, "Open 5")
        XCTAssertEqual(session.presses.last?.before, "Open 24")
    }
}
