import XCTest

@testable import PuterUseHelper

/// Reading a long clipboard in parts, and where an agent's new window goes to be on screen.
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
