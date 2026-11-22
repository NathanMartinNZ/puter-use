import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Checks that keep the agent from missing something: an act going by the outline whose outline didn't
/// change while the window did, a press on a button named only by the text in it, and what a view-only
/// app still lets it do.
final class StatusSafetyTests: XCTestCase {
    // MARK: - an outline that missed the change

    static let w = 200, h = 150

    /// A frame of a window like Calculator's: a light window, its display's digits (`display`) and a text
    /// cursor at `cursorX` in a field (or none).
    static func frame(display: Bool = false, cursorX: Int? = nil) -> Signature {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if display {
            ctx.setFillColor(gray: 0.1, alpha: 1)
            ctx.fill(CGRect(x: 10, y: 20, width: 180, height: 25))
        }
        if let cursorX {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: cursorX, y: 100, width: 2, height: 16))
        }
        return Signature(ctx.makeImage()!)
    }

    /// The text field the cursor is in, in the signature's cells: a band across the window's middle, as tall
    /// as the window (so it holds the cursor however the frame is turned).
    static let field = CGRect(x: 40, y: 0, width: 120, height: h)

    static func box(_ now: Signature, _ then: Signature) -> CGRect? { now.diff(then, outW: now.w, outH: now.h)?.box }

    /// Nothing changed in the picture either: the outline stands.
    func testAnUnchangedWindowKeepsTheOutline() {
        XCTAssertNil(Handlers.outlineMissed(box: Self.box(Self.frame(), Self.frame()), cursorField: nil))
        XCTAssertNil(Handlers.outlineMissed(box: nil, cursorField: Self.field))
    }

    /// The display changed (the outline of what can be acted on leaves it out): the window is shown, saying why.
    func testADisplayThatChangedShowsTheWindow() {
        let box = Self.box(Self.frame(display: true), Self.frame())
        XCTAssertNotNil(box)
        let why = Handlers.outlineMissed(box: box, cursorField: nil)
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("outline"), why!)
        XCTAssertNotNil(Handlers.outlineMissed(box: box, cursorField: Self.field), "the change runs past the field")
    }

    /// Only the text cursor moved, in the field it stayed in: no outline shows it, and the outline stands.
    func testOnlyTheCursorMovingInItsFieldKeepsTheOutline() {
        let box = Self.box(Self.frame(cursorX: 120), Self.frame(cursorX: 60))
        XCTAssertNotNil(box)
        XCTAssertNil(Handlers.outlineMissed(box: box, cursorField: Self.field))
    }

    /// The cursor in no field known at both ends (it left one, or there's none): its change is shown as any is.
    func testACursorChangeWithNoFieldShowsTheWindow() {
        XCTAssertNotNil(Handlers.outlineMissed(box: Self.box(Self.frame(cursorX: 120), Self.frame(cursorX: 60)), cursorField: nil))
    }

    /// The cursor moved and the display changed too: shown.
    func testACursorAndADisplayChangeShowTheWindow() {
        let box = Self.box(Self.frame(display: true, cursorX: 120), Self.frame(cursorX: 60))
        XCTAssertNotNil(Handlers.outlineMissed(box: box, cursorField: Self.field))
    }

    /// An outline is unchanged with the same elements and lines, in any order; not with one changed, gone or new,
    /// nor with a text (it has no number) changed.
    func testWhenAnOutlineIsUnchanged() {
        func outline(_ lines: [(Int, String)], text: [String] = []) -> OutlineDiff.Outline {
            OutlineDiff.Outline(lines.map { OutlineDiff.Line(.id($0.0), $0.1, interactive: true) }
                + text.map { OutlineDiff.Line(.text($0), $0) }, interactive: true)
        }
        func unchanged(_ a: OutlineDiff.Outline, _ b: OutlineDiff.Outline) -> Bool { OutlineDiff.unchanged(a, b) }
        let old: [(Int, String)] = [(1, "button \"7\""), (2, "button \"8\""), (3, "button \"+\"")]
        XCTAssertTrue(unchanged(outline(old), outline(old)))
        XCTAssertTrue(unchanged(outline(old), outline(old.reversed())))
        XCTAssertFalse(unchanged(outline(old), outline([(1, "button \"7\""), (2, "button \"8\""), (3, "button \"-\"")])))
        XCTAssertFalse(unchanged(outline(old), outline(Array(old.prefix(2)))))
        XCTAssertFalse(unchanged(outline(old), outline(old + [(4, "button \"=\"")])))
        XCTAssertFalse(unchanged(outline(old), outline([(1, "button \"7\""), (2, "button \"8\""), (5, "button \"+\"")])),
                       "the same line under another number is another element")
        XCTAssertTrue(unchanged(outline(old, text: ["status: ready"]), outline(old, text: ["status: ready"])))
        XCTAssertFalse(unchanged(outline(old, text: ["status: busy"]), outline(old, text: ["status: ready"])),
                       "a status text changed")
    }

    // MARK: - what a press is judged by

    func label(own: String? = nil, role: String, numbered: String? = nil, shown: String? = nil, inside: String? = nil,
               inControl: Bool = false) -> String? {
        Policy.pressLabel(own: own, role: role, numbered: numbered, shown: shown, inside: { inside }, inControl: { inControl })
    }

    /// Its own name, else the one it was numbered with, for any control: as before.
    func testAControlsOwnNameComesFirst() {
        XCTAssertEqual(label(own: "Delete", role: "AXButton", shown: "Keep", inside: "Keep"), "Delete")
        XCTAssertEqual(label(role: "AXCheckBox", numbered: "Remove after reading"), "Remove after reading")
        XCTAssertEqual(label(own: "  ", role: "AXButton", numbered: "Send"), "Send", "a blank name is none")
    }

    /// A button, link or menu item named only by the text in it goes by that text: what the outline called it,
    /// else the words in it now.
    func testAButtonNamedOnlyByItsTextGoesByIt() {
        XCTAssertEqual(label(role: "AXButton", shown: "Delete", inside: "Delete"), "Delete")
        XCTAssertEqual(label(role: "AXButton", inside: "Delete"), "Delete", "found by target: no outline name kept")
        XCTAssertEqual(label(role: "AXLink", inside: "Delete account"), "Delete account")
        XCTAssertEqual(label(role: "AXMenuItem", shown: "Move to Trash"), "Move to Trash")
        XCTAssertNil(label(role: "AXButton"), "nothing to go by")
    }

    /// Calculator's backspace key is a button whose own accessibility description is "Delete" (its outline said
    /// `button "Delete"` when the outline named a control only by its title, description, placeholder or help).
    /// A press on it was judged by that name before a button could go by the text in it, and still is: it stops,
    /// as it always did. Nothing the outline or a search found it by (`shown`) or the words in it change that.
    func testABackspaceKeyNamedDeleteByItsOwnDescriptionStopsAsBefore() {
        XCTAssertEqual(label(own: "Delete", role: "AXButton"), "Delete")
        XCTAssertEqual(label(own: "Delete", role: "AXButton", numbered: "Delete", shown: "Delete"), "Delete")
        XCTAssertEqual(label(role: "AXButton", numbered: "Delete"), "Delete", "the name it was numbered by, as before")
        // With no name of its own, no words in it, and nothing it was found by: nothing to judge it by.
        XCTAssertNil(label(role: "AXButton", inside: nil))
    }

    /// The words in it are read only when the button has no other name.
    func testTheWordsInItAreOnlyReadWhenNeeded() {
        var reads = 0
        _ = Policy.pressLabel(own: "Save", role: "AXButton", numbered: nil, shown: nil, inside: { reads += 1; return "x" },
                              inControl: { true })
        _ = Policy.pressLabel(own: nil, role: "AXButton", numbered: nil, shown: "Send", inside: { reads += 1; return "x" },
                              inControl: { true })
        XCTAssertEqual(reads, 0)
    }

    /// A field, checkbox or pop-up is judged by its own name only: the text that titles a field ("Post title")
    /// or a pop-up's shown choice ("Send later") is no press of anything.
    func testOtherControlsGoByTheirOwnNameOnly() {
        XCTAssertNil(label(role: "AXTextField", shown: "Post title", inside: "Post title"))
        XCTAssertNil(label(role: "AXCheckBox", shown: "Send me updates", inside: "Send me updates"))
        XCTAssertNil(label(role: "AXPopUpButton", shown: "Send later", inside: "Send later"))
        XCTAssertNil(label(role: "AXRow", shown: "Delete me", inside: "Delete me"))
    }

    /// A text is judged by its words inside a button, link or menu item (clicking a button's words presses the
    /// button); elsewhere (a file name, a subject line), not at all.
    func testATextGoesByItsWordsOnlyInsideAControl() {
        XCTAssertEqual(label(role: "AXStaticText", shown: "Delete", inControl: true), "Delete")
        XCTAssertEqual(label(role: "AXStaticText", inside: "Send", inControl: true), "Send")
        XCTAssertNil(label(role: "AXStaticText", shown: "Post-mortem notes", inside: "Post-mortem notes", inControl: false))
    }

    // MARK: - view-only apps and the read keys

    /// A view-only app still lets the agent read text in an act, as a screenshot's read does.
    func testReadIsLooking() {
        XCTAssertTrue(Policy.looking.contains("read"))
        XCTAssertFalse(Policy.looking.contains("type"))
    }

    /// clipboard and read take a query (and an offset from the end): not refused as unknown keys.
    func testClipboardAndReadTakeAQuery() {
        XCTAssertNil(Handlers.invalid(["type": "clipboard", "query": "Total"]))
        XCTAssertNil(Handlers.invalid(["type": "clipboard", "offset": -500, "limit": 200]))
        XCTAssertNil(Handlers.invalid(["type": "read", "target": "Notes", "query": "Total"]))
        XCTAssertNil(Handlers.invalid(["type": "read", "element": 12, "offset": -1000]))
        XCTAssertNotNil(Handlers.invalid(["type": "clipboard", "search": "Total"]), "other keys are still refused")
    }
}
