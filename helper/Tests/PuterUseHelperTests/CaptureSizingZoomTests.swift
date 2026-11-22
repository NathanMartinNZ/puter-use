import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// How sharp a `region` zoom is (`Sizing.zoomFor`): full 2 px/pt for a small region, tapering to 1.5 by
/// 400x250 pt and to no less than 1.4 for big ones, never more than the zoom scale asked for. Arithmetic
/// only (no display needed); a Retina display unless said otherwise.
final class CaptureSizingZoomTests: XCTestCase {
    func size(_ s: Sizing, _ w: Double, _ h: Double, native: CGFloat = 2, zoom: Bool = true) -> [Int] {
        let (a, b) = s.size(for: CGRect(x: 0, y: 0, width: w, height: h), native: native, zoom: zoom)
        return [a, b]
    }

    func tokens(_ s: Sizing, _ px: [Int]) -> Double { s.tokens(Double(px[0]), Double(px[1])) }

    /// Small regions keep 2 px/pt, as before: 150x60 pt is 280x112 (40 tokens), 220x140 pt 420x267 (150).
    func testSmallRegionsKeepTwoPxPerPoint() {
        let s = Sizing()
        XCTAssertEqual(s.zoomFor(150, 60), 2)
        XCTAssertEqual(size(s, 150, 60), [280, 112])
        XCTAssertEqual(tokens(s, [280, 112]), 40)
        XCTAssertEqual(s.zoomFor(220, 140), 2)
        XCTAssertEqual(size(s, 220, 140), [420, 267])
    }

    /// A 400x250 pt zoom is taken at 1.5 px/pt: 582x364, 273 tokens (476 at 2). A 600x400 pt one is brought
    /// down to 1.4 to stay at 600 tokens (925 before). A zoom of a whole 1440x900 pt window is still set by
    /// the token cap, as before.
    func testBiggerRegionsTaper() {
        let s = Sizing()
        XCTAssertEqual(s.zoomFor(400, 250), 1.5)
        let mid = size(s, 400, 250)
        XCTAssertEqual(mid, [582, 364])
        XCTAssertEqual(tokens(s, mid), 273)
        XCTAssertEqual(s.zoomFor(300, 200), 1.75, accuracy: 0.01, "on the way down")
        XCTAssertEqual(s.zoomFor(600, 400), 1.4, accuracy: 1e-9)
        let big = size(s, 600, 400)
        XCTAssertEqual(big, [840, 560])
        XCTAssertEqual(tokens(s, big), 600)
        XCTAssertEqual(s.zoomFor(1440, 900), 1.4, accuracy: 1e-9)
        XCTAssertEqual(size(s, 1440, 900), [1120, 700])
        XCTAssertEqual(tokens(s, [1120, 700]), 1000)
    }

    /// Snapped onto the tile grid, a zoom set at 1.4 px/pt or more stays at 1.4 at least: the probe's 620x415 pt
    /// zoom came out at 838x560, 1.35 px/pt (the snap down went past the floor); now 868x580, with the floor. Every
    /// size in the taper's range keeps it, unless the token cap takes it lower (a whole 1440x900 pt window).
    func testASnappedZoomKeepsItsFloor() {
        let s = Sizing()
        let probe = size(s, 620.5, 414.6)
        XCTAssertEqual(probe, [868, 580])
        XCTAssertGreaterThanOrEqual(Double(probe[0]) / 620.5, Sizing.minZoomScale - 0.002)
        XCTAssertLessThanOrEqual(tokens(s, probe), 0.7 * Double(s.maxTokens))
        var bad: [String] = []
        for aspect in [0.5, 0.625, 0.75, 1.0] {
            for side in stride(from: 300.0, through: 760, by: 7) {
                let w = side, h = (side * aspect).rounded(), px = size(s, w, h)
                let capped = s.tokens(w * Sizing.minZoomScale, h * Sizing.minZoomScale) > Double(s.maxTokens)
                if !capped, Double(px[0]) / w < Sizing.minZoomScale - 1.0 / w - 1e-9 || Double(px[1]) / h < Sizing.minZoomScale - 1.0 / h - 1e-9 {
                    bad.append("\(w)x\(h) -> \(px)")
                }
                if tokens(s, px) > Double(s.maxTokens) { bad.append("\(w)x\(h) over the cap") }
            }
        }
        XCTAssertEqual(Array(bad.prefix(5)), [])
        XCTAssertEqual(size(s, 1440, 900), [1120, 700], "the token cap still sets a whole window's")
        // Up onto the grid where that costs no tile.
        // 610x405 pt at 1.4 is 854x567 (31x21 tiles); 868x576 is the same tiles, a side on its line.
        XCTAssertEqual(s.zoomFloor(610, 405, set: 1.5, snapped: 1.38), 868.0 / 610, accuracy: 1e-9)
        XCTAssertEqual(s.zoomFloor(610, 405, set: 1.41, snapped: 1.38), 1.4, "never above the scale it was set at")
        XCTAssertEqual(s.zoomFloor(610, 405, set: 1.5, snapped: 1.45), 1.45, "above the floor: as snapped")
        XCTAssertEqual(s.zoomFloor(610, 405, set: 1.2, snapped: 1.15), 1.15, "set lower by the token cap: as snapped")
    }

    /// As a region grows its zoom scale never rises and stays within 1.4-2 px/pt, and its picture never
    /// gets smaller (a bigger region never comes back with fewer pixels).
    func testTheTaperIsSmooth() {
        let s = Sizing()
        var bad: [String] = []
        for aspect in [0.3, 0.5, 0.625, 1.0, 1.6] {
            var last = Double.infinity, area = 0.0
            for side in stride(from: 10.0, through: 2000, by: 3) {
                let w = side, h = side * aspect, z = s.zoomFor(w, h)
                if z < Sizing.minZoomScale - 1e-12 || z > s.zoomScale || z > last + 1e-12 || w * z * h * z < area - 1e-6 {
                    bad.append("\(w)x\(h) -> \(z)")
                }
                last = z
                area = w * z * h * z
            }
        }
        XCTAssertEqual(Array(bad.prefix(5)), [])
    }

    /// Never more than the zoom scale asked for: a lower one is used for every size, and a higher one only
    /// for small regions.
    func testTheZoomScaleAskedForIsTheMost() {
        var s = Sizing()
        s.zoomScale = 1.25
        for (w, h) in [(100.0, 50.0), (400, 250), (600, 400), (1440, 900)] { XCTAssertEqual(s.zoomFor(w, h), 1.25) }
        s.zoomScale = 3
        XCTAssertEqual(s.zoomFor(100, 50), 3)
        XCTAssertEqual(s.zoomFor(400, 250), 1.5)
        XCTAssertEqual(s.zoomFor(600, 400), 1.4, accuracy: 1e-9)
    }

    /// On a 1x display a zoom is held to the display's own 1 px/pt anyway, so the taper changes nothing:
    /// the same pixels as an ordinary capture at 1 px/pt.
    func testNoChangeOnA1xDisplay() {
        let s = Sizing()
        var plain = Sizing()
        plain.scale = 1
        for (w, h) in [(150.0, 60.0), (400, 250), (600, 400), (900, 700)] {
            XCTAssertEqual(size(s, w, h, native: 1), size(plain, w, h, native: 1, zoom: false), "\(w)x\(h)")
        }
        XCTAssertEqual(size(s, 400, 250, native: 1), [400, 250])
        XCTAssertEqual(size(s, 600, 400, native: 1), [588, 392])
    }

    /// The sharp capture that text is read off the screen from (`Handlers.sharpShot`: 1.5 px/pt, zooms at 2,
    /// a 40,000-token cap) keeps its full 2 px/pt on a whole window, as before.
    func testTheSharpCaptureForReadingTextKeepsItsScale() {
        var s = Sizing()
        s.scale = 1.5
        s.zoomScale = 2
        s.maxTokens = 40_000
        XCTAssertEqual(s.zoomFor(1440, 900), 2)
        XCTAssertEqual(size(s, 1440, 900), [2856, 1785])
        XCTAssertEqual(s.zoomFor(2560, 1440), 2)
        XCTAssertEqual(s.zoomFor(120, 40), 2)
    }
}
