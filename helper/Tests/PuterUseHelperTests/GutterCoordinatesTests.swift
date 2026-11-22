import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Coordinates read off an act's picture with blank margins left out of it (`Meta.trim`) land where they show:
/// the content's columns, then the scroll bar's; below a picture cut short at the bottom, the window as it was.
/// Points the agent is told (`toPixels`) are in the picture's pixels, and none for what was left out.
final class GutterCoordinatesTests: XCTestCase {
    /// A window at (100, 50), 560x448 pt, captured at 1 px a point: its left side, the blank left of its scroll
    /// bar and its bottom left out of the picture (308x196).
    static let window = WinInfo(id: 424_601, pid: 424_601, app: "Browser", title: "",
                                frame: CGRect(x: 100, y: 50, width: 560, height: 448), layer: 0, onScreen: true)
    static let trim = Trim(columns: [131..<429, 550..<560], height: 196, fullWidth: 560, fullHeight: 448)

    @MainActor func withPicture(trim: Trim?, _ body: (Target) throws -> Void) throws {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = Self.window
        try Session.$current.withValue(Session(id: "t-trim-coordinates", ordinal: 1)) {
            Handlers.meta[w.id] = Meta(offset: .zero, size: w.frame.size, width: 560, height: 448, sig: Signature(ctx.makeImage()!),
                                       trim: trim)
            try body(.window(w))
        }
    }

    @MainActor func testPicturePixelsLandWhereTheyShow() throws {
        try withPicture(trim: Self.trim) { t in
            XCTAssertEqual(try Handlers.toGlobal(t, 0, 10), CGPoint(x: 231, y: 60), "the first column kept")
            XCTAssertEqual(try Handlers.toGlobal(t, 297, 10), CGPoint(x: 528, y: 60), "the content's last")
            XCTAssertEqual(try Handlers.toGlobal(t, 300, 100), CGPoint(x: 652, y: 150), "on the scroll bar")
            XCTAssertEqual(try Handlers.toGlobal(t, 20, 400), CGPoint(x: 251, y: 450), "below the picture: the window carries on")
            XCTAssertThrowsError(try Handlers.toGlobal(t, 20, 449), "below the window")
            XCTAssertThrowsError(try Handlers.toGlobal(t, 309, 10), "right of the picture") { e in
                XCTAssertTrue("\(e)".contains("308x196"), "\(e)")
            }
            XCTAssertThrowsError(try Handlers.toGlobal(t, -1, 10))
            XCTAssertEqual(try Handlers.toGlobal(t, 10, 10, ["units": "pt"]), CGPoint(x: 110, y: 60), "window points: no picture involved")
        }
    }

    @MainActor func testPointsAreToldInThePicturesPixels() throws {
        try withPicture(trim: Self.trim) { t in
            XCTAssertEqual(Handlers.toPixels(t, CGPoint(x: 231, y: 60)), [0, 10])
            XCTAssertEqual(Handlers.toPixels(t, CGPoint(x: 652, y: 150)), [300, 100])
            XCTAssertNil(Handlers.toPixels(t, CGPoint(x: 150, y: 60)), "in the left side left out")
            XCTAssertNil(Handlers.toPixels(t, CGPoint(x: 600, y: 60)), "in the blank left of the scroll bar")
            XCTAssertNil(Handlers.toPixels(t, CGPoint(x: 231, y: 400)), "below the picture")
        }
    }

    /// A scroll given no place goes to the middle of what was captured, as before: not the picture's.
    @MainActor func testTheMiddleIsTheCaptures() throws {
        try withPicture(trim: Self.trim) { t in XCTAssertEqual(Handlers.captureCenter(t), CGPoint(x: 380, y: 274)) }
        try withPicture(trim: nil) { t in XCTAssertEqual(Handlers.captureCenter(t), CGPoint(x: 380, y: 274)) }
    }

    /// No margins left out: as it always was.
    @MainActor func testAnUntrimmedPictureIsAsBefore() throws {
        try withPicture(trim: nil) { t in
            XCTAssertEqual(try Handlers.toGlobal(t, 20, 400), CGPoint(x: 120, y: 450))
            XCTAssertThrowsError(try Handlers.toGlobal(t, 561, 10))
            XCTAssertEqual(Handlers.toPixels(t, CGPoint(x: 150, y: 60)), [50, 10])
        }
    }
}
