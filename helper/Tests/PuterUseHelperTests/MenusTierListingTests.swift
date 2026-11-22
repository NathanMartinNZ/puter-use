import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The `menus` listing on a made-up menu bar (no app needed): each menu's own items in full, a submenu as its
/// number of items with those that have a shortcut, the menus of the user's own things cut down to their
/// shortcuts (walked after the app's own), and a query that still searches every level.
final class MenusTierListingTests: XCTestCase {
    typealias Fake = MenuWalkTests.Fake

    static func item(_ t: String?, _ k: String? = nil, sub: [Fake]? = nil) -> Fake { MenuWalkTests.item(t, k, sub: sub) }
    static func top(_ t: String, _ items: [Fake]) -> (Fake, String) { MenuWalkTests.top(t, items) }

    /// The items one walk of `bar` lists, at most `limit`, as `menuItems` gives them.
    static func items(_ bar: [(Fake, String)], limit: Int = 3000) -> [AX.MenuItem] {
        let dummy = AXUIElementCreateSystemWide()
        var out: [AX.MenuItem] = []
        AX.walkMenus(bar, children: { $0.kids }, more: { out.count < limit },
                     read: { n in n.title.map { ($0, n.shortcut, n.kids.first) } },
                     visit: { path, shortcut, _, sub in
                         out.append(AX.MenuItem(path: path, shortcut: shortcut, element: dummy, hasSubmenu: sub))
                         return false
                     })
        return out
    }

    /// The listing as `menus` makes it: the app's menus walked first, then the user's own (`listingWalk`).
    static func listing(_ bar: [(Fake, String)], query: String? = nil) -> String {
        AX.menuListing(AX.listingWalk(bar) { tops, limit in items(tops, limit: limit) }, query: query)
    }

    static var textEdit: [(Fake, String)] {
        let recent: [Fake] = (1...30).map { item("Document \($0).rtf") } + [item(nil), item("Clear Menu")]
        let find: [Fake] = [item("Find…", "cmd+f"), item("Find and Replace…"), item("Find Next", "cmd+g"),
                            item("Find Previous", "cmd+shift+g"), item("Use Selection for Find")]
        let spelling: [Fake] = [item("Show Spelling and Grammar", "cmd+:"), item("Check Document Now", "cmd+;"), item(nil),
                                item("Check Spelling While Typing"), item("Check Grammar With Spelling"),
                                item("Correct Spelling Automatically")]
        let substitutions: [Fake] = [item("Show Substitutions"), item(nil), item("Smart Copy/Paste"), item("Smart Quotes"),
                                     item("Smart Dashes"), item("Smart Links"), item("Data Detectors"), item("Text Replacement")]
        let font: [Fake] = [item("Show Fonts", "cmd+t"), item("Bold", "cmd+b"), item("Italic", "cmd+i"), item("Underline", "cmd+u"),
                            item("Outline"),
                            item("Kern", sub: [item("Use Default"), item("Use None"), item("Tighten"), item("Loosen")]),
                            item("Ligatures", sub: [item("Use Default"), item("Use None"), item("Use All")])]
        let direction: [Fake] = [item("Default"), item("Left to Right"), item("Right to Left", "cmd+option+r")]
        let text: [Fake] = [item("Align Left", "cmd+{"), item("Center", "cmd+|"), item("Justify"), item("Align Right", "cmd+}"),
                            item("Writing Direction", sub: direction), item("Show Ruler", "cmd+ctrl+r")]
        return [
            top("TextEdit", [item("About TextEdit"), item("Settings…", "cmd+,"), item("Services", sub: [item("Make Sticky")]),
                             item("Hide TextEdit", "cmd+h"), item("Quit TextEdit", "cmd+q")]),
            top("File", [item("New", "cmd+n"), item("Open…", "cmd+o"), item("Open Recent", sub: recent), item(nil),
                         item("Close", "cmd+w"), item("Save…", "cmd+s"), item("Export as PDF…"), item("Share", sub: [])]),
            top("Edit", [item("Undo", "cmd+z"), item("Redo", "cmd+shift+z"), item(nil), item("Cut", "cmd+x"), item("Copy", "cmd+c"),
                         item("Paste", "cmd+v"), item("Delete"), item("Select All", "cmd+a"), item(nil),
                         item("Find", sub: find), item("Spelling and Grammar", sub: spelling),
                         item("Substitutions", sub: substitutions),
                         item("Transformations", sub: [item("Make Upper Case"), item("Make Lower Case"), item("Capitalize")]),
                         item("Speech", sub: [item("Start Speaking"), item("Stop Speaking")])]),
            top("Format", [item("Font", sub: font), item("Text", sub: text), item("Make Plain Text", "cmd+shift+t")]),
            top("Window", [item("Minimize", "cmd+m"), item("Zoom"), item(nil), item("Bring All to Front"), item(nil),
                           item("Untitled"), item("Notes for the meeting.rtf")]),
            top("Help", [item("TextEdit Help", "cmd+?")]),
        ]
    }

    static let long = "Release notes for version 12: every change, fix and known issue, with links to the full discussion"

    static var browser: [(Fake, String)] {
        let closed: [Fake] = [item("Reopen Closed Tab", "cmd+shift+t")] + (1...5).map { item("Old Tab \($0)") }
        let history: [Fake] = [item("Show All History", "cmd+y"), item("Clear Recent History…"),
                               item("Recently Closed", sub: closed)] + (1...800).map { item("Visited \($0)") }
        let bookmarks: [Fake] = [item("Bookmark This Page", "cmd+d"), item("Show All Bookmarks", "cmd+option+b"),
                                 item("Favorites", sub: [item(long, "cmd+1"), item("Short", "cmd+2"), item("Untitled")])]
            + (1...50).map { item("Folder \($0)", sub: [item("Bookmark \($0)")]) }
        let moveAndResize: [Fake] = [item("Halves"), item("Left", "ctrl+fn+Left"), item("Right", "ctrl+fn+Right")]
        return [
            top("Browser", [item("About Browser"), item("Settings…", "cmd+,"), item("Quit Browser", "cmd+q")]),
            top("File", [item("New Window", "cmd+n"), item("Open Recent", sub: (1...12).map { item("Recent \($0)") }),
                         item("Close Window", "cmd+shift+w")]),
            top("History", history),
            top("Bookmarks", bookmarks),
            top("Profiles", [item("Work"), item("Personal")]),
            top("Window", [item("Minimize", "cmd+m"), item("Zoom"), item("Move & Resize", sub: moveAndResize),
                           item("Bring All to Front"), item(long), item("Inbox")]),
            top("Help", [item("Browser Help")]),
        ]
    }

    /// Each menu's own items in full; a submenu as its number of items, with those that have a shortcut at any depth
    /// (none of it repeating the submenu's name); a submenu whose items weren't read as "Name >".
    func testTopLevelInFullAndSubmenusCollapsedToTheirShortcuts() {
        XCTAssertEqual(Self.listing(Self.textEdit), """
            TextEdit: About TextEdit · Settings… cmd+, · Hide TextEdit cmd+h · Quit TextEdit cmd+q
            File: New cmd+n · Open… cmd+o · Open Recent > (31) · Close cmd+w · Save… cmd+s · Export as PDF… · Share >
            Edit: Undo cmd+z · Redo cmd+shift+z · Cut cmd+x · Copy cmd+c · Paste cmd+v · Delete · Select All cmd+a · \
            Find > (5: Find… cmd+f · Find Next cmd+g · Find Previous cmd+shift+g) · \
            Spelling and Grammar > (5: Show Spelling and Grammar cmd+: · Check Document Now cmd+;) · Substitutions > (7) · \
            Transformations > (3) · Speech > (2)
            Format: Font > (7: Show Fonts cmd+t · Bold cmd+b · Italic cmd+i · Underline cmd+u) · \
            Text > (6: Align Left cmd+{ · Center cmd+| · Align Right cmd+} · Writing Direction > (3: Right to Left cmd+option+r) · \
            Show Ruler cmd+ctrl+r) · Make Plain Text cmd+shift+t
            Window: Minimize cmd+m · … 4 more (search with a query)
            Help: TextEdit Help cmd+?
            """)
    }

    /// No shortcut of the app's is hidden: every item with one is listed with it, however deep. In the user's own
    /// menus, those in a submenu are left to a query, which finds them.
    func testEveryShortcutIsListed() {
        for bar in [Self.textEdit, Self.browser] {
            let text = Self.listing(bar)
            for i in Self.items(bar) where i.shortcut != nil && !i.hasSubmenu {
                let line = "\(AX.shownTitle(i.path)) \(i.shortcut!)"
                if AX.userMenu(i.path[0]), i.path.count > 2 {
                    XCTAssertFalse(text.contains(line), i.path.joined(separator: " > "))
                    XCTAssertTrue(Self.listing(bar, query: i.shortcut!).contains("\(AX.shownPath(i.path)) · \(i.shortcut!)"),
                                  i.path.joined(separator: " > "))
                } else {
                    XCTAssertTrue(text.contains(line), i.path.joined(separator: " > "))
                }
            }
        }
    }

    /// History, Bookmarks, Profiles and Window list only their items with a shortcut, and their submenus holding one
    /// as a count alone (Window's Move & Resize, in every app), then how many more. Open Recent is just a count.
    func testTheUsersOwnMenusAreCutToTheirShortcutsWithACount() {
        let clipped = String(Self.long.prefix(AX.ownTitleMax - 1)) + "…"
        XCTAssertEqual(Self.listing(Self.browser), """
            Browser: About Browser · Settings… cmd+, · Quit Browser cmd+q
            File: New Window cmd+n · Open Recent > (12) · Close Window cmd+shift+w
            History: Show All History cmd+y · Recently Closed > (6) · … 801 more (search with a query)
            Bookmarks: Bookmark This Page cmd+d · Show All Bookmarks cmd+option+b · Favorites > (3) · … 50 more (search with a query)
            Profiles: … 2 more (search with a query)
            Window: Minimize cmd+m · Move & Resize > (3) · … 4 more (search with a query)
            Help: Browser Help
            """)
        let text = Self.listing(Self.browser)
        for hidden in ["Visited", "Folder", "Bookmark 1", "Old Tab", "Recent 1", "Clear Recent History", "Work", "Inbox", "Zoom",
                       "Reopen Closed Tab", "Release notes", "Short", "ctrl+fn"] {
            XCTAssertFalse(text.contains(hidden), hidden)
        }
        XCTAssertLessThan(text.count, 600)
        // A clipped title still picks its item in a path.
        XCTAssertEqual(clipped.count, AX.ownTitleMax)
        XCTAssertEqual(AX.menuMatches(["Short", Self.long, "Untitled"], clipped), [1])
        // The app's own commands keep their whole title.
        XCTAssertEqual(AX.shownTitle(["File", Self.long]), Self.long)
    }

    /// A query searches all 3 levels and lists each hit with its full path, as before; only the titles of the user's
    /// own things are clipped.
    func testAQuerySearchesEveryLevelWithFullPaths() {
        XCTAssertEqual(Self.listing(Self.textEdit, query: "right to left"), "Format > Text > Writing Direction > Right to Left · cmd+option+r")
        XCTAssertEqual(Self.listing(Self.textEdit, query: "cmd+;"), "Edit > Spelling and Grammar > Check Document Now · cmd+;")
        // A submenu's name lists what's in it.
        XCTAssertEqual(Self.listing(Self.textEdit, query: "substitutions"), """
            Edit > Substitutions > Show Substitutions
            Edit > Substitutions > Smart Copy/Paste
            Edit > Substitutions > Smart Quotes
            Edit > Substitutions > Smart Dashes
            Edit > Substitutions > Smart Links
            Edit > Substitutions > Data Detectors
            Edit > Substitutions > Text Replacement
            """)
        XCTAssertEqual(Self.listing(Self.textEdit, query: "Document 7.rtf"), "File > Open Recent > Document 7.rtf")
        XCTAssertEqual(Self.listing(Self.textEdit, query: "zzz"), "(no menu item matches \"zzz\")")
        let clipped = String(Self.long.prefix(AX.ownTitleMax - 1)) + "…"
        XCTAssertEqual(Self.listing(Self.browser, query: "release notes"), """
            Bookmarks > Favorites > \(clipped) · cmd+1
            Window > \(clipped)
            """)
        XCTAssertEqual(Self.listing(Self.browser, query: "visited 80").components(separatedBy: "\n").first, "History > Visited 80")
    }

    /// The app's own menus are walked first, so a huge Bookmarks menu can't use up the 3,000 items before Tools and
    /// Help (one walk in menu order would); the listing keeps the menu bar's order.
    func testAppMenusAreWalkedFirstAndListedInMenuBarOrder() {
        let bar = [Self.top("File", [Self.item("New Window", "cmd+n")]),
                   Self.top("Bookmarks", [Self.item("Bookmark This Page", "cmd+d")] + (1...5000).map { Self.item("Bookmark \($0)") }),
                   Self.top("Tools", [Self.item("Downloads", "cmd+shift+j")]),
                   Self.top("Window", [Self.item("Minimize", "cmd+m")]),
                   Self.top("Help", [Self.item("Browser Help")])]
        XCTAssertFalse(Self.items(bar).contains { $0.path.first == "Tools" })
        var walked: [[String]] = []
        let items = AX.listingWalk(bar) { tops, limit in
            walked.append(tops.map(\.1))
            return Self.items(tops, limit: limit)
        }
        XCTAssertEqual(walked, [["File", "Tools", "Help"], ["Bookmarks", "Window"]])
        XCTAssertEqual(items.count, 3000)
        XCTAssertEqual(AX.menuListing(items, query: nil), """
            File: New Window cmd+n
            Bookmarks: Bookmark This Page cmd+d · … 2996 more (search with a query)
            Tools: Downloads cmd+shift+j
            Help: Browser Help
            """)
        // With room for all of it, every menu, in the menu bar's order.
        XCTAssertEqual(Self.listing(Array(bar.prefix(1)) + [Self.top("History", [Self.item("Visited 1")])] + Array(bar.suffix(3))), """
            File: New Window cmd+n
            History: … 1 more (search with a query)
            Tools: Downloads cmd+shift+j
            Window: Minimize cmd+m
            Help: Browser Help
            """)
    }

    /// The caps stay: 40 items per menu, then how many more; past 9,000 characters, the rest of the menus is left
    /// for a query.
    func testTheFortyItemAndNineThousandCharacterCapsStay() {
        let big = Self.top("Big", (1...50).map { Self.item("Item \($0)") })
        XCTAssertEqual(Self.listing([big]), "Big: " + (1...40).map { "Item \($0)" }.joined(separator: " · ") + " · … 10 more (search with a query)")
        let keys = Self.top("Go", [Self.item("Places", sub: (1...45).map { Self.item("Place \($0)", "cmd+\($0)") })])
        let line = Self.listing([keys])
        XCTAssertTrue(line.hasPrefix("Go: Places > (45: Place 1 cmd+1 · Place 2 cmd+2 · "), line)
        XCTAssertTrue(line.hasSuffix(" · Place 40 cmd+40 · …)"), line)
        let many = (1...40).map { m in Self.top("Menu \(m)", (1...35).map { Self.item("A command with a longish name \(m)-\($0)") }) }
        let lines = Self.listing(many).components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "… (more menus; pass a query to search them)")
        XCTAssertLessThanOrEqual(lines.dropLast().map(\.count).reduce(0, +), 9000)
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertLessThan(lines.count, 40)
    }

    /// Submenus with the same name each keep their own items.
    func testSameNamedSubmenusKeepTheirOwnItems() {
        let bar = [Self.top("View", [Self.item("Toolbars", sub: [Self.item("Tab Bar"), Self.item("Sidebar")]),
                                     Self.item("Toolbars", sub: [Self.item("Status Bar", "cmd+/")]), Self.item("Reload", "cmd+r")])]
        XCTAssertEqual(Self.listing(bar), "View: Toolbars > (2) · Toolbars > (1: Status Bar cmd+/) · Reload cmd+r")
    }
}
