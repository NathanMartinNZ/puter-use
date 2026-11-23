import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// Curly quotes, dashes, the minus sign and no-break spaces match the plain marks typed for them, either way round:
/// a wait for "we've" finds a page's "we’ve", and a target "Don't Save" the button "Don’t Save". Folded one for one
/// (`AX.fold1`), so where a match is (a read's offset, the words an OCR box is drawn round) is where it is in the text
/// as shown.
@MainActor
final class TypographicMatchTests: XCTestCase {
    // MARK: - the fold

    func testTypographicMarksFoldToPlainOnes() {
        XCTAssertEqual(AX.fold1("we\u{2019}ve"), "we've")
        XCTAssertEqual(AX.fold1("Don\u{2019}t Save"), "Don't Save")
        XCTAssertEqual(AX.fold1("a \u{2013} b"), "a - b")
        XCTAssertEqual(AX.fold1("\u{2018}\u{2019}\u{201A}\u{201B}\u{2032}"), "'''''")
        XCTAssertEqual(AX.fold1("\u{201C}\u{201D}\u{201E}\u{201F}\u{2033}"), "\"\"\"\"\"")
        XCTAssertEqual(AX.fold1("\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}"), "-------")
        XCTAssertEqual(AX.fold1("10\u{00A0}kg 5\u{202F}%\u{2009}x\u{2007}1"), "10 kg 5 % x 1")
    }

    /// Plain text, and text with no mark it folds (accents, an ellipsis, an emoji), comes back as it is.
    func testTextWithNothingToFoldIsUnchanged() {
        for s in ["", "Every change we've detected", "caf\u{E9} \u{2026} 👍🏽", "Cafe\u{301}", "\u{2026}\u{20AC}5"] {
            XCTAssertEqual(AX.fold1(s), s)
        }
    }

    /// One for one: as many UTF-16 units and characters as before, so a range or offset in the folded text is the
    /// same in the text itself.
    func testFoldingKeepsLengthsAndRanges() {
        let s = "👍🏽 \u{201C}We\u{2019}ve\u{201D} \u{2014} caf\u{E9}\u{00A0}ok"
        let f = AX.fold1(s)
        XCTAssertEqual(f, "👍🏽 \"We've\" - caf\u{E9} ok")
        XCTAssertEqual(f.utf16.count, s.utf16.count)
        XCTAssertEqual(f.count, s.count)
        let r = f.range(of: "we've", options: .caseInsensitive)!
        XCTAssertEqual(String(s[AX.unfolded(r, of: f, in: s)]), "We\u{2019}ve")
    }

    /// A menu item or a whole label matches by `menuKey` with its marks folded, on top of case, spacing and "...".
    func testMenuKeysFoldMarks() {
        XCTAssertEqual(AX.menuKey("Don\u{2019}t Save\u{2026}"), AX.menuKey("don't  save..."))
        XCTAssertEqual(AX.menuKey("Page\u{00A0}Setup\u{2026}"), "page setup\u{2026}")
        XCTAssertEqual(AX.menuMatches(["Save", "Don\u{2019}t Save", "Cancel"], "Don't Save"), [1])
    }

    // MARK: - what an element shows (find, wait_for, target)

    final class Fake {
        let element: AXUIElement
        let role: String
        let title, value: String?
        let frame: CGRect
        let kids: [Fake]
        init(_ id: Int, _ role: String, title: String?, value: String?, frame: CGRect, kids: [Fake]) {
            element = AXUIElementCreateApplication(pid_t(962_000 + id))  // a distinct element; never asked anything
            (self.role, self.title, self.value, self.frame, self.kids) = (role, title, value, frame, kids)
        }
    }

    var byElement: [AXUIElement: Fake] = [:]
    var id = 0

    func make(_ role: String, _ title: String? = nil, value: String? = nil, kids: [Fake] = []) -> Fake {
        id += 1
        let f = Fake(id, role, title: title, value: value, frame: CGRect(x: 10, y: CGFloat(id) * 20, width: 300, height: 16),
                     kids: kids)
        byElement[f.element] = f
        return f
    }

    /// `AX.attrs` of a fake, as the app would give them.
    func read(_ el: AXUIElement) -> [AnyObject]? {
        guard let f = byElement[el] else { return nil }
        var pos = f.frame.origin, size = f.frame.size
        let none = NSNull()
        func s(_ v: String?) -> AnyObject { v.map { $0 as NSString } ?? none }
        return [f.role as NSString, none, s(f.title), none, s(f.value), f.kids.map(\.element) as NSArray,
                AXValueCreate(.cgPoint, &pos)!, AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, none, none, none, none]
    }

    func search(_ kids: [Fake], _ q: String) -> [AX.Match] {
        id += 1
        let win = Fake(id, "AXWindow", title: nil, value: nil, frame: CGRect(x: 0, y: 0, width: 1000, height: 2000), kids: kids)
        byElement[win.element] = win
        return AX.search(in: [(win.element, win.frame)], menus: [], query: q, role: nil, limit: 30, budget: 1,
                         offScreen: false, now: { 0 }, read: { self.read($0) }).matches
    }

    /// A page's curly apostrophe, a button's, a dash and a no-break space are found by the plain marks, and the other way
    /// round; a whole label stays a whole-label match. The label found is the text as shown.
    func testElementsMatchEitherWay() {
        let page = make("AXStaticText", value: "Every change we\u{2019}ve detected")
        let button = make("AXButton", "Don\u{2019}t Save")
        let range = make("AXStaticText", value: "Pages 3 \u{2013} 7")
        let weight = make("AXStaticText", value: "Weight: 10\u{00A0}kg")
        let plain = make("AXButton", "Don't Replace")
        let kids = [page, button, range, weight, plain]

        let wait = search(kids, "Every change we've detected")
        XCTAssertEqual(wait.map(\.label), ["Every change we\u{2019}ve detected"])
        XCTAssertEqual(wait.map(\.exact), [true])
        let target = search(kids, "Don't Save")
        XCTAssertEqual(target.map(\.label), ["Don\u{2019}t Save"])
        XCTAssertEqual(target.map(\.exact), [true])
        XCTAssertEqual(search(kids, "3 - 7").map(\.label), ["Pages 3 \u{2013} 7"])
        XCTAssertEqual(search(kids, "10 kg").map(\.label), ["Weight: 10\u{00A0}kg"])
        XCTAssertEqual(search(kids, "Don\u{2019}t Replace").map(\.label), ["Don't Replace"], "a curly query finds a plain label")
        XCTAssertEqual(search(kids, "don\u{2019}t").map(\.label), ["Don\u{2019}t Save", "Don't Replace"])
    }

    // MARK: - a read's query and OCR's find

    /// A read's query finds the curly text by the plain one, and the offset it gives is where the match is in the text
    /// itself (a read from it starts there), after an emoji, an accent and other folded marks; the line shows the text
    /// as it is.
    func testAReadQueryMatchesEitherWayAtTheRightOffset() {
        let s = "👍🏽 caf\u{E9} \u{2014} \u{201C}Every change we\u{2019}ve detected\u{201D}"  // “ at 9, "we’ve" at 23; 38 in all
        let found = Handlers.textMatches(s, query: "we've", from: 0, limit: 10_000)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.text, "@23: " + s)
        XCTAssertEqual(Handlers.textPart(s, offset: 23, limit: 5).text, "we\u{2019}ve")
        let back = Handlers.textMatches("it's \u{2014} it\u{2019}s", query: "it\u{2019}s", from: 0, limit: 10_000)
        XCTAssertEqual(back.count, 2, "a curly query finds the plain text too")
        XCTAssertTrue(back.text.hasPrefix("@0: "))
        XCTAssertTrue(back.text.contains("\n@7: "))
        let on = Handlers.textMatches(s, query: "\"every", from: 5, limit: 10_000)
        XCTAssertTrue(on.text.hasPrefix("@9: "), on.text)
        XCTAssertEqual(Handlers.textPart(s, offset: 9, limit: 6).text, "\u{201C}Every")
        XCTAssertEqual(Handlers.textMatches(s, query: "zebra", from: 0, limit: 10_000).text, "no match for \"zebra\" in 38 characters")
    }

    /// The words an OCR box is drawn round are the line's own, though the match was made with its marks folded.
    func testAnOCRMatchIsARangeOfTheLineAsRead() {
        let line = "👍🏽 Caf\u{E9} \u{2014} We\u{2019}ve detected 3 changes"
        let r = OCR.range(of: AX.fold1("we've detected"), in: line)
        XCTAssertEqual(r.map { String(line[$0]) }, "We\u{2019}ve detected")
        XCTAssertEqual(r.map { line.distance(from: line.startIndex, to: $0.lowerBound) }, 9)
        XCTAssertEqual(OCR.range(of: AX.fold1("cafe - we"), in: line).map { String(line[$0]) }, "Caf\u{E9} \u{2014} We",
                       "accents aside too, as before")
        XCTAssertNil(OCR.range(of: "zebra", in: line))
    }
}
