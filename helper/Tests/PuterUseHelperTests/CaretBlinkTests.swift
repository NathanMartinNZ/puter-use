import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// A frame that differs from the agent's last image only by the text cursor blinking isn't a change
/// (`Handlers.onlyCaretBlinked`). Cells here are 1 per point, the capture starting at the window's corner.
final class CaretBlinkTests: XCTestCase {
    static let one = CGSize(width: 1, height: 1)

    /// A 200x22 field at (10, 28) holding 8 characters, the cursor after the 5th, reported at x 40.
    static let cursor = Caret(field: CGRect(x: 10, y: 28, width: 200, height: 22),
                              point: CGRect(x: 40, y: 30, width: 0, height: 16), at: 5, count: 8)

    func onlyBlink(_ box: CGRect, now: Caret = cursor, then: Caret = cursor) -> Bool {
        Handlers.onlyCaretBlinked(box, now: now, then: then, scale: Self.one, offset: .zero)
    }

    func testTheCursorBlinkingWhereItWasIsNoChange() {
        XCTAssertTrue(onlyBlink(CGRect(x: 40, y: 30, width: 1, height: 16)))
        XCTAssertTrue(onlyBlink(CGRect(x: 39, y: 29, width: 3, height: 18)), "its drawn width, cells rounding out")
        var atEdge = Self.cursor
        atEdge.at = 0
        atEdge.point = CGRect(x: 10, y: 30, width: 0, height: 16)
        XCTAssertTrue(onlyBlink(CGRect(x: 9, y: 30, width: 2, height: 16), now: atEdge, then: atEdge), "at the field's very edge")
    }

    /// "Ok Then!" with the cursor before "!", and a forward delete: the cursor's place and spot stay, the
    /// change is a sliver next to it, but the text got shorter.
    func testAForwardDeleteIsAChange() {
        var deleted = Self.cursor
        deleted.count = 7
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 2, height: 16), now: deleted))
        XCTAssertFalse(deleted.same(as: Self.cursor))
    }

    /// In a big text area, a sliver that isn't at the cursor: elsewhere on its line, lines away, or taller
    /// than a line.
    func testAThinChangeElsewhereInABigTextAreaIsAChange() {
        var big = Self.cursor
        big.field = CGRect(x: 10, y: 28, width: 600, height: 400)
        XCTAssertFalse(onlyBlink(CGRect(x: 300, y: 30, width: 1, height: 16), now: big, then: big), "another x")
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 200, width: 1, height: 16), now: big, then: big), "another line")
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 1, height: 60), now: big, then: big), "taller than a line")
        var empty = big
        empty.point = CGRect(x: 40, y: 14, width: 0, height: 16)  // an empty range's place: a line high
        XCTAssertTrue(onlyBlink(CGRect(x: 40, y: 30, width: 1, height: 16), now: empty, then: empty), "reported a line off")
    }

    /// The width allowed is a cursor's in points, not a number of cells: in a 1440-pt window (240 cells,
    /// 6 pt each) one cell or two it straddles, not 18 pt.
    func testTheWidthIsInPoints() {
        let sixth = CGSize(width: 1.0 / 6, height: 1.0 / 6)  // cells: the field x 1.7-35, the cursor at 6.7
        XCTAssertTrue(Handlers.onlyCaretBlinked(CGRect(x: 6, y: 5, width: 1, height: 3), now: Self.cursor, then: Self.cursor,
                                                scale: sixth, offset: .zero))
        XCTAssertTrue(Handlers.onlyCaretBlinked(CGRect(x: 6, y: 5, width: 2, height: 3), now: Self.cursor, then: Self.cursor,
                                                scale: sixth, offset: .zero))
        XCTAssertFalse(Handlers.onlyCaretBlinked(CGRect(x: 6, y: 5, width: 3, height: 3), now: Self.cursor, then: Self.cursor,
                                                 scale: sixth, offset: .zero))
    }

    func testTypedTextIsAChange() {
        // A character typed: the cursor moved on, its place in the text too.
        var typed = Self.cursor
        typed.at = 6
        typed.point = CGRect(x: 47, y: 30, width: 0, height: 16)
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 8, height: 16), now: typed))
        // Even a narrow one ("i"), whose cells make a sliver like a cursor's.
        typed.point = CGRect(x: 42, y: 30, width: 0, height: 16)
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 3, height: 16), now: typed))
    }

    func testACursorMovedByAClickIsAChange() {
        var moved = Self.cursor
        moved.at = 30
        moved.point = CGRect(x: 40, y: 46, width: 0, height: 16)
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 46, width: 1, height: 16), now: moved))
        var sameSpotOtherIndex = Self.cursor
        sameSpotOtherIndex.at = 9
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 1, height: 16), now: sameSpotOtherIndex))
        var sameIndexOtherSpot = Self.cursor
        sameIndexOtherSpot.point = CGRect(x: 60, y: 30, width: 0, height: 16)
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 1, height: 16), now: sameIndexOtherSpot))
    }

    /// A cursor that moved where neither picture shows it (between blinks) gets a note (`Caret.moved`).
    func testMovedInTheSameField() {
        var moved = Self.cursor
        moved.at = 2
        moved.point = CGRect(x: 20, y: 30, width: 0, height: 16)
        XCTAssertTrue(moved.moved(from: Self.cursor))
        XCTAssertFalse(Self.cursor.moved(from: Self.cursor), "where it was")
        var otherField = moved
        otherField.field = CGRect(x: 10, y: 60, width: 200, height: 22)
        XCTAssertFalse(otherField.moved(from: Self.cursor), "focus went to another field")
    }

    func testFocusInAnotherFieldIsAChange() {
        let other = Caret(field: CGRect(x: 10, y: 60, width: 200, height: 22), point: CGRect(x: 14, y: 62, width: 0, height: 16), at: 0)
        XCTAssertFalse(onlyBlink(CGRect(x: 14, y: 62, width: 1, height: 16), now: other))
    }

    func testAChangeBeyondTheCursorIsAChange() {
        XCTAssertFalse(onlyBlink(CGRect(x: 7, y: 25, width: 206, height: 28)), "a focus ring around the field")
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 60, height: 16)), "a selection, or text after the cursor")
        XCTAssertFalse(onlyBlink(CGRect(x: 40, y: 30, width: 1, height: 40)), "something below the field too")
        XCTAssertFalse(onlyBlink(CGRect(x: 300, y: 30, width: 1, height: 16)), "a sliver outside the field")
    }

    /// Apps that can't say where an empty range is: the same, with no position to compare.
    func testWithNoReportedPosition() {
        var bare = Self.cursor
        bare.point = nil
        XCTAssertTrue(onlyBlink(CGRect(x: 14, y: 31, width: 1, height: 15), now: bare, then: bare))
        XCTAssertFalse(onlyBlink(CGRect(x: 14, y: 31, width: 1, height: 15), now: bare, then: Self.cursor))
    }

    /// The field maps to cells through the capture's scale and where it starts in the window.
    func testScaleAndOffset() {
        let c = Caret(field: CGRect(x: 100, y: 60, width: 40, height: 20), point: nil, at: 3)
        let half = CGSize(width: 0.5, height: 0.5), offset = CGPoint(x: 20, y: 10)  // cells: x 40-60, y 25-35
        XCTAssertTrue(Handlers.onlyCaretBlinked(CGRect(x: 41, y: 26, width: 1, height: 8), now: c, then: c, scale: half, offset: offset))
        XCTAssertFalse(Handlers.onlyCaretBlinked(CGRect(x: 70, y: 26, width: 1, height: 8), now: c, then: c, scale: half, offset: offset))
    }

    /// With real signatures: a cursor line drawn in one frame and not the other differs in a 1-cell sliver.
    func testSignaturesOfABlink() throws {
        func frame(cursor: Bool) -> Signature {
            let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 0.9, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            ctx.setFillColor(gray: 0.1, alpha: 1)
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 3))  // some text, in both
            if cursor { ctx.fill(CGRect(x: 90, y: 14, width: 1, height: 16)) }
            return Signature(ctx.makeImage()!)
        }
        let on = frame(cursor: true), off = frame(cursor: false)
        let box = try XCTUnwrap(on.diff(off, outW: on.w, outH: on.h)?.box)
        XCTAssertEqual(box.width, 1)
        let c = Caret(field: box.insetBy(dx: -60, dy: -4), point: nil, at: 7)
        XCTAssertTrue(Handlers.onlyCaretBlinked(box, now: c, then: c, scale: Self.one, offset: .zero))
    }
}
