import XCTest

@testable import PuterUseHelper

/// A batch begun with open needs no window: it works in the window open brings up (`Handlers.opensFirst`),
/// and the app open starts or uses is checked against the policy, by its bundle id, before it's started
/// (`Handlers.launchLevel`, `Handlers.levelToLaunch`).
final class ActOpenFirstTests: XCTestCase {
    static let open: [String: Any] = ["type": "open", "path": "/tmp/report.pdf"]

    /// No window (absent or null), and open (by any of its names) first: nothing is looked up before it.
    func testOpenFirstWithNoWindowNeedsNone() {
        XCTAssertTrue(Handlers.opensFirst(["actions": [Self.open]]))
        XCTAssertTrue(Handlers.opensFirst(["window": NSNull(), "actions": [Self.open, ["type": "key", "keys": "cmd+f"]]]))
        XCTAssertTrue(Handlers.opensFirst(["actions": [["type": "open_url", "url": "https://example.com"]]]))
        XCTAssertTrue(Handlers.opensFirst(["actions": [["action": "launch", "app": "Calculator"]]]))
    }

    /// A window given is the target as ever (the screen too), and so is the session's window for a batch
    /// that doesn't begin with open. A macro step belongs to an app, so a batch with one is looked up as
    /// before as well. Nor an empty batch.
    func testOtherwiseTheWindowIsLookedUpAsEver() {
        XCTAssertFalse(Handlers.opensFirst(["window": "Preview", "actions": [Self.open]]))
        XCTAssertFalse(Handlers.opensFirst(["window": "screen", "actions": [Self.open]]))
        XCTAssertFalse(Handlers.opensFirst(["window": 4242, "actions": [Self.open]]))
        XCTAssertFalse(Handlers.opensFirst(["actions": [["type": "click", "target": "OK"], Self.open]]))
        XCTAssertFalse(Handlers.opensFirst(["actions": [Self.open, ["type": "macro", "name": "export"]]]))
        XCTAssertFalse(Handlers.opensFirst(["actions": [[String: Any]]()]))
        XCTAssertFalse(Handlers.opensFirst([:]))
    }

    /// Before an app runs, its level comes from its bundle id first (in any case), as a running app's does;
    /// else from the strictest of the names it may go by; else full.
    func testTheLevelOfAnAppNotRunningYet() {
        let apps: [String: Policy.Level] = ["com.example.notes": .view, "notes": .full, "slack": .deny, "slack beta": .click]
        XCTAssertEqual(Handlers.launchLevel(apps, bundleID: "com.example.Notes", names: ["Notes"]), .view, "the bundle id wins")
        XCTAssertEqual(Handlers.launchLevel(apps, bundleID: "com.tinyspeck.slackmacgap", names: ["Slack"]), .deny, "by name")
        XCTAssertEqual(Handlers.launchLevel(apps, bundleID: nil, names: ["Slack Beta", "Slack"]), .deny, "the strictest name")
        XCTAssertEqual(Handlers.launchLevel(apps, bundleID: "com.apple.calculator", names: ["Calculator"]), .full)
        XCTAssertEqual(Handlers.launchLevel(apps, bundleID: nil, names: []), .full)
        XCTAssertEqual(Handlers.launchLevel(Policy.defaultApps, bundleID: "com.1password.1password", names: ["1Password 7"]), .deny)
        XCTAssertEqual(Handlers.launchLevel(Policy.defaultApps, bundleID: "com.apple.Terminal", names: ["Terminal"]), .click)
    }

    /// Open only hands an app something, so a click's level will do (a terminal can be started, a view-only
    /// app isn't opened in); navigate types an address into the browser, so it needs full.
    func testTheLevelAnActionNeedsToStartAnApp() {
        XCTAssertEqual(Handlers.levelToLaunch(Self.open), .click)
        XCTAssertEqual(Handlers.levelToLaunch(["type": "launch", "app": "Calculator"]), .click)
        XCTAssertEqual(Handlers.levelToLaunch(["type": "navigate", "url": "https://example.com"]), .full)
        XCTAssertEqual(Handlers.levelToLaunch(["type": "goto", "url": "https://example.com"]), .full)
        XCTAssertTrue(Policy.Level.view < Handlers.levelToLaunch(Self.open))
        XCTAssertFalse(Policy.Level.click < Handlers.levelToLaunch(Self.open))
        XCTAssertTrue(Policy.Level.click < Handlers.levelToLaunch(["type": "navigate", "url": "https://example.com"]))
    }
}
