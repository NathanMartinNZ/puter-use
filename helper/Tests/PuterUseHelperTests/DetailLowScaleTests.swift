import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// How sparse a picture at `detail: "low"` is (`DetailLow`): as few pixels a point as keep a line of the window's
/// text 10 px high, by the height accessibility gives its texts (their median), no fewer than 0.5 px/pt, never
/// more than an ordinary picture's; a careful 0.65 px/pt when the height isn't known.
final class DetailLowScaleTests: XCTestCase {
    /// The median of the heights that can be one line (the lower of the middle two), from three of them at least.
    func testTheWindowsTextHeight() {
        XCTAssertEqual(DetailLow.textHeight([16, 16, 17, 15, 14]), 16)
        XCTAssertEqual(DetailLow.textHeight([18, 12, 16, 14]), 14, "the lower of the middle two")
        XCTAssertEqual(DetailLow.textHeight([2, 16, 17, 90, 15]), 16, "a hairline and a block of lines left out")
        XCTAssertNil(DetailLow.textHeight([2, 3, 80, 100, 16]), "too few lines left")
        XCTAssertNil(DetailLow.textHeight([16, 16]))
        XCTAssertNil(DetailLow.textHeight([]))
    }

    /// A web page's text and the browser's own: the smaller, as the page is what's read.
    func testAPagesTextCountsToo() {
        XCTAssertEqual(DetailLow.textHeight(window: [16, 16, 16], page: [13, 14, 14, 15]), 14)
        XCTAssertEqual(DetailLow.textHeight(window: [16, 16, 16], page: [13]), 16, "too few on the page to go by")
        XCTAssertEqual(DetailLow.textHeight(window: [], page: [20, 21, 22]), 21)
        XCTAssertNil(DetailLow.textHeight(window: [16], page: []))
    }

    func testTheScale() {
        XCTAssertEqual(DetailLow.scale(textHeight: nil, normal: 0.75), 0.65, "not known: a careful scale")
        XCTAssertEqual(DetailLow.scale(textHeight: 16, normal: 0.75), 0.625, accuracy: 1e-9, "13 pt text: 10 px lines")
        XCTAssertEqual(DetailLow.scale(textHeight: 25, normal: 0.75), 0.5, "big text: the sparsest")
        XCTAssertEqual(DetailLow.scale(textHeight: 12, normal: 0.75), 0.75, "small text: as an ordinary picture")
        XCTAssertEqual(DetailLow.scale(textHeight: 16, normal: 0.5), 0.5, "never sharper than asked for")
        XCTAssertEqual(DetailLow.scale(textHeight: nil, normal: 0.6), 0.6)
    }

    /// Whatever the text's height, a line of it stays 10 px high unless an ordinary picture is sparser already,
    /// and the scale stays between 0.5 px/pt and the ordinary one.
    func testNeverBelowTheLegibilityFloor() {
        for h in stride(from: 6.0, through: 40.0, by: 0.5) {
            let s = DetailLow.scale(textHeight: h, normal: 0.75)
            XCTAssertTrue(h * s >= DetailLow.minTextPixels - 1e-9 || s == 0.75, "\(h) pt at \(s)")
            XCTAssertGreaterThanOrEqual(s, DetailLow.lowest)
            XCTAssertLessThanOrEqual(s, 0.75)
        }
    }

    /// A 1440x900 pt window with 13 pt text: 896x560 (640 tokens) instead of 1064x665 (912).
    func testALowDetailPictureCostsLess() {
        var s = Sizing()
        s.scale = DetailLow.scale(textHeight: 16, normal: s.scale)
        let (w, h) = s.size(for: CGRect(x: 0, y: 0, width: 1440, height: 900), native: 2, zoom: false)
        XCTAssertEqual([w, h], [896, 560])
        XCTAssertEqual(s.tokens(Double(w), Double(h)), 640)
    }

    /// Asked for with `detail: "low"` only; the screen (no text to measure) gets the careful scale, and an
    /// ordinary picture keeps its own.
    @MainActor func testAskedForOnly() {
        XCTAssertTrue(Handlers.Opts(["detail": "low"]).lowDetail)
        XCTAssertTrue(Handlers.Opts(["detail": "LOW"]).lowDetail)
        XCTAssertFalse(Handlers.Opts(["detail": "normal"]).lowDetail)
        XCTAssertFalse(Handlers.Opts([:]).lowDetail)
        XCTAssertEqual(Handlers.detailed(Handlers.Opts([:]), .screen).sizing.scale, 0.75, "not asked: as it was")
        let screen = Handlers.detailed(Handlers.Opts(["detail": "low"]), .screen)
        XCTAssertEqual(screen.sizing.scale, 0.65)
        XCTAssertNil(screen.textHeight)
        XCTAssertEqual(Handlers.detailed(Handlers.Opts(["detail": "low", "scale": 0.5]), .screen).sizing.scale, 0.5)
    }

    /// A window's text height is measured once a while: asked again soon, the height kept is given (none
    /// measured, too) without looking at the window again.
    func testAMeasuredHeightIsKeptAWhile() {
        let now = 1_000_000.0
        AX.measuredText[424_801] = (height: 14, at: now)
        AX.measuredText[424_802] = (height: nil, at: now)
        XCTAssertEqual(AX.textHeight(pid: 0, wid: 424_801, now: now + 5), 14)
        XCTAssertNil(AX.textHeight(pid: 0, wid: 424_802, now: now + AX.textHeightKept - 1))
        AX.measuredText[424_801] = nil
        AX.measuredText[424_802] = nil
    }
}
