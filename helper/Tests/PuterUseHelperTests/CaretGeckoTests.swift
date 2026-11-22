import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// A text cursor blinking where accessibility can't say where it is (Firefox's web pages), told by the shape
/// of what changed (`CaretShape.blinked`). Frames here are 240 px wide, so a pixel is a cell; the window is
/// taken to be 1280 pt wide (5.3 pt a cell, as a 952 px capture of it is).
final class CaretGeckoTests: XCTestCase {
    static let perPoint = CGSize(width: 240.0 / 1280, height: 240.0 / 1280)
    /// The text field the cursor is in (cells): 213x32 pt.
    static let field = CGRect(x: 10, y: 34, width: 40, height: 6)
    /// The cursor, drawn: 1 cell wide, 4 tall (21 pt), in the field.
    static let cursor = CGRect(x: 15, y: 35, width: 1, height: 4)

    /// A 240x190 frame (top-left coordinates): a light page with a line of text, and dark (`dark`) and white
    /// (`white`) rects drawn over it.
    static func frame(dark: [CGRect] = [], white: [CGRect] = []) -> Signature {
        let ctx = CGContext(data: nil, width: 240, height: 190, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 190 - r.maxY, width: r.width, height: r.height) }
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 190))
        ctx.setFillColor(gray: 0.3, alpha: 1)
        ctx.fill(flip(CGRect(x: 20, y: 60, width: 120, height: 3)))  // some text, in every frame
        ctx.setFillColor(gray: 0.1, alpha: 1)
        for r in dark { ctx.fill(flip(r)) }
        ctx.setFillColor(gray: 1, alpha: 1)
        for r in white { ctx.fill(flip(r)) }
        return Signature(ctx.makeImage()!)
    }

    static let off = frame(), on = frame(dark: [cursor])

    func blink(_ now: Signature, _ before: Signature = CaretGeckoTests.off, near: CGRect? = CaretGeckoTests.field,
               typed: Bool = false) -> Bool {
        guard let d = CellDiff(now, from: before) else { return false }
        return CaretShape.blinked(d, near: near, perPoint: Self.perPoint, typed: typed)
    }

    func testTheCursorBlinkingInItsFieldIsNoChange() {
        XCTAssertTrue(blink(Self.on), "drawn")
        XCTAssertTrue(blink(Self.off, Self.on), "gone")
        XCTAssertTrue(blink(Self.on, near: nil), "where the field can't be told: shape alone")
        let straddling = Self.frame(dark: [CGRect(x: 15, y: 35, width: 2, height: 4)])
        XCTAssertTrue(blink(straddling), "across two cells")
    }

    /// Keys, typing or a click since the agent's last image: a sliver like a cursor's may be an "i" or an "l".
    func testNeverAfterTyping() {
        XCTAssertFalse(blink(Self.on, typed: true))
        XCTAssertFalse(blink(Self.on, near: nil, typed: true))
    }

    func testAChangeShapedOtherwiseIsAChange() {
        XCTAssertFalse(blink(Self.frame(dark: [CGRect(x: 15, y: 35, width: 3, height: 4)])), "wider than a cursor")
        XCTAssertFalse(blink(Self.frame(dark: [CGRect(x: 15, y: 36, width: 1, height: 1)])), "a dot")
        XCTAssertFalse(blink(Self.frame(dark: [CGRect(x: 15, y: 35, width: 2, height: 2)])), "a square")
        XCTAssertFalse(blink(Self.frame(dark: [CGRect(x: 15, y: 30, width: 1, height: 10)]), near: nil),
                       "53 pt tall: a divider or a scroll bar, not a line of text")
        let short = Self.frame(dark: [CGRect(x: 15, y: 36, width: 1, height: 2)])  // 11 pt
        XCTAssertTrue(blink(short), "a small font's cursor, in its field")
        XCTAssertFalse(blink(short, near: nil), "where it can't be told, a cursor is three cells tall at least")
    }

    func testOutsideItsFieldIsAChange() {
        let elsewhere = Self.frame(dark: [CGRect(x: 120, y: 35, width: 1, height: 4)])
        XCTAssertFalse(blink(elsewhere))
        XCTAssertTrue(blink(Self.frame(dark: [CGRect(x: 9, y: 35, width: 1, height: 4)])), "at its very edge, cells rounding out")
    }

    func testABrokenSliverIsAChange() {
        let dotAndStem = Self.frame(dark: [CGRect(x: 15, y: 35, width: 1, height: 1), CGRect(x: 15, y: 37, width: 1, height: 2)])
        XCTAssertFalse(blink(dotAndStem))
    }

    /// A character changed rather than a cursor drawn: some of it lighter, some darker.
    func testLighterAndDarkerTogetherIsAChange() {
        let both = Self.frame(dark: [CGRect(x: 15, y: 35, width: 1, height: 2)], white: [CGRect(x: 15, y: 37, width: 1, height: 2)])
        XCTAssertFalse(blink(both))
    }

    func testNothingChangedIsNoBlink() {
        XCTAssertFalse(blink(Self.off), "nothing to tell")
    }

    /// The window's own frames, as act gets them: a 952x755 capture with a cursor 1 px wide and 16 tall at
    /// (63,143), as Firefox drew it, made into a signature like any other.
    func testAFirefoxSizedCapture() throws {
        func capture(cursor: Bool) -> Signature {
            let ctx = CGContext(data: nil, width: 952, height: 755, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 952, height: 755))
            ctx.setFillColor(gray: 0.55, alpha: 1)
            ctx.stroke(CGRect(x: 55.5, y: 755 - 165.5, width: 160, height: 28))  // the field's border
            if cursor {
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fill(CGRect(x: 63, y: 755 - 159, width: 1, height: 16))
            }
            return Signature(ctx.makeImage()!)
        }
        let d = try XCTUnwrap(CellDiff(capture(cursor: true), from: capture(cursor: false)))
        let box = try XCTUnwrap(d.box)
        XCTAssertLessThanOrEqual(box.width, 2)
        let field = Signature.cells(CGRect(x: 74, y: 185, width: 216, height: 38), perPoint: Self.perPoint, offset: .zero)
        XCTAssertTrue(CaretShape.blinked(d, near: field, perPoint: Self.perPoint, typed: false))
        XCTAssertFalse(CaretShape.blinked(d, near: field, perPoint: Self.perPoint, typed: true))
    }

    /// With something that keeps moving left out first (`Ambient`), what's left is the cursor alone.
    func testTheCursorBesideASpinner() throws {
        let spinner = CGRect(x: 180, y: 20, width: 8, height: 8)
        let before = Self.frame(dark: [CGRect(x: 180, y: 20, width: 4, height: 4)])
        let now = Self.frame(dark: [Self.cursor, CGRect(x: 184, y: 24, width: 4, height: 4)])
        let d = try XCTUnwrap(CellDiff(now, from: before))
        XCTAssertFalse(CaretShape.blinked(d, near: Self.field, perPoint: Self.perPoint, typed: false), "the spinner too")
        let rest = d.clearing([spinner.insetBy(dx: -1, dy: -1)])
        XCTAssertTrue(CaretShape.blinked(rest, near: Self.field, perPoint: Self.perPoint, typed: false))
    }

    /// Which actions leave text and its cursor alone: after any other, a cursor-shaped change counts.
    func testWhatLeavesTextAlone() {
        for k in ["wait", "sleep", "wait_for", "scroll", "move", "hover", "screenshot", "read", "clipboard"] {
            XCTAssertTrue(CaretShape.leavesTextAlone(["type": k]), k)
        }
        XCTAssertTrue(CaretShape.leavesTextAlone(["action": "mouse_move"]))
        for k in ["type", "keypress", "key", "click", "left_click", "double_click", "drag", "paste", "set_value", "fill",
                  "select", "menu", "macro", "activate", "focus", "open", "navigate", "something_new"] {
            XCTAssertFalse(CaretShape.leavesTextAlone(["type": k]), k)
        }
    }
}
