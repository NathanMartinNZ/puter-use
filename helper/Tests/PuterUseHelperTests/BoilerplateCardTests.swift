import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The app card: quirks without the app's name (the reply names it), Slack's safety note kept although it's an
/// Electron app, the standard shortcuts everyone knows left out, and the menu walk kept out of the menus that
/// list the user's own things. No app needed.
final class BoilerplateCardTests: XCTestCase {
    static let dummy = AXUIElementCreateSystemWide()

    /// "File > Export as PDF…" with shortcut `keys` (nil: none) → a menu item.
    static func item(_ path: String, _ keys: String?, submenu: Bool = false) -> AX.MenuItem {
        AX.MenuItem(path: path.components(separatedBy: " > "), shortcut: keys, element: dummy, hasSubmenu: submenu)
    }

    func testQuirksLeaveOutTheAppsNameAndSlackKeepsItsSafetyNote() {
        XCTAssertEqual(AppCards.quirk(.firefox, id: "org.mozilla.firefox"),
                       "hover menus follow the real pointer, so click instead of hovering")
        XCTAssertEqual(AppCards.quirk(.chromium, id: "com.google.Chrome"),
                       "in the background, shortcuts only work if they're in its menus; browse in your own window (navigate)")
        XCTAssertEqual(AppCards.quirk(.electron, id: "com.tinyspeck.slackmacgap"),
                       "never send anything without the user's OK; Electron app: if it ignores background input, use foreground=true")
        XCTAssertEqual(AppCards.quirk(.electron, id: "com.example.chat"),
                       "Electron app: if it ignores background input, use foreground=true")
        XCTAssertEqual(AppCards.quirk(nil, id: "com.apple.MobileSMS"), "never send anything without the user's OK")
        XCTAssertNil(AppCards.quirk(nil, id: "com.example.app"))
    }

    /// The card's walk opens the app's menus, not History, Bookmarks, Profiles, Window, recent items or Help.
    func testCardWalkOpensTheAppsMenusOnly() {
        for top in ["File", "Edit", "View", "Tools", "Develop"] { XCTAssertTrue(AppCards.opens([top]), top) }
        for top in ["History", "Bookmarks", "Favorites", "Profiles", "People", "Window", "Help"] {
            XCTAssertFalse(AppCards.opens([top]), top)
        }
        XCTAssertTrue(AppCards.opens(["File", "Share"]))
        XCTAssertTrue(AppCards.opens(["View", "Toolbars"]))
        XCTAssertFalse(AppCards.opens(["File", "Open Recent"]))
        XCTAssertFalse(AppCards.opens(["File", "Recent Folders"]))
        XCTAssertFalse(AppCards.opens(["Go", "Recently Closed"]))
        XCTAssertFalse(AppCards.opens(["View", "Bookmarks"]))
    }

    /// The standard File, Edit, Format and View commands are left out by their names, not their keys: an app's
    /// own command on the same key stays.
    func testStandardCommandsAreLeftOutByName() {
        let standard = [
            ("App > Settings…", "cmd+,"), ("File > New Window", "cmd+n"), ("File > New Message", "cmd+n"),
            ("File > Open...", "cmd+o"), ("File > Save", "cmd+s"), ("File > Print...", "cmd+p"), ("Edit > Find…", "cmd+f"),
            ("Edit > Find Next", "cmd+g"), ("Format > Bold", "cmd+b"), ("View > Reload Page", "cmd+r"),
            ("View > Zoom In", "cmd+="), ("Window > Show Next Tab", "cmd+option+Right"), ("Help > Search", "cmd+?"),
        ]
        for (path, keys) in standard { XCTAssertNil(AppCards.shortcut(Self.item(path, keys)), path) }
        XCTAssertNil(AppCards.shortcut(Self.item("File > Share", "cmd+i", submenu: true)))
        XCTAssertNil(AppCards.shortcut(Self.item("File > Export as PDF…", nil)))
        XCTAssertEqual(AppCards.shortcut(Self.item("Product > Build", "cmd+b")), "Build cmd+b")
        XCTAssertEqual(AppCards.shortcut(Self.item("File > New Private Window", "cmd+shift+n")), "New Private Window cmd+shift+n")
        XCTAssertEqual(AppCards.shortcut(Self.item("Go > Quick Switcher", "cmd+k")), "Quick Switcher cmd+k")
        XCTAssertEqual(AppCards.shortcut(Self.item("File > Export as PDF…", "cmd+shift+e")), "Export as PDF… cmd+shift+e")
    }
}
