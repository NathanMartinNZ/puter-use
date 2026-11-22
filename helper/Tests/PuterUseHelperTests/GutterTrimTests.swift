import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Blank margins left out of a window's picture (`Trim`): blank sides either side of the content (a scroll
/// bar at the right edge staying beside it) and blank rows at the bottom, with the picture's pixels mapping
/// back to the window's. Captures here are 560x448 (20x16 tiles, 320 tokens) at 0.75 px per point.
final class GutterTrimTests: XCTestCase {
    static let perPoint = 0.75

    /// A capture to paint: opaque pixels of one colour, rects painted over it (top-left coordinates).
    struct Canvas {
        let w: Int, h: Int
        var rgba: [UInt8]

        init(_ w: Int = 560, _ h: Int = 448, _ c: UInt8 = 255) {
            (self.w, self.h) = (w, h)
            rgba = [UInt8](repeating: 255, count: w * h * 4)
            fill(0, 0, w, h, c)
        }

        mutating func fill(_ x: Int, _ y: Int, _ fw: Int, _ fh: Int, _ c: UInt8, alpha: UInt8 = 255) {
            fill(x, y, fw, fh, (c, c, c), alpha: alpha)
        }

        mutating func fill(_ x: Int, _ y: Int, _ fw: Int, _ fh: Int, _ c: (UInt8, UInt8, UInt8), alpha: UInt8 = 255) {
            for yy in max(0, y)..<min(h, y + fh) {
                for xx in max(0, x)..<min(w, x + fw) {
                    let i = (yy * w + xx) * 4, seen = alpha > 0  // (premultiplied: see-through is 0, 0, 0, 0)
                    rgba[i] = seen ? c.0 : 0
                    rgba[i + 1] = seen ? c.1 : 0
                    rgba[i + 2] = seen ? c.2 : 0
                    rgba[i + 3] = alpha
                }
            }
        }

        var pixels: Pixels { Pixels(width: w, height: h, rgba: rgba) }

        var image: CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            rgba.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return ctx.makeImage()!
        }
    }

    /// A browser's window over a centred article: its toolbar across the top (buttons at both ends, a line
    /// under it), lines of text in a 180 px column, and a scroll bar at the right edge (its knob near the top).
    static func article(page: UInt8 = 255, ink: UInt8 = 40, scrollBar: Bool = true) -> Canvas {
        var c = Canvas(560, 448, page)
        c.fill(0, 0, 560, 48, 230)  // the toolbar
        for x in [10, 40, 500] { c.fill(x, 12, 20, 24, 60) }  // back, forward, the menu
        c.fill(0, 47, 560, 1, 200)  // the line under it
        for (n, y) in stride(from: 60, to: 440, by: 12).enumerated() {
            c.fill(190, y, n % 4 == 3 ? 120 : 180, 3, ink)
        }
        if scrollBar {
            c.fill(549, 48, 11, 400, 245)  // its track
            c.fill(550, 60, 9, 100, 150)  // its knob
        }
        return c
    }

    func plan(_ c: Canvas, protect: [CGRect] = []) -> Trim? {
        Trim.plan(c.pixels, perPoint: Self.perPoint, protect: protect)
    }

    /// The blank either side of the column is cut, two tiles of it staying by the text (and a few more pixels
    /// so the picture ends on a tile); the scroll bar stays at the right, beside the content, from its knob on
    /// (its track's edge left of the knob is one colour, so it goes with the blank). All rows stay: the text
    /// runs to the bottom.
    func testAnArticlesBlankSidesAreCutAndItsScrollBarStays() throws {
        let trim = try XCTUnwrap(plan(Self.article()))
        XCTAssertEqual(trim, Trim(columns: [131..<429, 550..<560], height: 448, fullWidth: 560, fullHeight: 448))
        XCTAssertTrue(trim.split)
        XCTAssertEqual(trim.width, 308)
        XCTAssertEqual(trim.width % 28, 0)
        XCTAssertEqual([trim.left, trim.right, trim.bottom], [131, 121, 0])
        XCTAssertLessThan(trim.columns[0].lowerBound, 190 - 56 + 1, "two tiles of blank stay by the text, at least")
        XCTAssertGreaterThan(trim.columns[0].upperBound, 370 + 56 - 1)
    }

    func testTheSameInTheDark() throws {
        let trim = try XCTUnwrap(plan(Self.article(page: 30, ink: 220)))
        XCTAssertEqual(trim.columns, [131..<429, 550..<560])
    }

    /// No scroll bar showing: the right side's blank runs to the edge, one run of columns.
    func testWithNoScrollBarOneRunOfColumns() throws {
        let trim = try XCTUnwrap(plan(Self.article(scrollBar: false)))
        XCTAssertFalse(trim.split)
        XCTAssertEqual(trim.columns, [126..<434])
    }

    /// Sides that aren't one colour (a texture, a shade that changes down the page) aren't blank.
    func testASideThatIsntOneColourIsntCut() {
        var textured = Self.article()
        for y in 48..<448 {
            for x in stride(from: (y % 2), to: 190, by: 2) { textured.fill(x, y, 1, 1, 235) }
            for x in stride(from: 370 + (y % 2), to: 549, by: 2) { textured.fill(x, y, 1, 1, 235) }
        }
        XCTAssertNil(plan(textured))
        var shaded = Self.article()
        for y in 48..<448 {
            let v = UInt8(255 - (y - 48) / 20)  // 20 levels down the page, a level at a time
            shaded.fill(0, y, 190, 1, v)
            shaded.fill(370, y, 179, 1, v)
        }
        XCTAssertNil(plan(shaded))
    }

    /// Text across nearly all the width: the sides are too narrow to be worth cutting.
    func testNarrowSidesArentCut() {
        var c = Canvas()
        c.fill(0, 0, 560, 48, 230)
        c.fill(0, 47, 560, 1, 200)
        for y in stride(from: 60, to: 440, by: 12) { c.fill(40, y, 480, 3, 40) }
        XCTAssertNil(plan(c))
    }

    /// A short page (a field and a line of text near the top-left): its blank right side and bottom are cut.
    func testASparsePagesRightSideAndBottomAreCut() throws {
        for (page, ink) in [(UInt8(255), UInt8(40)), (30, 220)] {
            var c = Canvas(560, 448, page)
            c.fill(0, 0, 560, 48, 230)
            c.fill(0, 47, 560, 1, 200)
            c.fill(30, 80, 200, 30, ink)  // the field
            c.fill(30, 120, 170, 4, ink)  // a line of text
            let trim = try XCTUnwrap(plan(c))
            XCTAssertEqual(trim, Trim(columns: [0..<308], height: 196, fullWidth: 560, fullHeight: 448))
            XCTAssertEqual(trim.height % 28, 0)
        }
    }

    /// The window's rounded corners are see-through: they don't stop a column or a row being blank.
    func testSeeThroughCornersStillCountAsBlank() throws {
        var c = Canvas()
        c.fill(0, 0, 560, 48, 230)
        c.fill(0, 47, 560, 1, 200)
        c.fill(30, 80, 200, 30, 40)
        c.fill(30, 120, 170, 4, 40)
        let plain = plan(c)
        c.fill(0, 439, 9, 9, 0, alpha: 0)
        c.fill(551, 439, 9, 9, 0, alpha: 0)
        c.fill(0, 445, 2, 1, 128, alpha: 128)  // a part-covered pixel at its edge
        XCTAssertNotNil(plain)
        XCTAssertEqual(plan(c), plain)
    }

    /// A window's four corners as macOS 26 draws them (and captures them): part-covered pixels fading out along
    /// each edge, at the very edge for 24 points from the corner (18 px here), less so further in. `profile[i]`:
    /// how many pixels of the i-th column (or row) from an edge aren't wholly covered, from the corner.
    static let cornerProfile = [18, 10, 8, 7, 6, 6, 5, 5, 4, 4, 3, 3, 3, 2, 2, 2, 1, 1]

    static func roundCorners(_ c: inout Canvas) {
        func cover(_ x: Int, _ y: Int, _ along: Int, _ run: Int) {  // `along`: how far from the corner, of `run`
            let i = (y * c.w + x) * 4, a = UInt8(min(254, 30 + 220 * along / max(1, run)))
            if c.rgba[i + 3] <= a { return }  // (part-covered already, from the other edge)
            for k in 0..<3 { c.rgba[i + k] = UInt8(Int(c.rgba[i + k]) * Int(a) / 255) }  // premultiplied
            c.rgba[i + 3] = a
        }
        for (i, run) in cornerProfile.enumerated() {
            for along in 0..<run {
                for (x, y) in [(i, along), (c.w - 1 - i, along), (i, c.h - 1 - along), (c.w - 1 - i, c.h - 1 - along),
                               (along, i), (c.w - 1 - along, i), (along, c.h - 1 - i), (c.w - 1 - along, c.h - 1 - i)] {
                    cover(x, y, along, run)
                }
            }
        }
    }

    /// A short page in a window with such corners (the probe's web window): its blank bottom and right side are cut
    /// as without them, and no 1-px "scroll bar" of corner pixels stays at the right edge.
    func testRoundedCornersFadingAlongTheEdgesStillCountAsBlank() throws {
        for (page, ink) in [(UInt8(255), UInt8(40)), (30, 220)] {
            var c = Canvas(560, 448, page)
            c.fill(0, 0, 560, 48, 230)
            c.fill(0, 47, 560, 1, 200)
            c.fill(30, 80, 200, 30, ink)
            c.fill(30, 120, 170, 4, ink)
            let plain = try XCTUnwrap(plan(c))
            Self.roundCorners(&c)
            let trim = try XCTUnwrap(plan(c))
            XCTAssertEqual(trim, plain)
            XCTAssertEqual(trim, Trim(columns: [0..<308], height: 196, fullWidth: 560, fullHeight: 448))
            XCTAssertFalse(trim.split)
        }
    }

    /// A line down the window's right edge, a pixel or two wide (a border, its corner's edge): no scroll bar. The blank
    /// right side is cut, and the line with it; a scroll bar's knob (a few points wide) still stays.
    func testAThinLineAtTheRightEdgeIsNoScrollBar() throws {
        var c = Canvas(560, 448, 255)
        c.fill(0, 0, 560, 48, 230)
        c.fill(0, 47, 560, 1, 200)
        c.fill(30, 80, 200, 30, 40)
        c.fill(30, 120, 170, 4, 40)
        let plain = try XCTUnwrap(plan(c))
        for width in [1, 2] {
            var edged = c
            for y in stride(from: 48, to: 448, by: 2) { edged.fill(560 - width, y, width, 1, 120) }  // dashed: not one colour
            let trim = try XCTUnwrap(plan(edged))
            XCTAssertFalse(trim.split, "\(width) px")
            XCTAssertEqual(trim.columns, plain.columns)
        }
        let content = Array(repeating: 48, count: 100) + Array(repeating: 400, count: 200)
        XCTAssertEqual(Trim.sides(content + Array(repeating: 48, count: 256) + [400, 400, 400, 400], perPoint: Self.perPoint,
                                  pad: 56, tile: 28)?.strip, 4, "4 px (5 pt) is a scroll bar's knob")
        let thin = Trim.sides(content + Array(repeating: 48, count: 258) + [400, 400], perPoint: Self.perPoint, pad: 56, tile: 28)
        XCTAssertEqual(thin?.strip, 0)
        XCTAssertEqual(thin?.right, 258 - 56 + 2, "the blank cut, and the line with it")
    }

    /// A badge or the focused element in a blank side: the cut stops short of it. Too little left to cut on
    /// that side: none.
    func testNeverThroughWhatMustStay() throws {
        let badge = CGRect(x: 100, y: 200, width: 20, height: 12)
        let trim = try XCTUnwrap(plan(Self.article(), protect: [badge]))
        XCTAssertEqual(trim.left, 84, "4 px short of it, then back to a whole tile")
        XCTAssertEqual(trim.box(badge), CGRect(x: 16, y: 200, width: 20, height: 12), "all of it in the picture")
        let nearEdge = try XCTUnwrap(plan(Self.article(), protect: [CGRect(x: 10, y: 200, width: 20, height: 12)]))
        XCTAssertEqual(nearEdge.left, 0)
        XCTAssertTrue(nearEdge.right > 0)
        let right = try XCTUnwrap(plan(Self.article(), protect: [CGRect(x: 500, y: 300, width: 30, height: 20)]))
        XCTAssertNotNil(right.box(CGRect(x: 500, y: 300, width: 30, height: 20)))
        XCTAssertEqual(right.box(CGRect(x: 500, y: 300, width: 30, height: 20))?.width, 30)
        let below = CGRect(x: 30, y: 300, width: 40, height: 20)
        var sparse = Canvas()
        sparse.fill(0, 0, 560, 48, 230)
        sparse.fill(30, 80, 200, 30, 40)
        let kept = try XCTUnwrap(Trim.plan(sparse.pixels, perPoint: Self.perPoint, protect: [below]))
        XCTAssertGreaterThanOrEqual(kept.height, 324, "rows down to it, and 4 more")
    }

    /// Content in the rows at the top of a blank side (a page's logo, under the window's title bar) ends the
    /// blank side there: it isn't cut with what's over the side.
    func testContentHighUpEndsTheBlankSide() throws {
        var c = Self.article()
        c.fill(0, 0, 560, 48, 255)  // no toolbar: a title bar, and the page's header under it
        c.fill(0, 0, 560, 20, 230)
        c.fill(0, 19, 560, 1, 200)
        c.fill(20, 30, 40, 40, 60)  // its logo
        let trim = try XCTUnwrap(plan(c))
        XCTAssertEqual(trim.left, 0)
        XCTAssertTrue(trim.split)
    }

    /// Content right to the edge (no blank, no scroll bar there): only the left side is cut.
    func testContentToTheEdgeKeepsThatSide() throws {
        var c = Self.article(scrollBar: false)
        for y in stride(from: 60, to: 440, by: 12) { c.fill(190, y, 370, 3, 40) }
        let trim = try XCTUnwrap(plan(c))
        XCTAssertEqual(trim.columns, [112..<560])
    }

    /// Nothing below the toolbar at all: no sides to cut around, only the blank below it.
    func testAnEmptyWindowKeepsItsWidth() throws {
        var c = Canvas()
        c.fill(0, 0, 560, 48, 230)
        for x in [10, 40, 500] { c.fill(x, 12, 20, 24, 60) }
        c.fill(0, 47, 560, 1, 200)
        let trim = try XCTUnwrap(plan(c))
        XCTAssertEqual(trim.columns, [0..<560])
        XCTAssertEqual(trim.height, 112)
    }

    /// A blank bottom of a fifth: it'd save 6% of the tokens, too little for a picture unlike the window.
    func testTooLittleToSaveIsNoTrim() {
        var c = Canvas()
        c.fill(0, 0, 560, 48, 230)
        for y in stride(from: 60, to: 351, by: 12) { c.fill(20, y, 520, 3, 40) }
        XCTAssertNil(plan(c))
    }

    func testTooSmallACaptureIsNoTrim() {
        XCTAssertNil(Trim.plan(Canvas(160, 448).pixels, perPoint: Self.perPoint))
    }

    // MARK: - the picture's pixels and the window's

    static let split = Trim(columns: [131..<428, 549..<560], height: 448, fullWidth: 560, fullHeight: 448)

    /// From the picture to the capture: the content's run, then the scroll bar's; nothing off the picture's
    /// sides; past its bottom, the window as it was.
    func testPicturePixelsMapToTheCaptures() {
        let t = Self.split
        XCTAssertEqual(t.toCapture(CGPoint(x: 0, y: 10)), CGPoint(x: 131, y: 10))
        XCTAssertEqual(t.toCapture(CGPoint(x: 296.5, y: 5)), CGPoint(x: 427.5, y: 5))
        XCTAssertEqual(t.toCapture(CGPoint(x: 297, y: 5)), CGPoint(x: 549, y: 5), "the scroll bar's first column")
        XCTAssertEqual(t.toCapture(CGPoint(x: 303.5, y: 400)), CGPoint(x: 555.5, y: 400))
        XCTAssertEqual(t.toCapture(CGPoint(x: 308, y: 5)), CGPoint(x: 560, y: 5), "its right edge")
        XCTAssertNil(t.toCapture(CGPoint(x: 308.5, y: 5)))
        XCTAssertNil(t.toCapture(CGPoint(x: -1, y: 5)))
        let short = Trim(columns: [0..<308], height: 196, fullWidth: 560, fullHeight: 448)
        XCTAssertEqual(short.toCapture(CGPoint(x: 40, y: 300)), CGPoint(x: 40, y: 300), "below the picture: as in the window")
    }

    /// From the capture to the picture: nothing where it's cut (beside the content, left of the scroll bar, below).
    func testCapturePixelsMapToThePictures() {
        let t = Self.split
        XCTAssertEqual(t.toImage(CGPoint(x: 131, y: 10)), CGPoint(x: 0, y: 10))
        XCTAssertEqual(t.toImage(CGPoint(x: 555, y: 10)), CGPoint(x: 303, y: 10))
        XCTAssertEqual(t.toImage(CGPoint(x: 560, y: 10)), CGPoint(x: 308, y: 10))
        XCTAssertNil(t.toImage(CGPoint(x: 100, y: 10)), "the left side, cut")
        XCTAssertNil(t.toImage(CGPoint(x: 500, y: 10)), "left of the scroll bar, cut")
        let short = Trim(columns: [0..<308], height: 196, fullWidth: 560, fullHeight: 448)
        XCTAssertNil(short.toImage(CGPoint(x: 40, y: 300)), "below the picture")
    }

    /// Every point of the picture comes back to itself, both runs and the line between them.
    func testThereAndBackAgain() {
        for t in [Self.split, Trim(columns: [56..<500], height: 300, fullWidth: 560, fullHeight: 448)] {
            for x in stride(from: 0.0, to: Double(t.width), by: 0.5) {
                let p = CGPoint(x: x, y: 123.5)
                XCTAssertEqual(t.toCapture(p).flatMap(t.toImage), p, "\(x)")
            }
        }
    }

    /// A box (a change) as the picture shows it: the parts in each run side by side; nil when all of it is cut.
    func testBoxesAcrossTheRuns() {
        let t = Self.split
        XCTAssertEqual(t.box(CGRect(x: 400, y: 50, width: 160, height: 20)), CGRect(x: 269, y: 50, width: 39, height: 20))
        XCTAssertEqual(t.box(CGRect(x: 200, y: 50, width: 20, height: 20)), CGRect(x: 69, y: 50, width: 20, height: 20))
        XCTAssertNil(t.box(CGRect(x: 450, y: 50, width: 90, height: 20)), "all of it left of the scroll bar")
        XCTAssertNil(t.box(CGRect(x: 0, y: 50, width: 100, height: 20)))
        let short = Trim(columns: [0..<308], height: 196, fullWidth: 560, fullHeight: 448)
        XCTAssertEqual(short.box(CGRect(x: 10, y: 180, width: 20, height: 40)), CGRect(x: 10, y: 180, width: 20, height: 16))
        XCTAssertNil(short.box(CGRect(x: 10, y: 200, width: 20, height: 40)))
    }

    /// The picture: each pixel is the capture's pixel it maps to.
    func testTheCroppedPicture() throws {
        var c = Canvas()
        for x in 0..<560 { c.fill(x, 0, 1, 448, (UInt8(x % 256), UInt8(x / 256 * 100), 7)) }
        c.fill(0, 400, 560, 1, (1, 2, 3))
        for t in [Trim(columns: [131..<428, 549..<560], height: 420, fullWidth: 560, fullHeight: 448),
                  Trim(columns: [0..<308], height: 196, fullWidth: 560, fullHeight: 448)] {
            let img = try XCTUnwrap(t.crop(c.image))
            XCTAssertEqual(img.width, t.width)
            XCTAssertEqual(img.height, t.height)
            let px = try XCTUnwrap(Pixels(img))
            for x in [0, 1, 150, 296, 297, 300, 307] where x < t.width {
                for y in [0, 195, 400, t.height - 1] where y < t.height {  // (row 400 is a colour of its own)
                    let from = try XCTUnwrap(t.toCapture(CGPoint(x: x, y: y)))
                    let i = (y * px.width + x) * 4, j = (Int(from.y) * c.w + Int(from.x)) * 4
                    XCTAssertEqual(Array(px.rgba[i..<(i + 4)]), Array(c.rgba[j..<(j + 4)]), "(\(x),\(y))")
                }
            }
        }
        XCTAssertNil(Self.split.crop(Canvas(300, 300).image), "another size of capture")
    }
}
