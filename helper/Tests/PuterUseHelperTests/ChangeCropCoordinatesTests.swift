import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Coordinates read off an act's picture of only what changed (`Meta.crop`) land where they show: the crop's
/// pixels from its origin in the capture. Pixels off the crop (maybe read off an earlier, whole picture) are
/// refused, and points the agent is told (`toPixels`) are the crop's, none for what it doesn't show. The change's
/// box and the crop's place are given in the crop's pixels and the window's points.
final class ChangeCropCoordinatesTests: XCTestCase {
    /// A window at (100, 50), 560x448 pt, captured at half a pixel a point (280x224); the crop shows 112x56 of it
    /// from (56, 28) of the capture.
    static let window = WinInfo(id: 424_711, pid: 424_711, app: "Probe", title: "",
                                frame: CGRect(x: 100, y: 50, width: 560, height: 448), layer: 0, onScreen: true)
    static let crop = CGRect(x: 56, y: 28, width: 112, height: 56)

    static func meta(crop: CGRect?, offset: CGPoint = .zero) -> Meta {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Meta(offset: offset, size: window.frame.size, width: 280, height: 224, sig: Signature(ctx.makeImage()!), crop: crop)
    }

    @MainActor func withPicture(crop: CGRect?, _ body: (Target) throws -> Void) throws {
        let w = Self.window
        try Session.$current.withValue(Session(id: "t-crop-coordinates", ordinal: 1)) {
            Handlers.meta[w.id] = Self.meta(crop: crop)
            try body(.window(w))
        }
    }

    @MainActor func testCropPixelsLandWhereTheyShow() throws {
        try withPicture(crop: Self.crop) { t in
            XCTAssertEqual(try Handlers.toGlobal(t, 0, 0), CGPoint(x: 212, y: 106), "the crop's corner")
            XCTAssertEqual(try Handlers.toGlobal(t, 112, 56), CGPoint(x: 436, y: 218), "its far corner")
            XCTAssertEqual(try Handlers.toGlobal(t, 10, 4), CGPoint(x: 232, y: 114))
            XCTAssertEqual(try Handlers.toGlobal(t, 10, 10, ["units": "pt"]), CGPoint(x: 110, y: 60), "window points: no picture involved")
        }
    }

    /// Pixels off the crop may be from the whole picture before it: refused, saying how to aim instead.
    @MainActor func testPixelsOffTheCropAreRefused() throws {
        try withPicture(crop: Self.crop) { t in
            XCTAssertThrowsError(try Handlers.toGlobal(t, 113, 10)) { e in
                XCTAssertTrue("\(e)".contains("112x56"), "\(e)")
                XCTAssertTrue("\(e)".contains("only what changed"), "\(e)")
            }
            XCTAssertThrowsError(try Handlers.toGlobal(t, 20, 57), "below it")
            XCTAssertThrowsError(try Handlers.toGlobal(t, -1, 10))
            XCTAssertThrowsError(try Handlers.toGlobal(t, 200, 150), "a place in the whole picture")
        }
    }

    @MainActor func testPointsAreToldInTheCropsPixels() throws {
        try withPicture(crop: Self.crop) { t in
            XCTAssertEqual(Handlers.toPixels(t, CGPoint(x: 212, y: 106)), [0, 0])
            XCTAssertEqual(Handlers.toPixels(t, CGPoint(x: 436, y: 218)), [112, 56])
            XCTAssertNil(Handlers.toPixels(t, CGPoint(x: 150, y: 60)), "left of and above the crop")
            XCTAssertNil(Handlers.toPixels(t, CGPoint(x: 500, y: 300)), "right of and below it")
        }
    }

    /// A pixel of the crop to the screen and back is the same pixel.
    @MainActor func testRoundTrip() throws {
        try withPicture(crop: Self.crop) { t in
            for (x, y) in [(0, 0), (1, 1), (37, 19), (111, 55), (112, 56), (56, 28)] {
                let g = try Handlers.toGlobal(t, Double(x), Double(y))
                XCTAssertEqual(Handlers.toPixels(t, g), [x, y], "(\(x),\(y)) by way of \(g)")
            }
        }
    }

    /// A scroll given no place goes to the middle of what was captured, crop or not.
    @MainActor func testTheMiddleIsTheCaptures() throws {
        try withPicture(crop: Self.crop) { t in XCTAssertEqual(Handlers.captureCenter(t), CGPoint(x: 380, y: 274)) }
        try withPicture(crop: nil) { t in XCTAssertEqual(Handlers.captureCenter(t), CGPoint(x: 380, y: 274)) }
    }

    /// No crop: as it always was.
    @MainActor func testAWholePictureIsAsBefore() throws {
        try withPicture(crop: nil) { t in
            XCTAssertEqual(try Handlers.toGlobal(t, 10, 4), CGPoint(x: 120, y: 58))
            XCTAssertEqual(Handlers.toPixels(t, CGPoint(x: 150, y: 60)), [25, 5])
            XCTAssertThrowsError(try Handlers.toGlobal(t, 281, 10)) { e in XCTAssertTrue("\(e)".contains("280x224"), "\(e)") }
        }
    }

    /// The change's box (capture pixels) as the crop shows it: from its origin, cut to it.
    func testTheChangeBoxIsInTheCropsPixels() {
        let m = Self.meta(crop: Self.crop)
        XCTAssertEqual(m.pictureBox(CGRect(x: 60, y: 30, width: 20, height: 10)), CGRect(x: 4, y: 2, width: 20, height: 10))
        XCTAssertEqual(m.pictureBox(CGRect(x: 150, y: 70, width: 40, height: 40)), CGRect(x: 94, y: 42, width: 18, height: 14),
                       "cut to the crop")
        XCTAssertNil(m.pictureBox(CGRect(x: 0, y: 0, width: 20, height: 20)), "none of it in the crop")
        let whole = Self.meta(crop: nil)
        XCTAssertEqual(whole.pictureBox(CGRect(x: 0, y: 0, width: 20, height: 20)), CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    /// Where the crop is in the window (points, from its top-left corner), for the reply's `crop` [x0, y0, x1, y1].
    func testTheCropsPlaceInTheWindow() {
        XCTAssertEqual(Self.meta(crop: Self.crop).cropInWindow, CGRect(x: 112, y: 56, width: 224, height: 112))
        XCTAssertEqual(Self.meta(crop: Self.crop, offset: CGPoint(x: 0, y: 28)).cropInWindow,
                       CGRect(x: 112, y: 84, width: 224, height: 112), "a capture that starts below the window's top")
        XCTAssertNil(Self.meta(crop: nil).cropInWindow)
    }

    /// The options are off unless asked for: no crop and no low detail by default.
    @MainActor func testOffByDefault() {
        let plain = Handlers.Opts([:])
        XCTAssertFalse(plain.cropChanges)
        XCTAssertFalse(plain.lowDetail)
        XCTAssertTrue(Handlers.Opts(["crop_changes": true]).cropChanges)
        XCTAssertFalse(Handlers.Opts(["crop_changes": false]).cropChanges)
        XCTAssertFalse(Handlers.Opts(["crop_changes": "yes"]).cropChanges, "only true turns it on")
    }
}
