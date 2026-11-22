import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// How many pixels a capture gets (`Sizing.size`): a side that ends a few pixels past a tile line is
/// trimmed onto it, by one factor for both sides and a few percent at most; sizes that don't are as they
/// were. Arithmetic only (no display needed); a Retina display unless said otherwise.
final class CaptureSizingTests: XCTestCase {
    func size(_ s: Sizing, _ w: Double, _ h: Double, native: CGFloat = 2, zoom: Bool = false) -> [Int] {
        let (a, b) = s.size(for: CGRect(x: 0, y: 0, width: w, height: h), native: native, zoom: zoom)
        return [a, b]
    }

    func tokens(_ s: Sizing, _ px: [Int]) -> Double { s.tokens(Double(px[0]), Double(px[1])) }

    /// A full-screen window on a 16" MacBook (1728x1117 pt) came out 1039x672, 3 px past a tile line: a
    /// whole column of 24 tiles for them. Now 1036x669, a column fewer, for a 0.35% smaller picture. The
    /// same for a 5K screen (1095 was 3 px past) and a 1344x840 pt window (985 was 5 px past).
    func testAStrayColumnIsTrimmed() {
        let s = Sizing()
        let px = size(s, 1728, 1117)
        XCTAssertEqual(px, [1036, 669])
        XCTAssertEqual(tokens(s, px), 888)
        XCTAssertLessThan(tokens(s, px), s.tokens(1039, 672), "a column of tiles fewer")
        XCTAssertEqual(size(s, 2560, 1440), [1092, 614])
        XCTAssertEqual(tokens(s, [1092, 614]), 858, "was 880")
        XCTAssertEqual(size(s, 1344, 840), [980, 612])
        XCTAssertEqual(tokens(s, [980, 612]), 770, "was 792")
    }

    /// A 400x250 pt region at 2 px/pt (how such a zoom was taken before zooms tapered) came out 761x476,
    /// 5 px past a line. Now 756x472, a column fewer. Asked for as an ordinary capture at 2 px/pt, so the
    /// zoom taper (`CaptureSizingZoomTests`) leaves it alone.
    func testAStrayColumnOnASharpCaptureIsTrimmed() {
        var s = Sizing()
        s.scale = 2
        let px = size(s, 400, 250)
        XCTAssertEqual(px, [756, 472])
        XCTAssertEqual(tokens(s, px), 459)
        XCTAssertLessThan(tokens(s, px), s.tokens(761, 476), "a column of tiles fewer")
    }

    /// Sizes with no side just past a tile line come out exactly as before, the default agent window
    /// (1440x900 pt) among them.
    func testSizesWithNoStrayAreUnchanged() {
        let s = Sizing()
        XCTAssertEqual(size(s, 1440, 900), [1064, 665])
        XCTAssertEqual(size(s, 1360, 860), [1008, 637])
        XCTAssertEqual(size(s, 1280, 860), [952, 639])
        XCTAssertEqual(size(s, 1280, 800), [940, 588])
        XCTAssertEqual(size(s, 1512, 982), [1034, 672])
        XCTAssertEqual(size(s, 1712, 1409), [918, 756])
        XCTAssertEqual(size(s, 627, 877), [448, 626])
        XCTAssertEqual(size(s, 967, 639), [700, 462])
        XCTAssertEqual(size(s, 420, 240), [294, 168])
    }

    /// The trim only ever shrinks, only to save tiles, and by at most 2.5% (1% where it leaves the picture
    /// under 0.6 px/pt, where small text starts to blur).
    func testTheTrimIsBounded() {
        let s = Sizing()
        var bad: [String] = []
        for w in stride(from: 300.0, through: 2500, by: 37) {
            for h in stride(from: 200.0, through: 1600, by: 41) {
                for scale in [0.75, 0.62, 0.45, 1.5, 2.0] {
                    let t = s.trimStrays(w, h, scale)
                    let (bw, bh) = s.pixels(w, h, scale), (aw, ah) = s.pixels(w, h, t)
                    let fewer = s.tokens(Double(aw), Double(ah)) < s.tokens(Double(bw), Double(bh))
                    if t > scale || t < scale * (1 - Sizing.maxTrim) - 1e-12
                        || (t < Sizing.softScale && t < scale * (1 - Sizing.softTrim) - 1e-12) || (t < scale && !fewer)
                    {
                        bad.append("\(w)x\(h) at \(scale) -> \(t)")
                    }
                }
            }
        }
        XCTAssertEqual(Array(bad.prefix(5)), [])
    }

    /// Across window sizes from 400x300 to 2575x1675 pt, no capture ends 1-6 px past a tile line any more,
    /// and none goes over the token cap.
    func testNoWindowEndsJustPastATileLine() {
        let s = Sizing()
        var bad: [String] = []
        for w in stride(from: 400.0, through: 2575, by: 25) {
            for h in stride(from: 300.0, through: 1675, by: 25) {
                let px = size(s, w, h)
                let stray = px.contains { $0 > s.tile && (1...Sizing.maxStray).contains($0 % s.tile) }
                if stray || tokens(s, px) > Double(s.maxTokens) { bad.append("\(w)x\(h) -> \(px)") }
            }
        }
        XCTAssertEqual(Array(bad.prefix(5)), [])
    }
}
