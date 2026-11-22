import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Parts of a window that keep moving by themselves (a spinner, a clock) are left out of an act's change when
/// they were moving already as the agent's last image was taken and still are (`Ambient`, `Motion`,
/// `CellDiff`). Frames here are 240 px wide, so a pixel is a cell; the window is taken to be 1280 pt wide.
final class AmbientMaskTests: XCTestCase {
    static let perPoint = CGSize(width: 240.0 / 1280, height: 240.0 / 1280)
    static var maxSide: CGSize { Ambient.maxCells(perPoint: perPoint) }

    /// Where the spinner turns (cells), and where a label is.
    static let spinner = CGRect(x: 180, y: 20, width: 8, height: 8)
    static let label = CGRect(x: 30, y: 100, width: 40, height: 3)

    /// A 240x150 frame (top-left coordinates): the spinner's dark quarter at `phase` (0-3), a clock showing
    /// `tick` (its last digit moves), and what else is drawn (`dark`).
    static func frame(phase: Int = 0, tick: Int = 0, dark: [CGRect] = []) -> Signature {
        let ctx = CGContext(data: nil, width: 240, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 150 - r.maxY, width: r.width, height: r.height) }
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 150))
        ctx.setFillColor(gray: 0.2, alpha: 1)
        let quarters = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 4), CGPoint(x: 0, y: 4)]
        let q = quarters[phase % 4]
        ctx.fill(flip(CGRect(x: spinner.minX + q.x, y: spinner.minY + q.y, width: 4, height: 4)))
        ctx.fill(flip(CGRect(x: 150, y: 40, width: 12, height: 4)))  // the clock's hours, always there
        ctx.fill(flip(CGRect(x: 164 + Double(tick % 3) * 2, y: 40, width: 2, height: 4)))  // its last digit
        for r in dark { ctx.fill(flip(r)) }
        return Signature(ctx.makeImage()!)
    }

    /// The spinner turning and the clock ticking over a few frames with nothing done: one place that moves for
    /// each, grown by a cell.
    func testFramesThatKeepMovingMakeRegions() throws {
        var m = Motion()
        let frames = [Self.frame(phase: 0), Self.frame(phase: 1, tick: 1), Self.frame(phase: 2, tick: 1)]
        for (a, b) in zip(frames, frames.dropFirst()) { m.add(a, b) }
        XCTAssertEqual(m.pairs, 2)
        let regions = Ambient.regions(m, perPoint: Self.perPoint)
        XCTAssertEqual(regions.count, 2)
        let spun = try XCTUnwrap(regions.first { $0.intersects(Self.spinner) })
        XCTAssertTrue(spun.contains(Self.spinner.insetBy(dx: -1, dy: -1)) || spun.contains(Self.spinner))
        XCTAssertLessThanOrEqual(spun.width, Self.spinner.width + 2)
        XCTAssertTrue(regions.contains { $0.intersects(CGRect(x: 164, y: 40, width: 4, height: 4)) }, "the clock's digit")
    }

    /// Something big moving (a list scrolling, a video) is no part to leave out.
    func testABigMovingAreaIsNoRegion() {
        var m = Motion()
        m.add(Self.frame(), Self.frame(dark: [CGRect(x: 10, y: 60, width: 120, height: 60)]))
        XCTAssertTrue(Ambient.regions(m, perPoint: Self.perPoint).isEmpty)
        XCTAssertFalse(m.regions(maxSide: CGSize(width: 1000, height: 1000)).isEmpty, "(it moved)")
    }

    /// A gap of one cell still joins what moved; three don't.
    func testNearbyCellsMakeOneRegion() {
        var m = Motion()
        m.add(Self.frame(), Self.frame(dark: [CGRect(x: 20, y: 20, width: 3, height: 3), CGRect(x: 24, y: 20, width: 3, height: 3)]))
        XCTAssertEqual(m.regions(maxSide: Self.maxSide).count, 1)
        var apart = Motion()
        apart.add(Self.frame(), Self.frame(dark: [CGRect(x: 20, y: 20, width: 3, height: 3), CGRect(x: 26, y: 20, width: 3, height: 3)]))
        XCTAssertEqual(apart.regions(maxSide: Self.maxSide).count, 2)
    }

    /// A pair of another size (a new plan) starts over; two frames of different sizes are no pair.
    func testMotionStartsOverAtANewSize() {
        func blank(_ w: Int) -> Signature {
            let ctx = CGContext(data: nil, width: w, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 0.9, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: 150))
            return Signature(ctx.makeImage()!)
        }
        var m = Motion()
        m.add(Self.frame(phase: 0), Self.frame(phase: 1))
        m.add(blank(200), Self.frame())
        XCTAssertEqual(m.pairs, 1, "no pair")
        m.add(blank(200), blank(200))
        XCTAssertEqual(m.w, 200)
        XCTAssertEqual(m.pairs, 1)
        XCTAssertTrue(m.regions(maxSide: Self.maxSide).isEmpty, "what moved at the old size is gone")
    }

    /// Left out only when it was moving as the agent's image was taken and moves still, and the act didn't aim at it.
    func testWhatsLeftOut() {
        let known = [Self.spinner.insetBy(dx: -1, dy: -1)], moving = [Self.spinner.insetBy(dx: -1, dy: -1)]
        XCTAssertEqual(Ambient.mask(known: known, moving: moving, touched: [], maxSide: Self.maxSide), known)
        XCTAssertTrue(Ambient.mask(known: known, moving: [], touched: [], maxSide: Self.maxSide).isEmpty, "it stopped")
        XCTAssertTrue(Ambient.mask(known: [], moving: moving, touched: [], maxSide: Self.maxSide).isEmpty, "moving for the first time")
        let click = Ambient.touched(points: [CGPoint(x: 980, y: 128)], frames: [], perPoint: Self.perPoint, offset: .zero)
        XCTAssertTrue(Ambient.mask(known: known, moving: moving, touched: click, maxSide: Self.maxSide).isEmpty, "clicked on")
        let elsewhere = Ambient.touched(points: [CGPoint(x: 100, y: 500)], frames: [], perPoint: Self.perPoint, offset: .zero)
        XCTAssertEqual(Ambient.mask(known: known, moving: moving, touched: elsewhere, maxSide: Self.maxSide), known)
        let wider = CGRect(x: 176, y: 18, width: 14, height: 10)  // it moves a little further now
        XCTAssertEqual(Ambient.mask(known: known, moving: [wider], touched: [], maxSide: Self.maxSide), [known[0].union(wider)])
    }

    /// A spinner turning and a clock ticking since the agent's last image, and nothing else: no change once
    /// they're left out. (Here the frames before that image saw them go all the way round, as do the act's.)
    func testAChangeOnlyInWhatsLeftOutIsNoChange() throws {
        let d = try XCTUnwrap(CellDiff(Self.frame(phase: 2, tick: 2), from: Self.frame(phase: 0, tick: 0)))
        XCTAssertFalse(d.isEmpty)
        var m = Motion()
        let frames = [(0, 0), (1, 1), (2, 2), (3, 0), (0, 1)].map { Self.frame(phase: $0.0, tick: $0.1) }
        for (a, b) in zip(frames, frames.dropFirst()) { m.add(a, b) }
        let moving = Ambient.regions(m, perPoint: Self.perPoint)
        XCTAssertEqual(moving.count, 2, "the spinner, the clock's digit")
        let mask = Ambient.mask(known: moving, moving: moving, touched: [], maxSide: Self.maxSide)
        XCTAssertTrue(d.clearing(mask).isEmpty)
        XCTAssertNil(d.clearing(mask).change(outW: 952, outH: 595))
    }

    /// Anything beside it still counts, and what's left says where.
    func testAChangeBesideItStillCounts() throws {
        let d = try XCTUnwrap(CellDiff(Self.frame(phase: 2, dark: [Self.label]), from: Self.frame(phase: 0)))
        let mask = [Self.spinner.insetBy(dx: -1, dy: -1)]
        let rest = d.clearing(mask)
        XCTAssertEqual(rest.box, Self.label)
        XCTAssertEqual(rest.count, 120)
    }

    /// A key typed by a terminal's blinking cursor: the field it went to is aimed at, so nothing is left out.
    func testTypingByABlinkingCursorCounts() throws {
        let cursor = CGRect(x: 60, y: 70, width: 2, height: 4)
        let before = Self.frame(dark: [cursor])
        let now = Self.frame(dark: [CGRect(x: 60, y: 70, width: 1, height: 4), CGRect(x: 63, y: 70, width: 2, height: 4)])
        let known = [cursor.insetBy(dx: -1, dy: -1)]
        let moving = [CGRect(x: 62, y: 69, width: 4, height: 6)]
        let terminal = Ambient.touched(points: [], frames: [CGRect(x: 100, y: 300, width: 600, height: 200)],
                                       perPoint: Self.perPoint, offset: .zero)
        let mask = Ambient.mask(known: known, moving: moving, touched: terminal, maxSide: Self.maxSide)
        XCTAssertTrue(mask.isEmpty)
        let d = try XCTUnwrap(CellDiff(now, from: before))
        XCTAssertFalse(d.clearing(mask).isEmpty)
    }

    /// What differs, as `Signature.diff` has always said it.
    func testTheCellsAgreeWithSignatureDiff() throws {
        let pairs = [(Self.frame(phase: 1), Self.frame()), (Self.frame(dark: [Self.label]), Self.frame(phase: 3, tick: 1)),
                     (Self.frame(), Self.frame())]
        for (now, before) in pairs {
            let d = try XCTUnwrap(CellDiff(now, from: before))
            let old = now.diff(before, outW: 952, outH: 595), new = d.change(outW: 952, outH: 595)
            XCTAssertEqual(old?.box, new?.box)
            XCTAssertEqual(old?.fraction, new?.fraction)
            XCTAssertEqual(now.diff(before, outW: now.w, outH: now.h)?.box, d.box)
        }
    }

    func testFramesOfDifferentSizesHaveNoCells() {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        XCTAssertNil(CellDiff(Signature(ctx.makeImage()!), from: Self.frame()))
    }

    /// Where an act aimed, in cells: a little around each point, and each frame, from where the capture starts.
    func testWhereAnActAimed() {
        let half = CGSize(width: 0.5, height: 0.5), offset = CGPoint(x: 20, y: 10)
        let t = Ambient.touched(points: [CGPoint(x: 100, y: 50)], frames: [CGRect(x: 40, y: 30, width: 20, height: 10)],
                                perPoint: half, offset: offset)
        XCTAssertEqual(t, [CGRect(x: 36, y: 16, width: 8, height: 8), CGRect(x: 10, y: 10, width: 10, height: 5)])
    }
}
