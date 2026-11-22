import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Which part of an act's capture to send when only part of the window changed (`ChangeCrop.decide`), and when
/// the whole window is sent however little changed (`ChangeCrop.keyframe`). Pixels of a 1440x900 pt window
/// captured at 1064x665 (912 tokens) unless said otherwise.
final class ChangeCropDecideTests: XCTestCase {
    static let picture = CGSize(width: 1064, height: 665), perPoint = 1064.0 / 1440

    func decide(_ box: CGRect, fraction: Double = 0.01, picture: CGSize = ChangeCropDecideTests.picture,
                perPoint: Double = ChangeCropDecideTests.perPoint, tile: Int = 28, outline: Int = 0) -> CGRect? {
        ChangeCrop.decide(changeBox: box, fraction: fraction, picture: picture, perPoint: perPoint, tile: tile, outline: outline)
    }

    func tokens(_ r: CGRect, tile: Double = 28) -> Double { ceil(Double(r.width) / tile) * ceil(Double(r.height) / tile) }

    /// Text typed into a field near the top left: a few tiles round it, kept in the picture, instead of 912 tokens.
    func testATypedFieldIsCroppedToAFewTiles() throws {
        let crop = try XCTUnwrap(decide(CGRect(x: 11, y: 33, width: 29, height: 12)))
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 112, height: 112))
        XCTAssertEqual(tokens(crop), 16)
    }

    /// The outline sent with a crop counts against what it saves. Calculator (157x280, 60 tokens): its display's
    /// digits fit a 16-token crop, but with its 426-character outline (about 122 tokens) the reply would cost more
    /// than the whole window's: the whole it is. The probe (574x420, 315 tokens): a field's edit with its outline of a
    /// few elements is still cropped.
    func testTheOutlineSentWithACropCounts() throws {
        let calculator = CGSize(width: 157, height: 280), calcScale = 157.0 / 230
        let digits = CGRect(x: 50, y: 65, width: 30, height: 20)
        XCTAssertNotNil(decide(digits, picture: calculator, perPoint: calcScale), "the picture alone would be cropped")
        XCTAssertNil(decide(digits, picture: calculator, perPoint: calcScale, outline: 426))
        XCTAssertNil(decide(digits, picture: calculator, perPoint: calcScale, outline: 60), "even a short outline tips it")
        let probe = CGSize(width: 574, height: 420), probeScale = 574.0 / 804
        let field = CGRect(x: 35, y: 33, width: 27, height: 12)
        let crop = try XCTUnwrap(decide(field, picture: probe, perPoint: probeScale, outline: 300))
        XCTAssertEqual(tokens(crop), 16)
        XCTAssertNil(decide(field, picture: probe, perPoint: probeScale, outline: 1500), "an outline at its cap (about 429 tokens)")
    }

    /// Room all round, each side grown to whole tiles (which costs nothing), the change in the middle.
    func testRoomRoundTheChangeOnWholeTiles() throws {
        let box = CGRect(x: 500, y: 300, width: 60, height: 20)
        let crop = try XCTUnwrap(decide(box))
        XCTAssertEqual(crop, CGRect(x: 460, y: 254, width: 140, height: 112))
        XCTAssertTrue(crop.contains(box))
        XCTAssertGreaterThanOrEqual(box.minX - crop.minX, 28, "a tile of room at least")
        XCTAssertGreaterThanOrEqual(crop.maxY - box.maxY, 28)
    }

    /// By an edge: the crop slides inward to keep its whole tiles inside the picture.
    func testByTheEdgeItStaysInThePicture() throws {
        let box = CGRect(x: 1040, y: 640, width: 20, height: 20)
        let crop = try XCTUnwrap(decide(box))
        XCTAssertEqual(crop, CGRect(x: 952, y: 553, width: 112, height: 112))
        XCTAssertTrue(crop.contains(box))
    }

    /// A change over a quarter of the window, or two changes far apart (one wide box round both), or a capture of
    /// another size (all of it changed): the whole picture.
    func testABigChangeIsSentWhole() {
        XCTAssertNil(decide(CGRect(x: 100, y: 100, width: 600, height: 400)), "over a quarter of the picture")
        XCTAssertNil(decide(CGRect(x: 11, y: 33, width: 990, height: 570)), "a field and a label far apart")
        XCTAssertNil(decide(CGRect(x: 0, y: 0, width: 1064, height: 665), fraction: 1), "a capture of another size")
        XCTAssertNil(decide(CGRect(x: 500, y: 300, width: 20, height: 20), fraction: 1))
        XCTAssertNil(decide(.zero), "nothing in it")
    }

    /// A checkbox and the status label it updates (one box round both, on the probe's 574x400 picture, 315
    /// tokens): cropped all the same, for half the tokens or less.
    func testAControlAndItsLabelAreCroppedTogether() throws {
        let picture = CGSize(width: 574, height: 400), perPoint = 574.0 / 804
        let box = CGRect(x: 45, y: 33, width: 378, height: 63)
        let crop = try XCTUnwrap(decide(box, picture: picture, perPoint: perPoint))
        XCTAssertTrue(crop.contains(box))
        XCTAssertLessThanOrEqual(tokens(crop), 0.5 * ceil(574 / 28) * ceil(400 / 28))
    }

    /// A small window gains too little from a crop (a few tiles of its few): the whole picture.
    func testASmallWindowIsSentWhole() {
        XCTAssertNil(decide(CGRect(x: 60, y: 40, width: 10, height: 10), picture: CGSize(width: 168, height: 112)))
    }

    /// Another tile size (OpenAI's 32 px): whole tiles of it.
    func testAnotherTileSize() throws {
        let crop = try XCTUnwrap(decide(CGRect(x: 500, y: 300, width: 10, height: 10), picture: CGSize(width: 1024, height: 640),
                                        perPoint: 0.75, tile: 32))
        XCTAssertEqual(crop.width.truncatingRemainder(dividingBy: 32), 0)
        XCTAssertEqual(crop.height.truncatingRemainder(dividingBy: 32), 0)
        XCTAssertEqual(crop.width, 128, "four tiles at least")
    }

    /// Wherever the change is and however big, a crop holds all of it, lies in the picture, is whole tiles (or the
    /// picture's whole side) at least four a side, and saves half the tokens.
    func testACropAlwaysHoldsTheWholeChange() {
        let W = 1064.0, H = 665.0
        var crops = 0
        for x in stride(from: 0.0, to: W, by: 37) {
            for y in stride(from: 0.0, to: H, by: 41) {
                for (w, h) in [(4.0, 16.0), (29.0, 12.0), (150.0, 60.0), (378.0, 63.0), (300.0, 200.0)] {
                    let box = CGRect(x: x, y: y, width: min(w, W - x), height: min(h, H - y))
                    guard let crop = decide(box) else { continue }
                    crops += 1
                    XCTAssertTrue(crop.contains(box), "\(box) in \(crop)")
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: W, height: H).contains(crop), "\(crop)")
                    for (side, whole) in [(Double(crop.width), W), (Double(crop.height), H)] {
                        XCTAssertTrue(side.truncatingRemainder(dividingBy: 28) == 0 || side == whole, "\(crop)")
                        XCTAssertGreaterThanOrEqual(side, 112)
                    }
                    XCTAssertLessThanOrEqual(tokens(crop), 0.5 * 24 * 38)
                }
            }
        }
        XCTAssertGreaterThan(crops, 1000, "most small changes are cropped")
    }

    /// What a crop shows in global points: its pixels at the capture's scale, from the capture's corner.
    func testACropsPlaceOnScreen() {
        let ctx = CGContext(data: nil, width: 720, height: 450, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let shot = Shot(image: ctx.makeImage()!, rect: CGRect(x: 100, y: 50, width: 1440, height: 900))
        XCTAssertEqual(ChangeCrop.points(CGRect(x: 56, y: 28, width: 112, height: 56), of: shot),
                       CGRect(x: 212, y: 106, width: 224, height: 112))
    }

    // MARK: - whole pictures

    func keyframe(seen: Bool = true, crops: Int = 0, newWindow: Bool = false, reshaped: Bool = false, failed: Bool = false,
                  stopped: Bool = false, irreversible: Bool = false, outlined: Bool = false, always: Bool = false) -> Bool {
        ChangeCrop.keyframe(seen: seen, crops: crops, newWindow: newWindow, reshaped: reshaped, failed: failed, stopped: stopped,
                            irreversible: irreversible, outlined: outlined, always: always)
    }

    /// A window the agent has seen, its batch run cleanly: a crop may be sent.
    func testACleanBatchMayBeCropped() {
        XCTAssertFalse(keyframe())
    }

    /// Every fifth picture of a window is whole: after four crops in a row, the next isn't one.
    func testEveryFifthPictureIsWhole() {
        XCTAssertEqual(ChangeCrop.keyframeEvery, 5)
        for n in 0..<4 { XCTAssertFalse(keyframe(crops: n), "\(n) crops in a row") }
        XCTAssertTrue(keyframe(crops: 4))
        XCTAssertTrue(keyframe(crops: 9))
    }

    /// The whole window: one the agent hasn't seen whole, a new window, one moved, resized or with something new
    /// over it, an error, any stop (coordinates, a macro's positions, the user's OK), a press the user agreed to,
    /// the outline's fallback to a picture, and a batch that always asks for a picture.
    func testWhatCallsForTheWholeWindow() {
        XCTAssertTrue(keyframe(seen: false), "first picture of the window")
        XCTAssertTrue(keyframe(newWindow: true))
        XCTAssertTrue(keyframe(reshaped: true), "moved, resized, or a sheet or pop-up came or went")
        XCTAssertTrue(keyframe(failed: true))
        XCTAssertTrue(keyframe(stopped: true))
        XCTAssertTrue(keyframe(irreversible: true))
        XCTAssertTrue(keyframe(outlined: true))
        XCTAssertTrue(keyframe(always: true))
    }
}
