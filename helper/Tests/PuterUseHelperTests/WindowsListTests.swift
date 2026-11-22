import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// What `windows` lists and how it tags each window: invisible windows left out, and which windows are the
/// agent's, the one it's on, the one in front and the one with its app's keyboard.
final class WindowsListTests: XCTestCase {
    static func win(_ id: CGWindowID, pid: pid_t, onScreen: Bool = true, alpha: Double = 1) -> WinInfo {
        WinInfo(id: id, pid: pid, app: "App\(pid)", title: "Window \(id)", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                layer: 0, onScreen: onScreen, alpha: alpha)
    }

    /// A window drawn fully transparent (an app's preloaded or helper window) isn't listed; a faint one is.
    func testInvisibleWindowsArentListed() {
        XCTAssertFalse(Handlers.listable(alpha: 0))
        XCTAssertFalse(Handlers.listable(alpha: 0.05))
        XCTAssertTrue(Handlers.listable(alpha: 0.06))
        XCTAssertTrue(Handlers.listable(alpha: 1))
    }

    /// The key window is asked of apps with more than one window listed, or with the agent's window or the one
    /// it's on; not of every app with one window.
    func testWhichAppsAreAskedForTheirKeyWindow() {
        let wins = [Self.win(1, pid: 10), Self.win(2, pid: 10), Self.win(3, pid: 20), Self.win(4, pid: 30), Self.win(5, pid: 40)]
        XCTAssertEqual(Handlers.keyboardApps(wins, agent: [], current: nil), [10])
        XCTAssertEqual(Handlers.keyboardApps(wins, agent: [3], current: 4), [10, 20, 30])
        XCTAssertEqual(Handlers.keyboardApps([], agent: [1], current: 1), [])
    }

    /// Each window's tags, in a fixed order; untagged windows have none.
    func testEachWindowsTags() {
        let wins = [Self.win(1, pid: 10), Self.win(2, pid: 10), Self.win(3, pid: 20), Self.win(4, pid: 20, onScreen: false)]
        let tags = Handlers.windowTags(wins, agent: [2], current: 2, front: 10, keys: [10: 1, 20: 3])
        XCTAssertEqual(tags[1], ["front", "keyboard"], "the user's window in front, with its app's keyboard")
        XCTAssertEqual(tags[2], ["yours", "current"])
        XCTAssertEqual(tags[3], ["keyboard"])
        XCTAssertNil(tags[4])
    }

    /// The front window is the front app's first on screen (the list runs front to back); a hidden one never is.
    func testTheFrontWindowIsTheFrontAppsFirstOnScreen() {
        let wins = [Self.win(1, pid: 10, onScreen: false), Self.win(2, pid: 20), Self.win(3, pid: 10), Self.win(4, pid: 10)]
        let tags = Handlers.windowTags(wins, agent: [], current: nil, front: 10, keys: [:])
        XCTAssertEqual(tags[3], ["front"])
        XCTAssertNil(tags[1])
        XCTAssertNil(tags[4])
        XCTAssertTrue(Handlers.windowTags(wins, agent: [], current: nil, front: nil, keys: [:]).isEmpty, "no app in front")
        XCTAssertTrue(Handlers.windowTags(wins, agent: [], current: nil, front: 99, keys: [:]).isEmpty, "one not listed")
    }

    /// The keyboard tag goes to the window the app names, only if it's listed (a panel of its isn't).
    func testTheKeyboardTagFollowsTheAppsKeyWindow() {
        let wins = [Self.win(1, pid: 10), Self.win(2, pid: 10)]
        XCTAssertEqual(Handlers.windowTags(wins, agent: [1], current: nil, front: nil, keys: [10: 2])[2], ["keyboard"])
        XCTAssertEqual(Handlers.windowTags(wins, agent: [1], current: nil, front: nil, keys: [10: 77])[1], ["yours"])
        XCTAssertNil(Handlers.windowTags(wins, agent: [1], current: nil, front: nil, keys: [10: 77])[2])
    }
}
