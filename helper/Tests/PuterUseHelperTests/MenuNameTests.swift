import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// `menu {item: "Export as PDF…"}` with a name alone, on a made-up menu list: which command it runs, and
/// what the failure lists when it runs nothing.
final class MenuNameTests: XCTestCase {
    static let dummy = AXUIElementCreateSystemWide()

    /// "File > Share > Email Link · cmd+e" → an item; a trailing ">" marks one with a submenu.
    static func items(_ lines: [String]) -> [AX.MenuItem] {
        lines.map { line in
            let parts = line.components(separatedBy: " · ")
            var path = parts[0].components(separatedBy: " > ")
            let sub = path.last == ""
            if sub { path.removeLast() }
            return AX.MenuItem(path: path, shortcut: parts.count > 1 ? parts[1] : nil, element: dummy, hasSubmenu: sub)
        }
    }

    static func paths(_ name: String, _ lines: [String]) -> [String] {
        AX.commandsNamed(name, in: items(lines)).map { $0.path.joined(separator: " > ") }
    }

    let bar = [
        "File > New Window · cmd+n", "File > Export as PDF… · cmd+shift+e", "File > Share > ", "File > Share > Email Link",
        "File > Open Recent > ", "File > Open Recent > Toggle Thing", "File > Open Recent > Clear Menu",
        "View > Toggle Thing · cmd+option+t", "View > Toggle Sidebar",
    ]

    func testExactAfterNormalising() {
        XCTAssertEqual(Self.paths("Toggle Thing", bar), ["View > Toggle Thing"])
        XCTAssertEqual(Self.paths("  toggle   THING ", bar), ["View > Toggle Thing"])  // case and spacing
        XCTAssertEqual(Self.paths("Export as PDF...", bar), ["File > Export as PDF…"])  // "..." is "…"
        XCTAssertEqual(Self.paths("Export as PDF", bar), ["File > Export as PDF…"])     // a closing "…" is optional
        XCTAssertEqual(Self.paths("Export as PDF…", ["File > Export as PDF"]), ["File > Export as PDF"])
        // Exact only: no prefix or substring, and a submenu isn't a command.
        XCTAssertEqual(Self.paths("Toggle", bar), [])
        XCTAssertEqual(Self.paths("Export", bar), [])
        XCTAssertEqual(Self.paths("Thing", bar), [])
        XCTAssertEqual(Self.paths("Share", bar), [])
        XCTAssertEqual(AX.nameKey("Save As…"), "save as")
        XCTAssertEqual(AX.nameKey("…"), "")
    }

    func testEveryMatchIsReturnedSoOnlyAUniqueOneRuns() {
        let two = ["Edit > Copy · cmd+c", "Format > Copy", "Format > Copy Style · cmd+option+c"]
        XCTAssertEqual(Self.paths("copy", two), ["Edit > Copy", "Format > Copy"])
        let miss = AX.nameMiss("copy", in: Self.items(two))
        XCTAssertTrue(miss.hasPrefix("nothing was run: \"copy\" names 2 menu commands. Give the full path"), miss)
        XCTAssertTrue(miss.contains("\n  Edit > Copy · cmd+c\n  Format > Copy\n  Format > Copy Style · cmd+option+c"), miss)
    }

    func testTheUsersOwnMenusAreSkipped() {
        let browser = [
            "File > New Window · cmd+n", "File > Recently Closed > ", "File > Recently Closed > Old Tab",
            "Go > Recent Folders > ", "Go > Recent Folders > Desktop",
            "History > Show All History · cmd+y", "History > New Window", "History > Visited Page 5",
            "Bookmarks > Folder 1 > ", "Bookmarks > Folder 1 > Bookmark 1.1", "Favorites > Example",
            "Profiles > Work", "Window > Minimize · cmd+m", "Window > Some Page Title",
            "Tools > Bookmarks > ", "Tools > Bookmarks > Saved Search",
        ]
        // A page in History named like a command doesn't make it ambiguous, and never runs itself.
        XCTAssertEqual(Self.paths("New Window", browser), ["File > New Window"])
        for name in ["Visited Page 5", "Show All History", "Bookmark 1.1", "Example", "Work", "Minimize", "Some Page Title",
                     "Old Tab", "Desktop", "Saved Search"] {
            XCTAssertEqual(Self.paths(name, browser), [], name)
        }
        XCTAssertFalse(AX.ownItem(["File", "New Window"]))
        XCTAssertFalse(AX.ownItem(["View", "Recently Used"]))  // only a submenu's title counts, not the item's own
        XCTAssertTrue(AX.ownItem(["File", "Open Recent", "report.pdf"]))
        XCTAssertTrue(AX.ownItem(["window", "Minimize"]))

        let miss = AX.nameMiss("Visited Page 5", in: Self.items(browser))
        XCTAssertTrue(miss.hasPrefix("nothing was run: \"Visited Page 5\" is only in menus that list the user's own things"), miss)
        XCTAssertTrue(miss.hasSuffix(":\n  History > Visited Page 5 (full path only)"), miss)
        let near = AX.nameMiss("page", in: Self.items(browser))
        XCTAssertTrue(near.hasPrefix("nothing was run: no menu command is named exactly \"page\" (\"full path only\": in the user's own"), near)
        XCTAssertTrue(near.hasSuffix(":\n  History > Visited Page 5 (full path only)\n  Window > Some Page Title (full path only)"), near)
    }

    func testAMissListsWhatItCouldMeanByFullPath() {
        let miss = AX.nameMiss("Toggle", in: Self.items(bar))
        XCTAssertEqual(miss, """
            nothing was run: no menu command is named exactly "Toggle" ("full path only": in the user's own History, \
            Bookmarks, recent items or Window menu). Give the full path of the one you mean:
              View > Toggle Thing · cmd+option+t
              View > Toggle Sidebar
              File > Open Recent > Toggle Thing (full path only)
            """)
        XCTAssertTrue(AX.nameMiss("cmd+shift+e", in: Self.items(bar)).hasSuffix("\n  File > Export as PDF… · cmd+shift+e"))
        XCTAssertEqual(AX.nameMiss("Frobnicate", in: Self.items(bar)),
                       "nothing was run: no menu item matches \"Frobnicate\" (menus with a query searches every item: try another word)")
        // Capped, with how to see the rest.
        let many = AX.nameMiss("Page", in: Self.items((1...20).map { "Go > Page \($0)" }))
        XCTAssertEqual(many.split(separator: "\n").count, 1 + 12 + 1)
        XCTAssertTrue(many.hasSuffix("\n  Go > Page 12\n  … 8 more (menus \"Page\" lists them)"), many)
    }

    /// A macro saves a name-only menu step as the full path it ran; a path the agent gave stays as given.
    @MainActor func testAMacroSavesThePathANameRan() {
        // As the act loop does it: recorded before the action runs, `ran` once it has (`Run.ranMenu`).
        func saved(_ a: [String: Any], ran: String?) -> [String: Any] {
            Macros.ran(Macros.record(Handlers.external(a), .screen), menu: ran)
        }
        let byName = saved(["type": "menu", "item": "Toggle Thing", "confirm": true], ran: "View > Toggle Thing")
        XCTAssertEqual(byName["item"] as? String, "View > Toggle Thing")
        XCTAssertEqual(byName["type"] as? String, "menu")
        XCTAssertNil(byName["confirm"])
        XCTAssertEqual(saved(["type": "menu", "path": ["Toggle Thing"]], ran: "View > Toggle Thing") as NSDictionary,
                       ["type": "menu", "item": "View > Toggle Thing"] as NSDictionary)
        // Given by its path (the menu action leaves `ran` nil), or not a menu step: as given.
        XCTAssertEqual(saved(["type": "menu", "item": "View > Toggle"], ran: nil)["item"] as? String, "View > Toggle")
        XCTAssertEqual(saved(["type": "type", "text": "Toggle Thing"], ran: "View > Toggle Thing") as NSDictionary,
                       ["type": "type", "text": "Toggle Thing"] as NSDictionary)
    }

    /// A menu's `path` (["View", "Toggle Thing"]) is its item, saved as given; a drag's `path` is points,
    /// saved in window points.
    @MainActor func testAMenuPathArrayIsKeptAndADragPathIsConverted() {
        let w = WinInfo(id: 424_501, pid: 424_501, app: "Probe", title: "", frame: CGRect(x: 100, y: 50, width: 400, height: 300),
                        layer: 0, onScreen: true)
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        Session.$current.withValue(Session(id: "t-menu-path", ordinal: 1)) {
            // A 2x screenshot of the whole window: pixel (200, 100) is window point (100, 50).
            Handlers.meta[w.id] = Meta(offset: .zero, size: w.frame.size, width: 800, height: 600, sig: Signature(ctx.makeImage()!))
            let menu = Macros.ran(Macros.record(["type": "menu", "path": ["View", "Toggle Thing"]], .window(w)), menu: nil)
            XCTAssertEqual(menu as NSDictionary, ["type": "menu", "path": ["View", "Toggle Thing"]] as NSDictionary)
            XCTAssertEqual(AX.menuPath(menu["item"] ?? menu["path"] ?? menu["text"]), ["View", "Toggle Thing"])
            XCTAssertFalse(Macros.positional(menu))

            let drag = Macros.ran(Macros.record(["type": "drag", "path": [[200, 100], [400, 300]]], .window(w)), menu: nil)
            XCTAssertEqual((drag["path"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) }, [[100, 50], [200, 150]])
            XCTAssertEqual(drag["units"] as? String, "pt")
            XCTAssertTrue(Macros.positional(drag))
        }
        // Nor is a menu's path (or an open's file) aimed by coordinates: no stop for a missing or stale screenshot.
        XCTAssertFalse(Handlers.aimsByCoordinates(["type": "menu", "path": ["View", "Toggle Thing"]]))
        XCTAssertFalse(Handlers.aimsByCoordinates(["type": "open", "path": "/tmp/report.pdf"]))
        XCTAssertTrue(Handlers.aimsByCoordinates(["type": "drag", "path": [[200, 100], [400, 300]]]))
        XCTAssertFalse(Handlers.aimsByCoordinates(["type": "drag", "path": [[100, 50]], "units": "pt"]))
    }

    /// A walk cut short can't prove a name is unique: nothing runs.
    func testAWalkCutShortRunsNothing() {
        let miss = AX.nameMiss("Toggle Thing", in: Self.items(["View > Toggle Thing"]), whole: false)
        XCTAssertTrue(miss.hasPrefix("nothing was run: the menus are too long to check that \"Toggle Thing\" is the only one."), miss)
        XCTAssertTrue(AX.nameMiss("Nope", in: [], whole: false).contains("in the part of the menus read in time"))
    }
}
