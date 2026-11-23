import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Which of an app's windows a capture of one of its windows takes in (`Capture.related`): its sheets, and
/// the menus, popovers and panels over it, a menu's cascade of submenus whole; not its menu-bar items, its
/// tooltips, its other windows that merely sit nearby or lie over it, or windows too small or faint to see.
/// Made-up windows (no app needed), with what accessibility says of those on the window's layer.
final class CaptureRelatedTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    func win(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0, pid: pid_t = 7, alpha: Double = 1, on: Bool = true) -> WinInfo {
        WinInfo(id: id, pid: pid, app: "App", title: "", frame: frame, layer: layer, onScreen: on, alpha: alpha)
    }

    func taken(_ target: WinInfo, _ others: [WinInfo], kin: [CGWindowID: Capture.Kin] = [:]) -> Set<CGWindowID> {
        Set(Capture.related(to: target, among: others + [target], display: display, kin: kin).map(\.id))
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
        XCTAssertEqual(taken(w, [sheet, popover, panel, tooltip, nearby, otherApp, otherWindow, hidden, elsewhere],
                             kin: [2: .attached, 8: .another]),
                       [1, 2, 3, 4])
    }

    /// Another of the app's windows over the window, the same size at the same spot (a browser's other window, maybe
    /// the user's): never taken, or its picture would stand in for the window's. Not when accessibility calls it one
    /// of the app's own windows, nor when it says it's neither that nor a sheet (it starts at the window's top edge,
    /// where only a window of its own has its title bar), nor when accessibility couldn't be asked. Nor a smaller one
    /// lying inside the window, called one of the app's own windows.
    func testAnotherWindowOfTheAppOverItIsNeverTaken() {
        let w = win(1, frame)
        let twin = win(2, frame)
        XCTAssertEqual(taken(w, [twin], kin: [2: .another]), [1])
        XCTAssertEqual(taken(w, [twin], kin: [2: .other]), [1])
        XCTAssertEqual(taken(w, [twin]), [1])
        let small = win(3, CGRect(x: 200, y: 300, width: 500, height: 400))
        XCTAssertEqual(taken(w, [small], kin: [3: .another]), [1])
        XCTAssertEqual(Capture.kinAsked(to: w, among: [w, twin, small], display: display), [2, 3])
    }

    /// A sheet is taken when it hangs off the window, or when accessibility doesn't list it and it lies inside the
    /// window below its top edge (a child panel); not when it hangs off another of the app's windows (the same size
    /// over this one, say), nor when accessibility couldn't be asked. A pop-up menu over the window is taken
    /// whatever accessibility says: it's on a layer above windows.
    func testASheetIsTakenWhenItHangsOffTheWindowAndAPopUpMenuAlways() {
        let w = win(1, frame)
        let sheet = win(2, CGRect(x: 300, y: 228, width: 400, height: 300))
        XCTAssertEqual(taken(w, [sheet], kin: [2: .attached]), [1, 2])
        XCTAssertEqual(taken(w, [sheet], kin: [2: .other]), [1, 2])
        XCTAssertEqual(taken(w, [sheet], kin: [2: .another]), [1])
        XCTAssertEqual(taken(w, [sheet]), [1])
        let wide = win(3, CGRect(x: 50, y: 228, width: 900, height: 300))  // wider than the window, hanging off it
        XCTAssertEqual(taken(w, [wide], kin: [3: .attached]), [1, 3])
        XCTAssertEqual(taken(w, [wide], kin: [3: .other]), [1])
        let menu = win(4, CGRect(x: 400, y: 400, width: 220, height: 300), layer: 101)
        XCTAssertEqual(taken(w, [menu]), [1, 4])
        XCTAssertEqual(Capture.kinAsked(to: w, among: [w, menu], display: display), [])
    }

    /// What accessibility's role says of a window on the captured window's layer: a sheet, drawer or popover hangs off
    /// the window it names (this one, or another); a standard window is another of the app's; a dialog, or one with
    /// no role or no window named, is neither.
    func testWhatAccessibilitySaysAWindowIs() {
        XCTAssertEqual(Capture.kin(role: "AXSheet", subrole: nil, parent: 1, of: 1), .attached)
        XCTAssertEqual(Capture.kin(role: "AXDrawer", subrole: nil, parent: 1, of: 1), .attached)
        XCTAssertEqual(Capture.kin(role: "AXSheet", subrole: nil, parent: 2, of: 1), .another)
        XCTAssertEqual(Capture.kin(role: "AXPopover", subrole: nil, parent: nil, of: 1), .other)
        XCTAssertEqual(Capture.kin(role: "AXWindow", subrole: "AXStandardWindow", parent: nil, of: 1), .another)
        XCTAssertEqual(Capture.kin(role: "AXWindow", subrole: "AXDialog", parent: nil, of: 1), .other)
        XCTAssertEqual(Capture.kin(role: nil, subrole: nil, parent: nil, of: 1), .other)
    }

    /// Clicks in the window go to what's over it (`Windows.popups`): a menu, a sheet inside it (also when accessibility
    /// couldn't say what it is), but not another of the app's own windows inside it or the same size over it, maybe
    /// the user's: the click is stamped for the window, and goes to it.
    func testClicksDontGoToAnotherWindowOfTheAppOverIt() {
        let w = win(1, frame)
        let twin = win(2, frame), sheet = win(3, CGRect(x: 300, y: 228, width: 400, height: 300))
        let menu = win(4, CGRect(x: 850, y: 300, width: 200, height: 300), layer: 101)
        let unknown = win(5, CGRect(x: 320, y: 240, width: 300, height: 200))
        let over = Windows.popups([menu, twin, sheet, unknown], over: w, kin: [2: .another, 3: .attached])
        XCTAssertEqual(over.map(\.id), [4, 3, 5])
    }

    /// Accessibility is asked only about the app's windows on the window's layer that overlap it and can be seen: not
    /// menus, windows elsewhere on screen, other apps' windows or tiny ones.
    func testAccessibilityIsAskedOnlyAboutWindowsOnItsLayerOverIt() {
        let w = win(1, frame)
        let over = win(2, CGRect(x: 500, y: 500, width: 800, height: 500))
        let apart = win(3, CGRect(x: 1000, y: 100, width: 300, height: 300))
        let menu = win(4, CGRect(x: 400, y: 400, width: 200, height: 200), layer: 101)
        let otherApp = win(5, frame, pid: 8)
        let tiny = win(6, CGRect(x: 300, y: 300, width: 10, height: 10))
        XCTAssertEqual(Capture.kinAsked(to: w, among: [w, over, apart, menu, otherApp, tiny], display: display), [2])
    }
}
