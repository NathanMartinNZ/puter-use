import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Where marks' badges go on a picture (`Marks.layout`, which `Marks.draw` draws), and a picture trimmed of
/// its blank margins keeping every badge (`Trim.plan`'s `protect`). The capture is 560x448 at 1 px a point.
final class GutterMarksTests: XCTestCase {
    static func shot(_ c: GutterTrimTests.Canvas = GutterTrimTests.Canvas()) -> Shot {
        Shot(image: c.image, rect: CGRect(x: 0, y: 0, width: c.w, height: c.h))
    }

    func testBadgesSitAtTheirElementsCorners() throws {
        let marks = [Marks.Mark(id: 3, rect: CGRect(x: 200, y: 100, width: 80, height: 20), role: "AXButton"),
                     Marks.Mark(id: 12, rect: CGRect(x: 200, y: 100, width: 60, height: 20), role: "AXLink")]
        let placed = Marks.layout(Self.shot(), marks)
        XCTAssertEqual(placed.map(\.mark.id), [3, 12])
        let first = try XCTUnwrap(placed.first), second = try XCTUnwrap(placed.last)
        XCTAssertEqual(first.badge.origin, CGPoint(x: 200, y: 100))
        XCTAssertEqual(first.box, CGRect(x: 200, y: 100, width: 80, height: 20))
        XCTAssertGreaterThanOrEqual(second.badge.minX, first.badge.maxX + 1, "shifted right, clear of the first")
        XCTAssertEqual(second.badge.minY, first.badge.minY)
    }

    /// Off the picture, or too small to see: no badge. A row a cell fills: the cell's badge alone.
    func testWhatGetsNoBadge() {
        let marks = [Marks.Mark(id: 1, rect: CGRect(x: -100, y: -100, width: 20, height: 20)),
                     Marks.Mark(id: 2, rect: CGRect(x: 50, y: 50, width: 1, height: 1)),
                     Marks.Mark(id: 3, rect: CGRect(x: 100, y: 200, width: 300, height: 20), role: "AXRow"),
                     Marks.Mark(id: 4, rect: CGRect(x: 100, y: 200, width: 300, height: 20), role: "AXCell")]
        XCTAssertEqual(Marks.layout(Self.shot(), marks).map(\.mark.id), [4])
    }

    /// The badges drawn are where the layout says: the mark's colour at the badge's left edge.
    func testDrawingFollowsTheLayout() throws {
        let marks = [Marks.Mark(id: 5, rect: CGRect(x: 120, y: 80, width: 90, height: 24))]
        let shot = Self.shot()
        let badge = try XCTUnwrap(Marks.layout(shot, marks).first?.badge)
        let drawn = Marks.draw(shot, marks)
        XCTAssertEqual(drawn.width, 560)
        XCTAssertEqual(drawn.height, 448)
        let px = try XCTUnwrap(Pixels(drawn))
        let i = ((Int(badge.minY) + 1) * px.width + Int(badge.minX) + 1) * 4
        XCTAssertEqual(Double(px.rgba[i]), 0.84 * 255, accuracy: 3)
        XCTAssertEqual(Double(px.rgba[i + 1]), 0, accuracy: 3)
        XCTAssertEqual(Double(px.rgba[i + 2]), 0.44 * 255, accuracy: 3)
        XCTAssertTrue(Marks.draw(shot, []) === shot.image, "no marks: the picture as it was")
    }

    /// An element in a blank side (a link the page draws nothing for, say) with marks on: the cut stops short
    /// of its badge, which stays whole in the picture.
    func testATrimKeepsEveryBadge() throws {
        let canvas = GutterTrimTests.article()
        let shot = Self.shot(canvas)
        let marks = [Marks.Mark(id: 9, rect: CGRect(x: 60, y: 300, width: 50, height: 14), role: "AXLink"),
                     Marks.Mark(id: 10, rect: CGRect(x: 200, y: 60, width: 160, height: 12), role: "AXLink")]
        let badges = Marks.layout(shot, marks).map(\.badge)
        XCTAssertEqual(badges.count, 2)
        let plain = try XCTUnwrap(Trim.plan(canvas.pixels, perPoint: 1))
        let trim = try XCTUnwrap(Trim.plan(canvas.pixels, perPoint: 1, protect: badges))
        XCTAssertLessThan(trim.left, plain.left)
        XCTAssertLessThanOrEqual(trim.left, 60 - Trim.clearance)
        for b in badges {
            let kept = try XCTUnwrap(trim.box(b), "\(b)")
            XCTAssertEqual(kept.width, b.width, accuracy: 1e-9)
            XCTAssertEqual(kept.height, b.height, accuracy: 1e-9)
        }
    }
}
