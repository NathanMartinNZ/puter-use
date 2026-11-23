import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// navigate's own window: how it's opened when keys for it wouldn't reach the app (another window has its keyboard;
/// `Handlers.newWindowBy`), whether the window that appears then is used (`menuWindow`, `freshWindow`), and, opened
/// by cmd+n or the menu, where it's moved so it covers as little of the user's windows as it can (`ownWindowSpot`,
/// `Run.leastCovering`), with what its note says (`movedOffNote`, `keyboardNote`).
final class NewWindowByMenuTests: XCTestCase {
    // MARK: - how it's opened

    /// Through the menu only while the keys wouldn't reach the window and the app is in the background; in the user's
    /// front app the keys go (and stop, saying why), as they do when they'd reach it and in foreground mode.
    func testTheMenuOnlyWhileKeysWouldMissAndTheAppIsInTheBackground() {
        XCTAssertEqual(Handlers.newWindowBy(foreground: false, keysReach: false, front: false), .menu)
        XCTAssertEqual(Handlers.newWindowBy(foreground: false, keysReach: false, front: true), .keys, "the user's front app")
        XCTAssertEqual(Handlers.newWindowBy(foreground: false, keysReach: true, front: false), .keys)
        XCTAssertEqual(Handlers.newWindowBy(foreground: false, keysReach: true, front: true), .keys)
        XCTAssertEqual(Handlers.newWindowBy(foreground: true, keysReach: false, front: false), .keys, "foreground mode")
    }

    // MARK: - whether it's used

    /// A fresh window is used; one that isn't (a page of the user's may have opened it) never is; and a fresh one the
    /// user came into the app over stays where it is.
    func testOnlyAFreshWindowIsUsedAndNotOnceTheUserIsInTheApp() {
        XCTAssertEqual(Handlers.menuWindow(fresh: true, front: false), .use)
        XCTAssertEqual(Handlers.menuWindow(fresh: true, front: true), .userCameIn)
        XCTAssertEqual(Handlers.menuWindow(fresh: false, front: false), .notFresh)
        XCTAssertEqual(Handlers.menuWindow(fresh: false, front: true), .notFresh)
    }

    /// Fresh: one tab (or a tab strip that can't be read) on a new-tab or blank page, by its address, else by an empty
    /// address bar. Not: more tabs, a real page, or nothing to go by.
    func testAFreshWindowIsOneTabOnANewTabPage() {
        XCTAssertTrue(Handlers.freshWindow(tabs: 1, url: "about:home", address: nil))
        XCTAssertTrue(Handlers.freshWindow(tabs: nil, url: "chrome://newtab/", address: nil))
        XCTAssertTrue(Handlers.freshWindow(tabs: 1, url: nil, address: ""))
        XCTAssertFalse(Handlers.freshWindow(tabs: 2, url: "about:newtab", address: ""), "a second tab")
        XCTAssertFalse(Handlers.freshWindow(tabs: 1, url: "https://accounts.example.com/login", address: nil), "a pop-up")
        XCTAssertFalse(Handlers.freshWindow(tabs: 1, url: nil, address: "accounts.example.com/login"))
        XCTAssertFalse(Handlers.freshWindow(tabs: 1, url: nil, address: nil), "nothing to go by")
    }

    /// Browsers' new-tab, start and blank pages, and an empty address; not pages that only look like them.
    func testNewTabAndBlankPages() {
        for s in ["about:blank", "about:home", "about:newtab", "About:NewTab ", "chrome://newtab/", "chrome://new-tab-page/",
                  "edge://newtab/", "brave://newtab", "vivaldi://startpage/", "favorites://", "topsites://", "", "  "] {
            XCTAssertTrue(Handlers.blankPage(s), s)
        }
        for s in ["https://example.com/newtab", "about:config", "chrome://settings/", "file:///Users/a/home", "home",
                  "example.com"] {
            XCTAssertFalse(Handlers.blankPage(s), s)
        }
    }

    // MARK: - where it goes

    let screen = CGRect(x: 0, y: 40, width: 1800, height: 1129)

    func covered(_ f: CGRect, _ avoid: [CGRect]) -> CGFloat {
        Run.unionArea(avoid.map { $0.intersection(f) }.filter { !$0.isNull && !$0.isEmpty })
    }

    /// Cascaded over the user's window, with room beside it: moved clear of it, wholly on its screen, to the nearest
    /// such spot.
    func testItMovesClearOfTheUsersWindowWhereThereIsRoom() {
        let theirs = CGRect(x: 4, y: 40, width: 800, height: 700)
        let to = Run.leastCovering(size: CGSize(width: 900, height: 700), from: CGPoint(x: 26, y: 62), screen: screen,
                                   avoid: [theirs])
        XCTAssertEqual(covered(to, [theirs]), 0)
        XCTAssertTrue(screen.contains(to), "\(to)")
        XCTAssertEqual(to.size, CGSize(width: 900, height: 700))
        XCTAssertEqual(to.origin, CGPoint(x: 804, y: 62), "beside it, as near as can be to where it was")
    }

    /// No spot clear of the user's window (theirs fills most of the screen): where it covers least, wholly on screen.
    /// A user's window of 1280x1016 at (4,40) on a 1800x1129 screen, the new one cascaded 22 pt off it, as Firefox does.
    func testWithNoFreeSpotItCoversAsLittleAsItCan() {
        let theirs = CGRect(x: 4, y: 40, width: 1280, height: 1016)
        let from = CGRect(x: 48, y: 84, width: 1280, height: 900)
        let to = Run.leastCovering(size: from.size, from: from.origin, screen: screen, avoid: [theirs])
        XCTAssertTrue(screen.contains(to), "\(to)")
        XCTAssertLessThan(covered(to, [theirs]), covered(from, [theirs]))
        XCTAssertEqual(to.minX, screen.maxX - 1280, "as far right as it goes")
        XCTAssertEqual(to.maxY, screen.maxY, "and down, below the user's window's bottom edge")
    }

    /// Two windows of the user's, overlapping each other: their area under it is counted once, and the spot clear of
    /// both is taken over one beside only the first.
    func testOverlappingWindowsOfTheUsersAreCountedOnce() {
        let a = CGRect(x: 0, y: 40, width: 900, height: 600), b = CGRect(x: 600, y: 40, width: 600, height: 600)
        XCTAssertEqual(Run.unionArea([a, b]), 1200 * 600)
        XCTAssertEqual(Run.unionArea([a, a]), 900 * 600)
        XCTAssertEqual(Run.unionArea([]), 0)
        let to = Run.leastCovering(size: CGSize(width: 1000, height: 480), from: CGPoint(x: 22, y: 62), screen: screen,
                                   avoid: [a, b])
        XCTAssertEqual(covered(to, [a, b]), 0)
        XCTAssertEqual(to.minY, 640, "below both")
    }

    /// Clear of the user's windows already: it stays where it is. Bigger than the screen: shrunk to it.
    func testItStaysWhenClearAndShrinksToTheScreen() {
        let theirs = CGRect(x: 1000, y: 40, width: 800, height: 600)
        let here = CGRect(x: 30, y: 100, width: 800, height: 600)
        XCTAssertEqual(Run.leastCovering(size: here.size, from: here.origin, screen: screen, avoid: [theirs]), here)
        let big = Run.leastCovering(size: CGSize(width: 2560, height: 1600), from: CGPoint(x: 0, y: 40), screen: screen, avoid: [])
        XCTAssertEqual(big, screen)
    }

    /// Opened by cmd+n or the menu over the user's window, as the app cascades it: moved off it, shrunk to the batch's
    /// box. Overlapping the user's window only at its full size, not once shrunk to the box where it opened: it stays
    /// (moveTo shrinks it there). Clear of theirs, or with none: it stays.
    func testANewWindowOverTheUsersMovesOffItOnlyThen() {
        let theirs = CGRect(x: 4, y: 40, width: 800, height: 700)
        let cascaded = CGRect(x: 26, y: 62, width: 1280, height: 900), box = CGSize(width: 900, height: 700)
        let to = Handlers.ownWindowSpot(frame: cascaded, size: box, screen: screen, theirs: [theirs])
        XCTAssertEqual(to, CGRect(x: 804, y: 62, width: 900, height: 700), "beside it, at the box's size")
        let small = CGRect(x: 4, y: 40, width: 400, height: 300)
        let unboxed = Handlers.ownWindowSpot(frame: cascaded, size: cascaded.size, screen: screen, theirs: [small])
        XCTAssertEqual(unboxed.map { covered($0, [small]) }, 0)
        XCTAssertEqual(unboxed?.size, cascaded.size, "with no box, at its own size")
        let below = CGRect(x: 0, y: 40, width: 1800, height: 300)  // a wide window of theirs at the top
        XCTAssertNil(Handlers.ownWindowSpot(frame: CGRect(x: 100, y: 340, width: 900, height: 700), size: box, screen: screen,
                                            theirs: [below]), "clear of it")
        XCTAssertNil(Handlers.ownWindowSpot(frame: CGRect(x: 820, y: 100, width: 1000, height: 700), size: CGSize(width: 900, height: 700),
                                            screen: screen, theirs: [CGRect(x: 1750, y: 40, width: 50, height: 300)]),
                     "it covers theirs only at its full size: shrunk where it opened, it doesn't")
        XCTAssertNil(Handlers.ownWindowSpot(frame: cascaded, size: box, screen: screen, theirs: []), "no window of theirs")
    }

    /// Where the user's window fills the screen, a new window can only cover less of it: moved there all the same.
    func testWithNoFreeSpotTheNewWindowCoversLess() {
        let theirs = CGRect(x: 4, y: 40, width: 1280, height: 1016)
        let cascaded = CGRect(x: 48, y: 84, width: 1280, height: 900)
        let to = Handlers.ownWindowSpot(frame: cascaded, size: cascaded.size, screen: screen, theirs: [theirs])
        XCTAssertNotNil(to)
        XCTAssertLessThan(covered(to!, [theirs]), covered(cascaded, [theirs]))
        XCTAssertEqual(Run.covered(cascaded, by: [theirs]), covered(cascaded, [theirs]))
    }

    /// The note says it moved off the user's windows, or onto as little of them as the screen has room for, or nothing
    /// when it covers no less; and that it has the app's keyboard: in front when the user next switches to the app, or
    /// where their keys go when the app is their front app.
    func testTheNewWindowsNote() {
        XCTAssertEqual(Handlers.movedOffNote(before: 300_000, after: 0), " and moved it off the user's windows")
        XCTAssertEqual(Handlers.movedOffNote(before: 300_000, after: 40_000),
                       " and moved it to where it covers least of the user's windows (the screen has no free spot its size)")
        XCTAssertEqual(Handlers.movedOffNote(before: 40_000, after: 40_000), "")
        XCTAssertEqual(Handlers.keyboardNote(front: false, app: "Firefox"),
                       "; it now has Firefox's keyboard, so it'll be in front when the user next switches to Firefox")
        XCTAssertEqual(Handlers.keyboardNote(front: true, app: "Firefox"),
                       "; it now has Firefox's keyboard, and Firefox is the user's front app")
    }

    /// The screen a window is on: the one most of it is on, else the first.
    func testTheScreenAWindowIsOn() {
        let builtIn = CGRect(x: 0, y: 40, width: 1800, height: 1129), above = CGRect(x: -785, y: -1410, width: 3440, height: 1410)
        XCTAssertEqual(AX.screen(of: CGRect(x: 48, y: 84, width: 1280, height: 1016), [above, builtIn]), builtIn)
        XCTAssertEqual(AX.screen(of: CGRect(x: 0, y: -900, width: 1280, height: 1016), [builtIn, above]), above)
        XCTAssertEqual(AX.screen(of: CGRect(x: 9000, y: 9000, width: 10, height: 10), [builtIn, above]), builtIn)
        XCTAssertNil(AX.screen(of: .zero, []))
    }
}
