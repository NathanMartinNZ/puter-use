import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// `find` keeps a picture of the window to give what it lists a place in pixels, but never shows it: an act
/// after it still aims from that picture, yet treats the window as one the agent hasn't seen
/// (`Handlers.startLook`), so a failed first action or an unchanged window still comes with an image. A reply
/// that never reached the agent takes back what it showed, as for everything kept per window (`Store`).
final class FindFirstLookTests: XCTestCase {
    static func picture(shown: Bool) -> Meta {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return Meta(offset: .zero, size: CGSize(width: 400, height: 300), width: 40, height: 30, sig: Signature(ctx.makeImage()!),
                    shown: shown)
    }

    /// No picture: a first look (one is taken, coordinates stop). find's picture: coordinates go by it, but the
    /// agent hasn't seen the window. A screenshot it was sent: seen. A batch begun with open: neither.
    func testWhatAnActStartsFrom() {
        XCTAssertTrue(Handlers.startLook(nil, opening: false) == (true, true))
        XCTAssertTrue(Handlers.startLook(Self.picture(shown: false), opening: false) == (false, true))
        XCTAssertTrue(Handlers.startLook(Self.picture(shown: true), opening: false) == (false, false))
        XCTAssertTrue(Handlers.startLook(nil, opening: true) == (false, false))
        XCTAssertTrue(Handlers.startLook(Self.picture(shown: false), opening: true) == (false, false))
    }

    /// After find alone, a first action that fails (or a stop for the user's OK before anything ran) shows the
    /// window, as on a first look; once the agent has been shown a screenshot, a quick look decides.
    func testAFailureAfterFindAloneShowsTheWindow() {
        func end(_ m: Meta?, stopped: Bool = false, confirm: Bool = false, failed: Bool = true) -> Handlers.Ending {
            Handlers.ending(wantShot: true, always: false, done: 0, stopped: stopped, confirm: confirm, failed: failed,
                            firstLook: Handlers.startLook(m, opening: false).unseen)
        }
        XCTAssertEqual(end(Self.picture(shown: false)), .firstLook)
        XCTAssertEqual(end(Self.picture(shown: false), stopped: true, confirm: true, failed: false), .firstLook)
        XCTAssertEqual(end(Self.picture(shown: true)), .check)
        XCTAssertEqual(end(nil), .firstLook)
    }

    /// Delivery bookkeeping: a screenshot whose reply never reached the agent is taken back, leaving find's
    /// picture, which still counts as unseen. One that arrived stands.
    func testAPictureNeverDeliveredDoesntCountAsSeen() {
        let store = Store<CGWindowID, Meta>()
        let lost = RequestKey(client: "c", id: 1), delivered = RequestKey(client: "c", id: 2)
        Connection.$current.withValue(Connection(fd: -1, key: nil)) { store[7] = Self.picture(shown: false) }  // find's (no tracking)
        Connection.$current.withValue(Connection(fd: -1, key: lost)) { store[7] = Self.picture(shown: true) }
        XCTAssertFalse(Handlers.startLook(store[7], opening: false).unseen)
        store.rollback(lost)
        XCTAssertEqual(store[7]?.shown, false)
        XCTAssertTrue(Handlers.startLook(store[7], opening: false).unseen)
        Connection.$current.withValue(Connection(fd: -1, key: delivered)) { store[7] = Self.picture(shown: true) }
        store.forget(delivered)
        store.rollback(delivered)  // nothing left to take back once it arrived
        XCTAssertEqual(store[7]?.shown, true)
    }
}
