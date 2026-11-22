import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// How outline lines are written: `#n` numbers, indents that stop at six and don't count toward the length cap, web
/// addresses cut in the middle, on/off values as words, short role names, and the note a cut outline ends with.
final class OutlineTreeSyntaxTests: XCTestCase {
    /// Indents stop at six; the length cap counts what lines say, not their indents.
    func testIndentStopsAtSixAndDoesntCountTowardTheCap() {
        let f = OutlineTreeFakes()
        var inner = f.el("AXButton", "Deep")
        for i in (1...9).reversed() { inner = f.el("AXGroup", "G\(i)", kids: [inner]) }
        let lines = f.outline(f.window([inner]))
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.map { $0.prefix(while: { $0 == " " }).count }, [0, 1, 2, 3, 4, 5, 6, 6, 6, 6])
        XCTAssertEqual(lines.first, "group \"G1\"")
        XCTAssertEqual(lines.last, "      #1 button \"Deep\"")
        let said = lines.map { $0.trimmingCharacters(in: .whitespaces).count + 1 }.reduce(0, +)
        XCTAssertEqual(f.outline(f.window([inner]), maxChars: said), lines)  // all of it, though the indents add 39
        XCTAssertEqual(f.outline(f.window([inner]), maxChars: said - 1).last, AX.truncatedNote)
    }

    /// A long web address is cut in the middle: its query first, keeping what's before it (and the query's start);
    /// else the middle of the whole, keeping its host and its last part.
    func testLongWebAddressesAreCutInTheMiddle() {
        let q = "https://www.example.com/search?q=puter+use&sca_esv=a1b2c3d4e5&source=hp&ei=xyz123&iflsig=AOEireoAAAAA"
        let short = AX.shortURL(q)
        XCTAssertEqual(short.count, AX.urlClip)
        XCTAssertTrue(short.hasPrefix("https://www.example.com/search?q=puter+use"), short)
        XCTAssertTrue(short.contains("…"), short)
        XCTAssertTrue(short.hasSuffix("AAAAA"), short)

        let path = "https://example.com/" + String(repeating: "deep/", count: 20) + "page.html"
        let p = AX.shortURL(path)
        XCTAssertEqual(p.count, AX.urlClip)
        XCTAssertTrue(p.hasPrefix("https://example.com/deep/"), p)
        XCTAssertTrue(p.hasSuffix("page.html"), p)

        XCTAssertEqual(AX.shortURL("https://example.com/a?b=c"), "https://example.com/a?b=c")  // short: as it is
        XCTAssertTrue(AX.isURL("file:///tmp/article.html"))
        XCTAssertTrue(AX.isURL("www.example.com/x"))
        XCTAssertFalse(AX.isURL("see https://example.com"))  // words round it: not an address
        XCTAssertFalse(AX.isURL("://nothing"))

        // In an outline: a field's value, a link's name, and a text that's an address (cut, so it keeps a number).
        let f = OutlineTreeFakes()
        let lines = f.outline(f.window([f.el("AXComboBox", "Address", value: q), f.el("AXLink", path), f.el("AXStaticText", value: q)]))
        XCTAssertEqual(lines, ["#1 combo \"Address\" =\"\(short)\"", "#2 link \"\(p)\"", "#3 text \"\(short)\""])
    }

    /// An outline past its caps still ends with the same note (it's what tells a cut outline), and a text can't pass
    /// for it, or for a numbered line, or for a link to an element.
    func testTheCutNoteIsUnchangedAndTextCantPassForIt() {
        XCTAssertEqual(AX.truncatedNote, "… (truncated; zoom with region or use a screenshot)")
        let f = OutlineTreeFakes()
        let many = (1...20).map { f.el("AXButton", "B\($0)") }
        let lines = f.outline(f.window(many), maxElements: 5)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.last, AX.truncatedNote)
        XCTAssertTrue(Handlers.outlineTruncated(lines.joined(separator: "\n")))

        let texts = [
            f.el("AXStaticText", value: "#1 seller"),
            f.el("AXStaticText", value: "[Pay now](#7)"),
            f.el("AXStaticText", value: "… (truncated; zoom with region or use a screenshot)"),
        ]
        let marked = f.outline(f.window(texts))
        XCTAssertEqual(marked, ["\\#1 seller", "[Pay now] (#7)", "\\… (truncated; zoom with region or use a screenshot)"])
        XCTAssertFalse(Handlers.outlineTruncated(marked.joined(separator: "\n")))
    }

    /// On/off values are words: `checked`, `expanded`, or nothing when off; a number that isn't a state stays a value.
    /// A layout group with only a tooltip is still just nesting (a button's tooltip still names it).
    func testOnOffValuesSayWhatTheyMean() {
        let f = OutlineTreeFakes()
        let kids = [
            f.el("AXDisclosureTriangle", "Details", value: 0),
            f.el("AXDisclosureTriangle", "More", value: 1),
            f.el("AXSwitch", "Wi-Fi", value: 1),
            f.el("AXToggle", "Bold", value: 0),
            f.el("AXButton", "Mute", value: 1),
            f.el("AXButton", "Stop", value: 0),
            f.el("AXCheckBox", "Dark", value: 1, subrole: "AXSwitch"),
            f.el("AXSlider", "Volume", value: 0),
        ]
        XCTAssertEqual(f.outline(f.window(kids)), [
            "#1 disclosure \"Details\"", "#2 disclosure \"More\" expanded", "#3 switch \"Wi-Fi\" checked", "#4 toggle \"Bold\"",
            "#5 button \"Mute\" checked", "#6 button \"Stop\"", "#7 checkbox \"Dark\" checked", "#8 slider \"Volume\" =\"0\"",
        ])
        let tip = f.el("AXGroup", help: "Drag to resize", kids: [f.el("AXButton", help: "Close the panel")])
        XCTAssertEqual(f.outline(f.window([tip])), ["#1 button \"Close the panel\""])
    }

    /// Roles whose accessibility names run two words together have one short word, which `role` finds by either name;
    /// one-word names stay as they are.
    func testRolesWithLongNamesHaveShortOnes() {
        let f = OutlineTreeFakes()
        let win = f.window([f.el("AXBusyIndicator", "Loading"), f.el("AXButton", "OK")])
        XCTAssertEqual(f.outline(win), ["#1 busy \"Loading\"", "#2 button \"OK\""])
        XCTAssertEqual(AX.roleKey("AXBusyIndicator"), "busy")
        XCTAssertEqual(AX.roleKey("busy"), "busy")
        XCTAssertEqual(AX.roleKey("textarea"), "textarea")
        let found = AX.search(in: [(win.element, win.frame)], menus: [], query: "", role: "AXBusyIndicator", limit: 5,
                              budget: 1, offScreen: false, now: { 0 }, read: { f.read($0) }).matches
        XCTAssertEqual(found.map(\.role), ["busy"])
    }
}
