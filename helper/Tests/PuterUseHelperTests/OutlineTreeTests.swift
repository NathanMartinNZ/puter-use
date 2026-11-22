import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// A made-up window for outline tests (no app needed): elements with roles, names, values and frames, read the way
/// `AX.readAttrs` reads them.
final class OutlineTreeFakes {
    final class El {
        let element: AXUIElement
        let role: String
        var subrole, title, help: String?
        var value: AnyObject?
        var frame: CGRect
        var kids: [El]
        init(_ id: Int, _ role: String, frame: CGRect, kids: [El]) {
            element = AXUIElementCreateApplication(pid_t(980_000 + id))  // a distinct element; never asked anything
            (self.role, self.frame, self.kids) = (role, frame, kids)
        }
    }

    var byElement: [AXUIElement: El] = [:]
    var next = 0
    var row: CGFloat = 0  // how far down the window the last element on a line of its own is
    var asked = 0  // how often a text was asked whether it takes a press

    /// An element on a line of its own, unless it's given a `frame`. `value`: a string, or a number.
    func el(_ role: String, _ title: String? = nil, value: Any? = nil, subrole: String? = nil, help: String? = nil,
            frame: CGRect? = nil, kids: [El] = []) -> El {
        next += 1
        if frame == nil { row += 20 }
        let e = El(next, role, frame: frame ?? CGRect(x: 10, y: row, width: 300, height: 16), kids: kids)
        (e.title, e.subrole, e.help) = (title, subrole, help)
        if let s = value as? String { e.value = s as NSString } else if let n = value as? Int { e.value = NSNumber(value: n) }
        byElement[e.element] = e
        return e
    }

    func window(_ title: String? = nil, _ kids: [El]) -> El {
        el("AXWindow", title, frame: CGRect(x: 0, y: 0, width: 1000, height: 4000), kids: kids)
    }

    func window(_ kids: [El]) -> El { window(nil, kids) }

    /// `AX.attrs` of a fake, as the app would give them.
    func read(_ el: AXUIElement) -> [AnyObject]? {
        guard let f = byElement[el] else { return nil }
        let none = NSNull()
        func s(_ v: String?) -> AnyObject {
            if let v { return v as NSString }
            return none
        }
        var pos = f.frame.origin, size = f.frame.size
        return [f.role as NSString, s(f.subrole), s(f.title), none, f.value ?? none, f.kids.map(\.element) as NSArray,
                AXValueCreate(.cgPoint, &pos)!, AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, none, none,
                s(f.help), none]
    }

    /// The outline of `win`, one string per line. `pressable` take a press.
    func outline(_ win: El, _ reg: AX.Registry = AX.Registry(), interactive: Bool = false, pressable: [El] = [],
                 maxElements: Int = 300, maxChars: Int = 8000) -> [String] {
        let text = AX.outline(of: win.element, reg, visible: win.frame, menus: [], maxElements: maxElements,
                              maxChars: maxChars, interactive: interactive, now: { 0 }, read: { self.read($0) },
                              presses: { el in
                                  self.asked += 1
                                  return pressable.contains { CFEqual($0.element, el) }
                              })
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }
}

/// The outline is gathered as a tree, then shaped: texts side by side are one line with their links in it, plain
/// text has no number, numbers stay across looks, and what says nothing (empty containers, wrappers round one line,
/// hidden bits, the window's own title) goes.
final class OutlineTreeTests: XCTestCase {
    func at(_ x: CGFloat, _ width: CGFloat, y: CGFloat = 200) -> CGRect { CGRect(x: x, y: y, width: width, height: 16) }

    // MARK: - texts and links on one line

    /// Texts side by side in one element are one line, with the links among them as `[label](#n)`: the links keep their
    /// numbers (their own lines are what `lines` keeps, for what changed), the texts have none.
    func testTextsAndLinksSideBySideAreOneLine() {
        let f = OutlineTreeFakes()
        let row = f.el("AXGroup", kids: [
            f.el("AXStaticText", value: "380 points", frame: at(10, 70)),
            f.el("AXStaticText", value: " by ", frame: at(80, 20)),
            f.el("AXLink", "alice", frame: at(100, 30)),
            f.el("AXStaticText", value: " ", frame: at(130, 4)),
            f.el("AXLink", "2 hours ago", frame: at(134, 70)),
            f.el("AXStaticText", value: " | ", frame: at(204, 10)),
            f.el("AXLink", "hide", frame: at(214, 30)),
        ])
        let reg = AX.Registry()
        let line = "380 points by [alice](#1) [2 hours ago](#2) | [hide](#3)"
        XCTAssertEqual(f.outline(f.window([row]), reg), [line])
        XCTAssertEqual(reg.lines.map(\.1), ["#1 link \"alice\"", "#2 link \"2 hours ago\"", "#3 link \"hide\""])
        XCTAssertEqual(reg.unnumbered.map(\.1), [line])
        XCTAssertEqual(reg.nodes.count, 3)
        XCTAssertEqual(f.asked, 0)  // several texts on a line: a paragraph's, not asked about presses
    }

    /// A paragraph's text runs over several lines of the screen around its link; no space goes before a closing
    /// bracket. Another paragraph, or a line below in the same element, is a line of its own.
    func testAParagraphIsOneLineAndTheNextIsAnother() {
        let f = OutlineTreeFakes()
        let para = f.el("AXGroup", kids: [
            f.el("AXStaticText", value: "The council measured a quiet but measurable (see ",
                 frame: CGRect(x: 10, y: 300, width: 700, height: 48)),
            f.el("AXLink", "tide tables", frame: at(300, 80, y: 332)),
            f.el("AXStaticText", value: ") improvement in water clarity.", frame: CGRect(x: 10, y: 332, width: 700, height: 32)),
        ])
        let next = f.el("AXGroup", kids: [f.el("AXStaticText", value: "Next paragraph.", frame: at(10, 200, y: 380))])
        let address = f.el("AXGroup", kids: [
            f.el("AXStaticText", value: "1 Main St", frame: at(10, 80, y: 420)),
            f.el("AXStaticText", value: "Springfield", frame: at(10, 80, y: 438)),
        ])
        XCTAssertEqual(f.outline(f.window([para, next, address])), [
            "The council measured a quiet but measurable (see [tide tables](#1)) improvement in water clarity.",
            "Next paragraph.", "1 Main St", "Springfield",
        ])
        // "$" "9.99" touch: one word.
        XCTAssertEqual(AX.joinSegments([("$", false, false, at(10, 8)), ("9.99", false, false, at(18, 30))]), "$9.99")
    }

    /// Links alone side by side keep their own lines: there's no text to put them in.
    func testLinksAloneKeepTheirLines() {
        let f = OutlineTreeFakes()
        let nav = f.el("AXGroup", kids: [f.el("AXLink", "Home", frame: at(10, 40)), f.el("AXLink", "Docs", frame: at(60, 40))])
        XCTAssertEqual(f.outline(f.window([nav])), ["#1 link \"Home\"", "#2 link \"Docs\""])
    }

    // MARK: - numbers

    /// Plain text has no number. A text keeps one when it takes a press and is its line's only text (a clickable
    /// text), or when it's cut short (for `read`), at 200 characters.
    func testPlainTextHasNoNumberButClickableOrCutTextKeepsOne() {
        let f = OutlineTreeFakes()
        let long = String(repeating: "lorem ipsum ", count: 30)
        let settings = f.el("AXStaticText", value: "Settings")
        let status = f.el("AXStaticText", value: "status: ready")
        let kids = [f.el("AXButton", "Save"), status, f.el("AXGroup", kids: [settings]), f.el("AXStaticText", value: long)]
        let reg = AX.Registry()
        let lines = f.outline(f.window(kids), reg, pressable: [settings])
        XCTAssertEqual(Array(lines.prefix(3)), ["#1 button \"Save\"", "status: ready", "#2 text \"Settings\""])
        XCTAssertTrue(lines[3].hasPrefix("#3 text \"lorem ipsum lorem"), lines[3])
        XCTAssertTrue(lines[3].hasSuffix("…\""), lines[3])
        XCTAssertLessThanOrEqual(lines[3].count - "#3 text \"\"".count, AX.proseClip)
        XCTAssertEqual(lines.count, 4)
        XCTAssertNil(reg.ids[status.element])
        XCTAssertEqual(reg.lines.map(\.0), [1, 2, 3])
        XCTAssertEqual(f.asked, 2)  // "status: ready" and "Settings"; the long one has a number anyway
    }

    /// In a line of text, a clickable text that's the line's only text is `[text](#n)`; the texts of a paragraph that
    /// all take a press (a page listening for clicks at its top) are still prose; a text cut short ends `[…](#n)`.
    func testClickableAndCutTextsInALine() {
        let f = OutlineTreeFakes()
        let s = f.el("AXStaticText", value: "Settings", frame: at(10, 60))
        let card = f.el("AXGroup", kids: [s, f.el("AXLink", "Learn more", frame: at(80, 80))])
        XCTAssertEqual(f.outline(f.window([card]), pressable: [s]), ["[Settings](#1) [Learn more](#2)"])

        let a = f.el("AXStaticText", value: "Read the ", frame: at(10, 60, y: 300))
        let c = f.el("AXStaticText", value: " first.", frame: at(110, 40, y: 300))
        let para = f.el("AXGroup", kids: [a, f.el("AXLink", "guide", frame: at(70, 40, y: 300)), c])
        XCTAssertEqual(f.outline(f.window([para]), pressable: [a, c]), ["Read the [guide](#1) first."])

        let long = String(repeating: "lorem ipsum ", count: 30)
        let story = f.el("AXGroup", kids: [
            f.el("AXStaticText", value: long, frame: CGRect(x: 10, y: 600, width: 700, height: 80)),
            f.el("AXLink", "more", frame: at(600, 40, y: 664)),
        ])
        let reg = AX.Registry()
        let line = f.outline(f.window([story]), reg)[0]
        XCTAssertTrue(line.hasPrefix("lorem ipsum lorem"), line)
        XCTAssertTrue(line.hasSuffix("[…](#1) [more](#2)"), line)
        XCTAssertTrue(reg.lines[0].1.hasPrefix("#1 text \"lorem ipsum"), reg.lines[0].1)  // read=1 reads all of it
    }

    /// An element keeps its number across looks while it's there, whatever comes before it; texts take none.
    func testNumbersStayAcrossLooks() {
        let f = OutlineTreeFakes()
        let save = f.el("AXButton", "Save"), note = f.el("AXStaticText", value: "Saved 2 minutes ago"), help = f.el("AXLink", "Help")
        let reg = AX.Registry()
        XCTAssertEqual(f.outline(f.window([save, note, help]), reg), ["#1 button \"Save\"", "Saved 2 minutes ago", "#2 link \"Help\""])
        XCTAssertEqual(reg.next, 3)

        let undo = f.el("AXButton", "Undo")
        note.value = "Saved just now" as NSString
        XCTAssertEqual(f.outline(f.window([undo, save, note, help]), reg),
                       ["#3 button \"Undo\"", "#1 button \"Save\"", "Saved just now", "#2 link \"Help\""])
        XCTAssertEqual(reg.lines.map(\.0), [3, 1, 2])
        XCTAssertEqual(reg.unnumbered.map(\.0), ["Saved just now"])
    }

    /// Whether a text takes a press is asked once for it, not on every look.
    func testATextIsAskedAboutPressesOnce() {
        let f = OutlineTreeFakes()
        let win = f.window([f.el("AXStaticText", value: "Total"), f.el("AXButton", "Pay"), f.el("AXStaticText", value: "Total")])
        let reg = AX.Registry()
        XCTAssertEqual(f.outline(win, reg), ["Total", "#1 button \"Pay\"", "Total"])
        XCTAssertEqual(f.asked, 2)
        XCTAssertEqual(reg.unnumbered.map(\.0), ["Total", "Total (2)"])  // the same line again: a key of its own
        _ = f.outline(win, reg)
        XCTAssertEqual(f.asked, 2)
    }

    // MARK: - what goes

    /// The window has no line; an empty container with no name goes, a named one stays; one round a single line gives
    /// way to it (a heading goes on its front); what has no size and can't be acted on goes, but not a control, nor a
    /// 1x1 one (a visually hidden checkbox).
    func testEmptyContainersWrappersAndHiddenBitsGo() {
        let f = OutlineTreeFakes()
        let zero = CGRect(x: 10, y: 900, width: 0, height: 0)
        let kids = [
            f.el("AXToolbar"),
            f.el("AXGroup", "Rating: 4 of 5"),
            f.el("AXList", kids: [f.el("AXButton", "Only")]),
            f.el("AXHeading", kids: [f.el("AXLink", "Story")]),
            f.el("AXImage", "spacer", frame: zero),
            f.el("AXStaticText", value: "hidden", frame: zero),
            f.el("AXHeading", "Hidden heading", frame: zero),
            f.el("AXCheckBox", "Agree", frame: CGRect(x: 10, y: 940, width: 1, height: 1)),
            f.el("AXButton", "Hidden action", frame: zero),
        ]
        XCTAssertEqual(f.outline(f.window("Settings", kids)), [
            "group \"Rating: 4 of 5\"", "#1 button \"Only\"", "heading #2 link \"Story\"", "#3 checkbox \"Agree\"",
            "#4 button \"Hidden action\"",
        ])
    }

    /// A wrapper of no size still shows what's in it (web pages have them round what's on screen).
    func testAWrapperOfNoSizeStillShowsWhatsInIt() {
        let f = OutlineTreeFakes()
        let zero = CGRect(x: 0, y: 0, width: 0, height: 0)
        let kids = [
            f.el("AXGroup", "Card", frame: zero, kids: [f.el("AXButton", "Buy"), f.el("AXStaticText", value: "$9.99")]),
            f.el("AXList", frame: zero, kids: [f.el("AXLink", "One"), f.el("AXLink", "Two")]),
        ]
        XCTAssertEqual(f.outline(f.window(kids)), [
            "group \"Card\"", " #1 button \"Buy\"", " $9.99", "list", " #2 link \"One\"", " #3 link \"Two\"",
        ])
    }

    /// The window's title isn't said again: not by a group round everything with that name (Firefox's), nor by its page
    /// (a page in a frame keeps its title). The page's line stays, unnamed, where it holds several.
    func testTheWindowsTitleIsntSaidAgain() {
        let f = OutlineTreeFakes()
        let page = f.el("AXWebArea", "Harbour news", kids: [
            f.el("AXHeading", "The harbour"),
            f.el("AXWebArea", "Ad", kids: [f.el("AXLink", "Buy a boat")]),
            f.el("AXButton", "Subscribe"),
        ])
        let all = f.el("AXGroup", "Harbour news", kids: [f.el("AXToolbar", "Navigation", kids: [f.el("AXButton", "Back")]), page])
        XCTAssertEqual(f.outline(f.window("Harbour news", [all])), [
            "toolbar \"Navigation\"", " #1 button \"Back\"",
            "web", " heading \"The harbour\"", " web \"Ad\"", "  #2 link \"Buy a boat\"", " #3 button \"Subscribe\"",
        ])
    }

    /// A text showing what the field it's in holds (a combo box's value) says nothing new.
    func testATextShowingItsFieldsValueGoes() {
        let f = OutlineTreeFakes()
        let combo = f.el("AXComboBox", "Search or enter address", value: "example.com",
                         kids: [f.el("AXStaticText", value: "example.com")])
        XCTAssertEqual(f.outline(f.window([combo])), ["#1 combo \"Search or enter address\" =\"example.com\""])
    }
}
