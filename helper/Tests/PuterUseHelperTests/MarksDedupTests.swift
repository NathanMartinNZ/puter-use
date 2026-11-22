import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Marks on tables and lists (`Marks.shown`): a row or cell that a cell or control inside it nearly fills
/// gets no badge of its own, the inner one standing in for it, so badges don't pile up at one corner. The
/// numbers stay as they are. Made-up rects (no app needed).
final class MarksDedupTests: XCTestCase {
    func mark(_ id: Int, _ role: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Marks.Mark {
        Marks.Mark(id: id, rect: CGRect(x: x, y: y, width: w, height: h), role: role)
    }

    /// A list row holding a cell holding a text field, all one size: just the field. An outline row
    /// holding just a cell: the cell. In a two-column row, a cell a checkbox fills gives way to the
    /// checkbox, but the row keeps its badge (no one cell fills it), and so does a cell with a short link
    /// in it (its blank part is something else to click).
    func testRowsAndCellsSomethingInsideFillsGetNoBadge() {
        let marks = [
            mark(1, "AXRow", 0, 0, 600, 20), mark(2, "AXCell", 0, 0, 600, 20), mark(3, "AXTextField", 2, 1, 596, 18),
            mark(4, "AXOutlineRow", 0, 20, 300, 22), mark(5, "AXCell", 0, 20, 300, 22),
            mark(6, "AXRow", 0, 50, 600, 20), mark(7, "AXCell", 0, 50, 300, 20), mark(8, "AXCheckBox", 1, 51, 298, 18),
            mark(9, "AXCell", 300, 50, 300, 20), mark(10, "AXLink", 304, 52, 60, 16),
        ]
        XCTAssertEqual(Marks.shown(marks).map(\.id), [3, 5, 6, 8, 9, 10])
    }

    /// Of a row and a cell exactly alike, the cell keeps its badge: never neither. Two cells alike, two
    /// buttons alike, or marks with no role given are all drawn, as before.
    func testOneOfEachPileKeepsItsBadge() {
        XCTAssertEqual(Marks.shown([mark(1, "AXRow", 0, 0, 200, 20), mark(2, "AXCell", 0, 0, 200, 20)]).map(\.id), [2])
        XCTAssertEqual(Marks.shown([mark(1, "AXCell", 0, 0, 200, 20), mark(2, "AXCell", 0, 0, 200, 20)]).map(\.id), [1, 2])
        XCTAssertEqual(Marks.shown([mark(1, "AXButton", 0, 0, 80, 20), mark(2, "AXButton", 1, 1, 78, 18)]).map(\.id), [1, 2])
        let plain = [Marks.Mark(id: 1, rect: CGRect(x: 0, y: 0, width: 200, height: 20)),
                     Marks.Mark(id: 2, rect: CGRect(x: 1, y: 1, width: 198, height: 18))]
        XCTAssertEqual(Marks.shown(plain).map(\.id), [1, 2])
    }

    /// What's drawn keeps its numbers and places, and the numbers left off still belong to their row and
    /// cell (for `element`): nothing is renumbered.
    func testNumbersAreKept() {
        let marks = [mark(14, "AXRow", 0, 0, 300, 20), mark(15, "AXCell", 0, 0, 300, 20),
                     mark(16, "AXButton", 2, 2, 296, 16), mark(3, "AXLink", 0, 40, 50, 16)]
        let shown = Marks.shown(marks)
        XCTAssertEqual(shown.map(\.id), [16, 3])
        XCTAssertEqual(shown.map(\.rect), [marks[2].rect, marks[3].rect])
    }

    /// Drawing with a row its cell stands in for gives a picture the same size, and none at all to draw
    /// gives the picture back as it was.
    func testDrawingKeepsThePictureSize() throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try XCTUnwrap(ctx.makeImage())
        let shot = Shot(image: img, rect: CGRect(x: 0, y: 0, width: 300, height: 100))
        let drawn = Marks.draw(shot, [mark(1, "AXRow", 0, 0, 300, 20), mark(2, "AXCell", 0, 0, 300, 20)])
        XCTAssertEqual([drawn.width, drawn.height], [300, 100])
        XCTAssertTrue(Marks.draw(shot, []) === img)
    }
}
