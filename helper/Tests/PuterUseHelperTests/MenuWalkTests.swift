import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The menu walk on a made-up menu bar (no app needed): menu order, and the early stop the app card uses.
final class MenuWalkTests: XCTestCase {
    /// A bar item (its one child is its menu), a menu (children are its items) or an item (a child is its submenu).
    final class Fake {
        let title: String?  // nil: a separator
        let shortcut: String?
        let kids: [Fake]
        init(_ title: String?, _ shortcut: String? = nil, _ kids: [Fake] = []) {
            (self.title, self.shortcut, self.kids) = (title, shortcut, kids)
        }
    }

    static func item(_ t: String?, _ k: String? = nil, sub: [Fake]? = nil) -> Fake { Fake(t, k, sub.map { [Fake(nil, nil, $0)] } ?? []) }
    static func top(_ t: String, _ items: [Fake]) -> (Fake, String) { (Fake(t, nil, [Fake(nil, nil, items)]), t) }

    var reads: [String] = []

    /// Runs the walk; `enter` says which menus it opens; `stop` sees each listed item's path and ends the walk by
    /// returning true.
    func walk(_ bar: [(Fake, String)], more: () -> Bool = { true }, enter: ([String]) -> Bool = { _ in true },
              stop: ([String], AX.MenuItem) -> Bool = { _, _ in false }) -> [[String]] {
        var listed: [[String]] = []
        let dummy = AXUIElementCreateSystemWide()
        AX.walkMenus(bar, children: { $0.kids }, more: more, enter: enter,
                     read: { n in
                         self.reads.append(n.title ?? "-")
                         return n.title.map { ($0, n.shortcut, n.kids.first) }
                     },
                     visit: { path, shortcut, _, hasSubmenu in
                         listed.append(path)
                         return stop(path, AX.MenuItem(path: path, shortcut: shortcut, element: dummy, hasSubmenu: hasSubmenu))
                     })
        return listed
    }

    func testMenuOrderSeparatorsServicesAndDepth() {
        let bar = [
            Self.top("App", [Self.item("About"), Self.item("Services", sub: [Self.item("Hidden")]), Self.item(nil),
                             Self.item("Quit", "cmd+q")]),
            Self.top("File", [Self.item("Share", sub: [Self.item("Email"),
                                                       Self.item("More", sub: [Self.item("Deep", sub: [Self.item("Deeper")])])]),
                              Self.item("Open", "cmd+o")]),
        ]
        XCTAssertEqual(walk(bar), [["App", "About"], ["App", "Quit"], ["File", "Share"], ["File", "Share", "Email"],
                                   ["File", "Share", "More"], ["File", "Share", "More", "Deep"], ["File", "Open"]])
        XCTAssertFalse(reads.contains("Hidden"))  // Services isn't opened
        XCTAssertFalse(reads.contains("Deeper"))  // 3 levels below the bar at most
    }

    /// Nothing after the item the walk was stopped at is read: not the rest of its menu, not the next menus.
    func testStopEndsTheWalkAtThatItem() {
        let bar = [Self.top("File", [Self.item("New"), Self.item("Share", sub: [Self.item("Email"), Self.item("Message")]),
                                     Self.item("Open")]),
                   Self.top("History", (1...500).map { Self.item("Page \($0)") })]
        XCTAssertEqual(walk(bar, stop: { path, _ in path.last == "Email" }), [["File", "New"], ["File", "Share"], ["File", "Share", "Email"]])
        XCTAssertEqual(reads, ["New", "Share", "Email"])
    }

    /// `more` (the time and item budget) is asked before each item is read.
    func testBudgetEndsTheWalk() {
        var left = 4
        let bar = [Self.top("File", [Self.item("A"), Self.item(nil), Self.item("B", sub: [Self.item("C")])]),
                   Self.top("Edit", [Self.item("D"), Self.item("E")])]
        XCTAssertEqual(walk(bar, more: { left -= 1; return left >= 0 }), [["File", "A"], ["File", "B"], ["File", "B", "C"]])
        XCTAssertEqual(reads, ["A", "-", "B", "C"])
    }

    /// The card's walk leaves the menus of the user's own things (History, Bookmarks, Window, Open Recent) and Help
    /// unopened, skips the standard commands everyone knows, and stops at the 8th shortcut with what walking
    /// those menus to the end gave (its first 8).
    func testCardShortcutsSkipUserMenusAndStopAtEightWithTheSameResult() {
        let bar = [
            Self.top("Browser", [Self.item("About Browser"), Self.item("Settings…", "cmd+,"), Self.item("Hide Browser", "cmd+h"),
                                 Self.item("Hide Others", "cmd+option+h"), Self.item("Quit Browser", "cmd+q")]),
            Self.top("File", [Self.item("New Window", "cmd+n"), Self.item("New Tab", "cmd+t"),
                              Self.item("New Private Window", "cmd+shift+n"), Self.item("Open File…", "cmd+o"),
                              Self.item("Open Location…", "cmd+l"), Self.item("Close Window", "cmd+shift+w"),
                              Self.item("Close Tab", "cmd+w"),
                              Self.item("Open Recent", sub: (1...30).map { Self.item("Recent \($0)") } + [Self.item("Clear Menu")]),
                              Self.item("Share", sub: [Self.item("Email Link", "cmd+i")]), Self.item("Print…", "cmd+p")]),
            Self.top("Edit", [Self.item("Undo", "cmd+z"), Self.item("Redo", "cmd+shift+z"), Self.item(nil), Self.item("Cut", "cmd+x"),
                              Self.item("Copy", "cmd+c"), Self.item("Paste", "cmd+v"), Self.item("Select All", "cmd+a"),
                              Self.item("Find in Page…", "cmd+f"), Self.item("Find Again", "cmd+g")]),
            Self.top("View", [Self.item("Toolbars", sub: [Self.item("Bookmarks Toolbar", "cmd+shift+b")]),
                              Self.item("Reload Page", "cmd+r"), Self.item("Zoom In", "cmd+="), Self.item("Zoom Out", "cmd+-"),
                              Self.item("Actual Size", "cmd+0"), Self.item("Enter Full Screen", "cmd+ctrl+f"),
                              Self.item("Page Source", "cmd+u")]),
            Self.top("History", [Self.item("Show All History", "cmd+shift+h"), Self.item("Reopen Closed Tab", "cmd+shift+t")]
                                + (1...800).map { Self.item("Visited \($0)") }),
            Self.top("Bookmarks", [Self.item("Bookmark This Page", "cmd+d")]
                                  + (1...800).map { Self.item("Bookmark \($0)", sub: [Self.item("Open \($0)")]) }),
            Self.top("Tools", [Self.item("Downloads", "cmd+shift+j"), Self.item("Developer Tools", "cmd+option+i"),
                               Self.item("Extensions", "cmd+shift+x"), Self.item("Task Manager", "cmd+option+Escape")]),
            Self.top("Window", [Self.item("Minimize", "cmd+m"), Self.item("Show Next Tab", "cmd+option+Right")]),
            Self.top("Help", [Self.item("Browser Help", "cmd+?")]),
        ]
        // Every menu, for scale: the user's own make up nearly all of it.
        _ = walk(bar)
        let everything = reads.count
        // Before: the card's menus walked to the end, then the first 8.
        var before: [String] = []
        reads = []
        let all = walk(bar, enter: AppCards.opens, stop: { _, item in
            if let s = AppCards.shortcut(item), before.count < AppCards.maxShortcuts { before.append(s) }
            return false
        })
        // Now: the card's own rule, stopping at the 8th.
        var now: [String] = []
        reads = []
        let listed = walk(bar, enter: AppCards.opens, stop: { _, item in
            if let s = AppCards.shortcut(item) { now.append(s) }
            return now.count == AppCards.maxShortcuts
        })
        XCTAssertEqual(AppCards.maxShortcuts, 8)
        XCTAssertEqual(now, before)
        XCTAssertEqual(now, ["New Private Window cmd+shift+n", "Open Location… cmd+l", "Email Link cmd+i",
                             "Bookmarks Toolbar cmd+shift+b", "Page Source cmd+u", "Downloads cmd+shift+j",
                             "Developer Tools cmd+option+i", "Extensions cmd+shift+x"])
        XCTAssertEqual(listed, Array(all.prefix(listed.count)))  // same order, just shorter
        XCTAssertEqual(listed.last, ["Tools", "Extensions"])
        XCTAssertTrue(listed.contains(["File", "Open Recent"]))  // listed, but not opened
        XCTAssertFalse(reads.contains { r in
            ["Visited", "Bookmark ", "Recent ", "Show All History", "Reopen Closed Tab", "Clear Menu", "Minimize", "Browser Help",
             "Task Manager"].contains(where: r.hasPrefix)
        })
        XCTAssertLessThan(reads.count, 40)
        XCTAssertGreaterThan(everything, 2400)
    }
}
