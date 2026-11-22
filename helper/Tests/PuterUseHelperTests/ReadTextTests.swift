import XCTest

@testable import PuterUseHelper

/// `screenshot(read: …)`: an element's whole text, paged.
final class ReadTextTests: XCTestCase {
    /// Pages read on from each one's end put the whole text back together exactly, emoji and all; the last
    /// one is short, and past the end there's nothing.
    func testPagesReadOnToTheWholeText() {
        let s = (1...700).map { String(format: "%04d line of the notes, é👍🏽 ok", $0) }.joined(separator: "\n")
        var offset = 0, pages: [String] = [], ranges: [[Int]] = []
        while true {
            let p = Handlers.page(s, offset: offset, limit: 10_000)
            pages.append(p.text)
            ranges.append([offset, p.end, p.total])
            if p.end >= p.total { break }
            offset = p.end
        }
        XCTAssertEqual(pages.joined(), s)
        XCTAssertEqual(pages.count, (s.count + 9_999) / 10_000)
        XCTAssertEqual(ranges.first, [0, 10_000, s.count])
        XCTAssertEqual(ranges.last?[1], s.count)
        XCTAssertLessThan(pages.last!.count, 10_000)
        let past = Handlers.page(s, offset: s.count + 5, limit: 10)
        XCTAssertEqual(past.text, "")
        XCTAssertEqual(past.end, s.count + 5)
        XCTAssertEqual(past.total, s.count)
    }

    func testShortTextAndCharactersNotBytes() {
        XCTAssertTrue(Handlers.page("hello", offset: 0, limit: 10) == ("hello", 5, 5))
        XCTAssertTrue(Handlers.page("", offset: 0, limit: 10) == ("", 0, 0))
        XCTAssertTrue(Handlers.page("é👍🏽ab", offset: 1, limit: 2) == ("👍🏽a", 3, 4))
    }

    /// A number, text, a target spec or true asks for a read; false, null or nothing doesn't (JSON 1 is a
    /// number, not true).
    func testWhatAsksForARead() {
        XCTAssertTrue(Handlers.readRequested(NSNumber(value: 12)))
        XCTAssertTrue(Handlers.readRequested(NSNumber(value: 1)))
        XCTAssertTrue(Handlers.readRequested("Notes"))
        XCTAssertTrue(Handlers.readRequested(["text": "Notes", "role": "textarea"]))
        XCTAssertTrue(Handlers.readRequested(kCFBooleanTrue))
        XCTAssertFalse(Handlers.readRequested(kCFBooleanFalse))
        XCTAssertFalse(Handlers.readRequested(NSNull()))
        XCTAssertFalse(Handlers.readRequested(nil))
        let json = try! JSONSerialization.jsonObject(with: Data(#"{"a": true, "b": 1, "c": false}"#.utf8)) as! [String: Any]
        XCTAssertTrue(Handlers.readRequested(json["a"]))
        XCTAssertTrue(Handlers.readRequested(json["b"]))
        XCTAssertFalse(Handlers.readRequested(json["c"]))
    }

    func testHowAReadNamesItsElement() {
        XCTAssertEqual(Handlers.readName(12, "textarea", "Notes"), "[12] textarea \"Notes\"")
        XCTAssertEqual(Handlers.readName(3, "field", nil), "[3] field")
        XCTAssertEqual(Handlers.readName(7, "web", "Example Domain"), "[7] web area \"Example Domain\"")
        XCTAssertEqual(Handlers.readName(9, "text", String(repeating: "word ", count: 30)).count, "[9] text \"\"".count + 40)
    }

    /// An element number as outlines write it (`#12`) names that element, for `read` and for the read action's
    /// `element`, as `12` and `"12"` do. Anything more after it is a label, as is a `#` alone or before anything
    /// but digits.
    func testANumberAsOutlinesWriteIt() throws {
        XCTAssertEqual(Handlers.elementNumber(NSNumber(value: 12)), 12)
        XCTAssertEqual(Handlers.elementNumber("12"), 12)
        XCTAssertEqual(Handlers.elementNumber(" 12 "), 12)
        XCTAssertEqual(Handlers.elementNumber("#12"), 12)
        XCTAssertEqual(Handlers.elementNumber("  #7 "), 7)
        XCTAssertNil(Handlers.elementNumber("#12 open issues"))
        XCTAssertNil(Handlers.elementNumber("#"))
        XCTAssertNil(Handlers.elementNumber("# 12"))
        XCTAssertNil(Handlers.elementNumber("#-3"))
        XCTAssertNil(Handlers.elementNumber("#１２"), "digits in another script aren't a number")
        XCTAssertNil(Handlers.elementNumber("Notes"))
        XCTAssertNil(Handlers.elementNumber(kCFBooleanTrue))
        XCTAssertNil(Handlers.elementNumber(NSNull()))
        XCTAssertNil(Handlers.elementNumber(nil))
        guard case .element(12) = try Handlers.readSource(["type": "read", "element": "#12"]) else {
            return XCTFail("#12 is element 12")
        }
        guard case .element(4) = try Handlers.readSource(["type": "read", "element": 4]) else { return XCTFail("as before") }
        XCTAssertThrowsError(try Handlers.readSource(["type": "read", "element": "#12 open issues"]))
    }
}
