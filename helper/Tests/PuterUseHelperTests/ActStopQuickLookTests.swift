import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The one look an act takes when nothing ran (the first action failed, or the batch stopped for the
/// user's OK) on a window the agent has seen (`Handlers.quickLook`): a change only when the window looks
/// different from the agent's last image, so an unchanged window costs no image.
final class ActStopQuickLookTests: XCTestCase {
    /// A 200x150 frame of the window, with a dark dialog over its middle or not.
    static func frame(dialog: Bool) -> Shot {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        if dialog {
            ctx.setFillColor(gray: 0.2, alpha: 1)
            ctx.fill(CGRect(x: 50, y: 60, width: 100, height: 60))
        }
        return Shot(image: ctx.makeImage()!, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    /// What the agent last saw: the window with no dialog.
    static let seen = Signature(frame(dialog: false).image)

    /// The window as the agent saw it: no change, from one capture (no settling), and the text cursor isn't
    /// asked about.
    @MainActor func testAnUnchangedWindowIsNoChange() async throws {
        var captures = 0, asked = 0
        let look = try await Handlers.quickLook(before: Self.seen, capture: {
            captures += 1
            return Self.frame(dialog: false)
        }, blinked: { _, _ in
            asked += 1
            return false
        })
        XCTAssertNil(look.change)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(asked, 0)
    }

    /// A dialog came up since: a change, around it, with the frame it was seen in (to send).
    @MainActor func testADialogThatCameUpIsAChange() async throws {
        var captures = 0
        let look = try await Handlers.quickLook(before: Self.seen, capture: {
            captures += 1
            return Self.frame(dialog: true)
        }, blinked: { _, _ in false })
        let change = try XCTUnwrap(look.change)
        XCTAssertGreaterThan(change.fraction, 0)
        XCTAssertLessThan(change.fraction, 1)
        XCTAssertTrue(change.box.contains(CGPoint(x: 100, y: 75)))
        XCTAssertEqual(Signature(look.shot.image), Signature(Self.frame(dialog: true).image))
        XCTAssertEqual(captures, 1)
    }

    /// What differs is only the text cursor blinking: no change. The check is asked about the frame just taken.
    @MainActor func testOnlyTheCursorBlinkingIsNoChange() async throws {
        var told: Signature?
        let look = try await Handlers.quickLook(before: Self.seen, capture: { Self.frame(dialog: true) }, blinked: { sig, _ in
            told = sig
            return true
        })
        XCTAssertNil(look.change)
        XCTAssertEqual(told, Signature(Self.frame(dialog: true).image))
    }

    /// A capture that fails (the window went) is the caller's to handle: it's thrown.
    @MainActor func testAFailedCaptureIsThrown() async {
        struct Gone: Error {}
        do {
            _ = try await Handlers.quickLook(before: Self.seen, capture: { throw Gone() }, blinked: { _, _ in false })
            XCTFail("expected the capture's error")
        } catch {
            XCTAssertTrue(error is Gone)
        }
    }
}
