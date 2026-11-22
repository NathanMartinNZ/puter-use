import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Which of an app's windows a capture of one of its windows takes in (`Capture.related`): its sheets, and
/// the menus, popovers and panels over it, a menu's cascade of submenus whole; not its menu-bar items, its
/// tooltips, its other windows that merely sit nearby, or windows too small or faint to see. Made-up
/// windows (no app needed).
final class CaptureRelatedTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    func win(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0, pid: pid_t = 7, alpha: Double = 1, on: Bool = true) -> WinInfo {
        WinInfo(id: id, pid: pid, app: "App", title: "", frame: frame, layer: layer, onScreen: on, alpha: alpha)
    }

    func taken(_ target: WinInfo, _ others: [WinInfo]) -> Set<CGWindowID> {
        Set(Capture.related(to: target, among: others + [target], display: display).map(\.id))
    }

    /// The app's status items in the menu bar are left out, far off or near (one 176 pt above the window
    /// used to be taken in, widening the picture to the top of the screen), and even over the window.
    func testMenuBarItemsAreLeftOut() {
        let w = win(1, frame)
        let far = win(2, CGRect(x: 1500, y: 0, width: 30, height: 24), layer: 25)
        let near = win(3, CGRect(x: 600, y: 0, width: 30, height: 24), layer: 25)
        XCTAssertEqual(taken(w, [far, near]), [1])
        let tall = win(4, CGRect(x: 0, y: 0, width: 1200, height: 900))  // reaching up under the menu bar
        XCTAssertEqual(taken(tall, [far, near]), [4])
    }

    /// A menu over the window's edge and the two submenus cascading off it beyond the window are all taken
    /// in, each reached through the one before (listed deepest first, so it takes more than one pass). A
    /// menu that touches none of them isn't.
    func testAMenuAndItsCascadingSubmenusAreTaken() {
        let w = win(1, frame)
        let menu = win(3, CGRect(x: 700, y: 500, width: 220, height: 300), layer: 101)  // over the right edge
        let sub = win(4, CGRect(x: 916, y: 520, width: 200, height: 250), layer: 101)  // past the window, on the menu
        let subsub = win(5, CGRect(x: 1116, y: 560, width: 200, height: 200), layer: 101)  // just touching the submenu
        XCTAssertEqual(taken(w, [subsub, sub, menu]), [1, 3, 4, 5])
        let apart = win(6, CGRect(x: 1400, y: 900, width: 200, height: 150), layer: 101)
        XCTAssertEqual(taken(w, [subsub, sub, menu, apart]), [1, 3, 4, 5])
    }

    /// A window too small (10x10, or a 4 pt strip) or too faint (alpha 0 or 0.01) is left out, and an
    /// invisible one covering the screen doesn't link a menu elsewhere to the window.
    func testWindowsTooSmallOrFaintToSeeAreLeftOut() {
        let w = win(1, frame)
        let tiny = win(2, CGRect(x: 300, y: 300, width: 10, height: 10), layer: 101)
        let clear = win(3, display, layer: 3, alpha: 0)
        let faintSheet = win(4, CGRect(x: 300, y: 222, width: 400, height: 300), alpha: 0.01)
        let strip = win(5, CGRect(x: 120, y: 260, width: 600, height: 4), layer: 3)
        XCTAssertEqual(taken(w, [tiny, clear, faintSheet, strip]), [1])
        let menu = win(6, CGRect(x: 1300, y: 300, width: 200, height: 200), layer: 101)
        XCTAssertEqual(taken(w, [clear, menu]), [1])
    }

    /// Taken: a sheet inside the window, a popover over its top edge, a panel over its right edge. Not: a
    /// tooltip over it, a panel 20 pt off it, another app's menu over it, another of the app's windows on
    /// the same layer overlapping it, a menu that isn't on screen, one on another display.
    func testSheetsPopoversAndPanelsOverTheWindowAreTaken() {
        let w = win(1, frame)
        let sheet = win(2, CGRect(x: 300, y: 222, width: 400, height: 300))
        let popover = win(3, CGRect(x: 150, y: 150, width: 300, height: 200), layer: 3)
        let panel = win(4, CGRect(x: 850, y: 300, width: 250, height: 400), layer: 8)
        let tooltip = win(5, CGRect(x: 400, y: 400, width: 120, height: 22), layer: 200)
        let nearby = win(6, CGRect(x: 100, y: 820, width: 300, height: 150), layer: 3)
        let otherApp = win(7, CGRect(x: 400, y: 400, width: 200, height: 200), layer: 101, pid: 8)
        let otherWindow = win(8, CGRect(x: 500, y: 500, width: 800, height: 500))
        let hidden = win(9, CGRect(x: 400, y: 400, width: 200, height: 200), layer: 101, on: false)
        let elsewhere = win(10, CGRect(x: 1800, y: 200, width: 300, height: 300), layer: 101)
        XCTAssertEqual(taken(w, [sheet, popover, panel, tooltip, nearby, otherApp, otherWindow, hidden, elsewhere]),
                       [1, 2, 3, 4])
    }
}
