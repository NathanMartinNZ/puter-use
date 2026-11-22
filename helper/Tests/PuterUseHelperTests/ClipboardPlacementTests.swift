import XCTest

@testable import PuterUseHelper

/// Reading a long clipboard in parts (its end, or where a query is in it), and where an agent's new window
/// goes to be on screen.
final class ClipboardPlacementTests: XCTestCase {
    func testShortTextComesWholeWithNoNote() {
        let (text, note) = Clipboard.page("hello", offset: 0, limit: 10)
        XCTAssertEqual(text, "hello")
        XCTAssertNil(note)
    }

    func testLongTextSaysWhereToReadOn() {
        let s = String(repeating: "a", count: 25)
        var (text, note) = Clipboard.page(s, offset: 0, limit: 10)
        XCTAssertEqual(text.count, 10)
        XCTAssertEqual(note, "the clipboard's text is 25 characters; this is characters 1-10. Read on with clipboard {offset: 10}")
        (text, note) = Clipboard.page(s, offset: 20, limit: 10)
        XCTAssertEqual(text.count, 5)
        XCTAssertEqual(note, "the clipboard's text is 25 characters; this is characters 21-25", "the last part: nothing to read on")
        (text, note) = Clipboard.page(s, offset: 30, limit: 10)
        XCTAssertEqual(text, "")
        XCTAssertEqual(note, "the clipboard's text is 25 characters: there's nothing from offset 30")
    }

    func testPartsCountCharactersNotBytes() {
        let (text, _) = Clipboard.page("é👍🏽ab", offset: 1, limit: 2)
        XCTAssertEqual(text, "👍🏽a")
    }

    /// A negative offset reads from the end; the note says where that part is, counted from the start, and
    /// where to read on. Further back than the start is from the start.
    func testANegativeOffsetReadsTheEnd() {
        let s = String(repeating: "a", count: 20) + "bbbbb"
        var (text, note) = Clipboard.page(s, offset: -5, limit: 10)
        XCTAssertEqual(text, "bbbbb")
        XCTAssertEqual(note, "the clipboard's text is 25 characters; this is characters 21-25")
        (text, note) = Clipboard.page(s, offset: -20, limit: 10)
        XCTAssertEqual(text, String(repeating: "a", count: 10))
        XCTAssertEqual(note, "the clipboard's text is 25 characters; this is characters 6-15. Read on with clipboard {offset: 15}")
        (text, note) = Clipboard.page(s, offset: -100, limit: 10)
        XCTAssertEqual(text.count, 10)
        XCTAssertEqual(note, "the clipboard's text is 25 characters; this is characters 1-10. Read on with clipboard {offset: 10}")
        (text, note) = Clipboard.page(s, offset: -100, limit: 50)
        XCTAssertEqual(text, s)
        XCTAssertNil(note, "all of it: no note")
        (text, note) = Clipboard.page("é👍🏽ab", offset: -3, limit: 2)
        XCTAssertEqual(text, "👍🏽a")
        XCTAssertEqual(note, "the clipboard's text is 4 characters; this is characters 2-3. Read on with clipboard {offset: 3}")
    }

    /// A query lists each match at its offset (data like the rest of the clipboard's text), with a note saying
    /// how many; from a (negative) offset, only from there on. No match is one line; an empty query is none.
    func testAQueryListsWhereItIs() {
        let s = "Subtotal: $40\nTotal: $44.20\nPaid"
        var (text, note) = Clipboard.page(s, offset: 0, limit: 10_000, query: "TOTAL")
        XCTAssertEqual(text, "@3: Subtotal: $40⏎Total: $44.20⏎Paid\n@14: Subtotal: $40⏎Total: $44.20⏎Paid")
        XCTAssertEqual(note, "the clipboard's text is 32 characters; 2 matches for \"TOTAL\"")
        (text, note) = Clipboard.page(s, offset: -20, limit: 10_000, query: "total")
        XCTAssertEqual(text, "@14: Subtotal: $40⏎Total: $44.20⏎Paid")
        XCTAssertEqual(note, "the clipboard's text is 32 characters; 1 match for \"total\" from offset 12")
        (text, note) = Clipboard.page(s, offset: 0, limit: 10_000, query: "zebra")
        XCTAssertEqual(text, "no match for \"zebra\" in the clipboard's 32 characters")
        XCTAssertNil(note)
        (text, note) = Clipboard.page(s, offset: 0, limit: 10, query: "")
        XCTAssertEqual(text, "Subtotal: ")
        XCTAssertEqual(note, "the clipboard's text is 32 characters; this is characters 1-10. Read on with clipboard {offset: 10}")
    }

    /// Ten matches, then how many more; a lot of them are counted up to 10,000.
    func testAQueryOnALongClipboardSaysHowManyMore() {
        let (text, note) = Clipboard.page(String(repeating: "x key ", count: 25), offset: 0, limit: 10_000, query: "key")
        XCTAssertEqual(text.components(separatedBy: "\n").count, 11)
        XCTAssertEqual(text.components(separatedBy: "\n").last, "+15 more (search on with offset 59)")
        XCTAssertEqual(note, "the clipboard's text is 150 characters; 25 matches for \"key\"")
        let many = Clipboard.page(String(repeating: "a", count: 10_050), offset: 0, limit: 10_000, query: "a")
        XCTAssertEqual(many.note, "the clipboard's text is 10050 characters; 10000+ matches for \"a\"")
    }

    let main = CGRect(x: 0, y: 25, width: 1512, height: 920)  // a laptop screen's visible area, below the menu bar
    let right = CGRect(x: 1512, y: 0, width: 1920, height: 1055)

    func testAWindowOnScreenStays() {
        XCTAssertNil(AX.onScreen(CGRect(x: 100, y: 100, width: 1000, height: 700), screens: [main]))
        XCTAssertNil(AX.onScreen(CGRect(x: 1000, y: 100, width: 1000, height: 700), screens: [main, right]),
                     "across two screens, all of it on one or the other")
        XCTAssertNil(AX.onScreen(CGRect(x: 0, y: 25, width: 1512, height: 920.5), screens: [main]), "a point of slack")
    }

    func testAWindowCascadedOffTheBottomRightMovesBackOn() {
        let to = AX.onScreen(CGRect(x: 900, y: 600, width: 1000, height: 700), screens: [main])
        XCTAssertEqual(to, CGRect(x: 512, y: 245, width: 1000, height: 700))
    }

    func testATooBigWindowIsShrunkToTheScreen() {
        let to = AX.onScreen(CGRect(x: 40, y: 60, width: 1534, height: 1072), screens: [main])
        XCTAssertEqual(to, main)
    }

    func testItGoesToTheScreenItsMostOn() {
        let to = AX.onScreen(CGRect(x: 3000, y: 500, width: 1000, height: 700), screens: [main, right])
        XCTAssertEqual(to, CGRect(x: 2432, y: 355, width: 1000, height: 700))
    }

    func testAWindowOnNoScreenGoesToTheFirst() {
        let to = AX.onScreen(CGRect(x: -5000, y: -5000, width: 800, height: 600), screens: [main, right])
        XCTAssertEqual(to, CGRect(x: 0, y: 25, width: 800, height: 600))
    }
}
