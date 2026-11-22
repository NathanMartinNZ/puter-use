import AppKit
import ApplicationServices

/// The app's menu bar through accessibility: every command and its keyboard shortcut, and pressing an
/// item by its path ("File > Export as PDF…"). Works on background apps and needs no screenshot or
/// pointer. The Apple menu (Restart, Shut Down, …) is left out on purpose.
extension AX {
    struct MenuItem {
        let path: [String]
        let shortcut: String?
        let element: AXUIElement
        var hasSubmenu = false
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] { value(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    /// Top-level menus (bar item, title), without the Apple menu.
    static func menuBar(pid: pid_t) -> [(AXUIElement, String)] {
        guard let bar = value(appElement(pid), kAXMenuBarAttribute) else { return [] }
        return children(bar as! AXUIElement).dropFirst().compactMap { item in  // [0] is the Apple menu
            guard let t = value(item, kAXTitleAttribute) as? String, !t.isEmpty else { return nil }
            return (item, t)
        }
    }

    /// Every item, in menu order, up to 3 levels deep (top menu > item > submenu item > …). `until` sees each
    /// item as it's listed and can end the walk there (true): the app card stops at its 8th shortcut.
    /// `tops`: just these top-level menus (default all). `limit`: the most items it lists. `enter`: whether to open
    /// the menu at a path (a top-level menu's, or an item's submenu); the app card leaves a browser's History and
    /// Bookmarks unread.
    static func menuItems(pid: pid_t, budget: TimeInterval = 3, tops: [(AXUIElement, String)]? = nil, limit: Int = 3000,
                          enter: ([String]) -> Bool = { _ in true }, until done: ((MenuItem) -> Bool)? = nil) -> [MenuItem] {
        let start = Date()
        let fields = [kAXTitleAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey",
                      "AXMenuItemCmdGlyph", kAXChildrenAttribute] as CFArray
        var out: [MenuItem] = []
        walkMenus(tops ?? menuBar(pid: pid), children: children,
                  more: { out.count < limit && Date().timeIntervalSince(start) < budget }, enter: enter,
                  read: { item in
                      var raw: CFArray?
                      guard AXUIElementCopyMultipleAttributeValues(item, fields, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                            let v = raw as? [AnyObject], v.count == 6, let title = v[0] as? String, !title.isEmpty
                      else { return nil }  // separators have no title
                      return (title, shortcutText(char: v[1] as? String, mods: (v[2] as? Int) ?? 0,
                                                  virtualKey: v[3] as? Int, glyph: v[4] as? Int),
                              (v[5] as? [AXUIElement])?.first)
                  },
                  visit: { path, shortcut, item, hasSubmenu in
                      out.append(MenuItem(path: path, shortcut: shortcut, element: item, hasSubmenu: hasSubmenu))
                      return done?(out[out.count - 1]) == true
                  })
        return out
    }

    /// The walk behind `menuItems`, apart from accessibility so tests can run it on a made-up menu bar:
    /// depth-first in menu order, up to 3 levels. `more` is asked before each item is read (the budget);
    /// `enter` before a top-level menu or a submenu is opened, with its path (an item with a submenu left
    /// closed is still listed); `read` gives its title, shortcut and submenu, or nil for a separator; `visit`
    /// gets each listed item and ends the whole walk by returning true.
    static func walkMenus<Node>(_ tops: [(Node, String)], children: (Node) -> [Node], more: () -> Bool,
                                enter: ([String]) -> Bool = { _ in true },
                                read: (Node) -> (title: String, shortcut: String?, submenu: Node?)?,
                                visit: (_ path: [String], _ shortcut: String?, _ item: Node, _ hasSubmenu: Bool) -> Bool) {
        var stopped = false
        func walk(_ menu: Node, _ path: [String], _ depth: Int) {
            for item in children(menu) {
                guard !stopped, more() else { return }
                guard let (title, shortcut, sub) = read(item) else { continue }
                // Services hand what's selected to other apps, and `menu` refuses them: not listed.
                if depth == 1, menuKey(title) == "services" { continue }
                if visit(path + [title], shortcut, item, sub != nil) { stopped = true; return }
                if let sub, depth < 3, enter(path + [title]) { walk(sub, path + [title], depth + 1) }
            }
        }
        for (top, title) in tops where !stopped && enter([title]) {
            if let menu = children(top).first { walk(menu, [title], 1) }
        }
    }

    static let keyNames: [Int: String] = [
        0x24: "Return", 0x30: "Tab", 0x31: "space", 0x33: "BackSpace", 0x75: "Delete", 0x35: "Escape",
        0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up", 0x73: "Home", 0x77: "End", 0x74: "PageUp",
        0x79: "PageDown", 0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// Menu glyph codes (Carbon's kMenu…Glyph) for keys without a character.
    static let glyphNames: [Int: String] = [
        0x02: "Tab", 0x04: "Return", 0x09: "space", 0x0A: "Delete", 0x0B: "Return", 0x17: "BackSpace",
        0x1B: "Escape", 0x62: "PageUp", 0x64: "Left", 0x65: "Right", 0x66: "Home", 0x68: "Up", 0x69: "End",
        0x6A: "Down", 0x6B: "PageDown", 0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6",
        0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
    ]

    /// "cmd+shift+e" from a menu item's key equivalent, in the form keypress accepts.
    static func shortcutText(char: String?, mods: Int, virtualKey: Int?, glyph: Int?) -> String? {
        var key: String?
        if let c = char, let u = c.unicodeScalars.first?.value {
            switch u {
            case 0x08, 0x7F: key = "BackSpace"
            case 0x03, 0x0D: key = "Return"
            case 0x09: key = "Tab"
            case 0x1B: key = "Escape"
            case 0x20: key = "space"
            case 0xF700: key = "Up"
            case 0xF701: key = "Down"
            case 0xF702: key = "Left"
            case 0xF703: key = "Right"
            case 0xF704...0xF70F: key = "F\(u - 0xF704 + 1)"
            case 0xF728: key = "Delete"
            case 0xF729: key = "Home"
            case 0xF72B: key = "End"
            case 0xF72C: key = "PageUp"
            case 0xF72D: key = "PageDown"
            case 0x00...0x1F, 0xF700...0xF8FF: key = nil
            default: key = c.lowercased()
            }
        }
        if key == nil, let g = glyph, g != 0 { key = glyphNames[g] }
        if key == nil, let vk = virtualKey, char?.isEmpty ?? true { key = keyNames[vk] }
        // Keys only a Mac keyboard's special row has (🎤 dictation, 🌐 globe) can't be typed by name.
        guard let key, key.count > 1 || key.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var parts: [String] = []
        if mods & 8 == 0 { parts.append("cmd") }  // AXMenuItemCmdModifiers: 8 = no cmd, 1 shift, 2 option, 4 ctrl, 16 fn
        if mods & 4 != 0 { parts.append("ctrl") }
        if mods & 2 != 0 { parts.append("option") }
        if mods & 1 != 0 { parts.append("shift") }
        if mods & 16 != 0 { parts.append("fn") }
        return (parts + [key]).joined(separator: "+")
    }

    /// The menu bar as text (`menuListing(_:query:)`), from a walk of every menu, 3 levels deep, in 3 s and 3,000
    /// items at most (`listingWalk`).
    static func menuListing(pid: pid_t, query: String?) -> String {
        let start = Date(), budget: TimeInterval = 3
        let items = listingWalk(menuBar(pid: pid)) { tops, limit in
            menuItems(pid: pid, budget: budget - Date().timeIntervalSince(start), tops: tops, limit: limit)
        }
        guard !items.isEmpty else { return "(no menu bar: the app has none, or exposes none to accessibility)" }
        return menuListing(items, query: query)
    }

    /// The listing's walk of the menu `bar`: the app's own menus first, then those of the user's own things (a
    /// browser's History and Bookmarks can hold thousands of items) with what's left of the `limit` (and of the
    /// time, which `walk` keeps), so they can't crowd out Tools or Help. The items come back in menu-bar order.
    static func listingWalk<Top>(_ bar: [(Top, String)], limit: Int = 3000,
                                 walk: (_ tops: [(Top, String)], _ limit: Int) -> [MenuItem]) -> [MenuItem] {
        let commands = walk(bar.filter { !userMenu($0.1) }, limit)
        let own = commands.count < limit ? walk(bar.filter { userMenu($0.1) }, limit - commands.count) : []
        var seen = Set<String>()
        return bar.filter { seen.insert($0.1).inserted }.flatMap { top in
            (userMenu(top.1) ? own : commands).filter { $0.path.first == top.1 }
        }
    }

    /// A walk's items (`menuItems`) as text. Without a query: one line per menu with its items, each submenu as
    /// its number of items and those with a shortcut, at any depth, e.g.
    /// `Edit: Undo cmd+z · Find > (5: Find… cmd+f · Find Next cmd+g) · Speech > (2)`. A menu of the user's own
    /// things (History, Bookmarks, Window) lists only its items with a shortcut and its submenus holding one (as
    /// their count: `Move & Resize > (21)`), and how many more it has.
    /// With a query: the items at any depth whose path or shortcut matches, one per line with its full path
    /// (`File > Share > Email Link · cmd+i`). Every item is listed, disabled or not: a background app shows its
    /// menus' items disabled until they're opened. Titles of the user's own things are clipped (`shownTitle`).
    static func menuListing(_ items: [MenuItem], query: String?) -> String {
        if let q = query?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty {
            let hits = items.filter { i in
                !i.hasSubmenu && (i.path.joined(separator: " > ").lowercased().contains(q)
                    || i.shortcut.map { comboKey($0) == comboKey(q) } == true)
            }
            if hits.isEmpty { return "(no menu item matches \"\(q)\")" }
            return hits.prefix(40).map { i in shownPath(i.path) + (i.shortcut.map { " · \($0)" } ?? "") }.joined(separator: "\n")
                + (hits.count > 40 ? "\n… \(hits.count - 40) more; narrow the query" : "")
        }
        var lines: [String] = []
        var chars = 0
        for menu in menuTree(items) {
            let top = menu.path[0]
            // History's pages, bookmarks, Window's windows: only what has a shortcut (Show All History, Minimize).
            let shown = (userMenu(top) ? menu.kids.filter(keeps) : menu.kids).prefix(40)
            var entries = shown.map(listingEntry)
            if menu.kids.count > shown.count { entries.append("… \(menu.kids.count - shown.count) more (search with a query)") }
            let line = "\(top): " + entries.joined(separator: " · ")
            chars += line.count
            if chars > 9000 { lines.append("… (more menus; pass a query to search them)"); break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A menu item with its submenu's items, for the listing (`menuTree`); a top-level menu is one too, its title
    /// alone in `path`.
    final class MenuNode {
        let path: [String]
        let shortcut: String?
        let submenu: Bool
        var kids: [MenuNode] = []
        init(_ path: [String], _ shortcut: String? = nil, submenu: Bool = true) {
            (self.path, self.shortcut, self.submenu) = (path, shortcut, submenu)
        }
    }

    /// A walk's items, in menu order, as the menus they're in: each top-level menu with its items, each item with
    /// its submenu's items.
    static func menuTree(_ items: [MenuItem]) -> [MenuNode] {
        var tops: [MenuNode] = []
        var open: [MenuNode] = []  // the menus the next item can be in: a top-level one, then submenus in it
        for i in items where i.path.count > 1 {
            let parent = Array(i.path.dropLast())
            if i.path.count == 2, tops.last?.path != parent {
                tops.append(MenuNode(parent))
                open = [tops[tops.count - 1]]
            }
            while open.count > 1, open[open.count - 1].path != parent { open.removeLast() }
            guard let menu = open.last, menu.path == parent else { continue }
            let node = MenuNode(i.path, i.shortcut, submenu: i.hasSubmenu)
            menu.kids.append(node)
            if i.hasSubmenu { open.append(node) }
        }
        return tops
    }

    /// Whether the listing shows an item in a submenu, or in a menu of the user's own things: one with a shortcut,
    /// or a submenu holding one.
    static func keeps(_ n: MenuNode) -> Bool { n.submenu ? n.kids.contains(where: keeps) : n.shortcut != nil }

    /// An item as the listing shows it: "Save… cmd+s"; a submenu as its number of items and those it `keeps`
    /// (at most 40): "Find > (5: Find… cmd+f · Find Next cmd+g)", "Speech > (2)"; "Share >" if none were read.
    /// In a menu of the user's own things, just its count: "Move & Resize > (21)" (the same in every app's Window).
    static func listingEntry(_ n: MenuNode) -> String {
        let title = shownTitle(n.path)
        guard n.submenu else { return title + (n.shortcut.map { " \($0)" } ?? "") }
        guard !n.kids.isEmpty else { return title + " >" }
        let kept: [MenuNode] = userMenu(n.path[0]) ? [] : n.kids.filter(keeps)
        var shown = kept.prefix(40).map(listingEntry)
        if kept.count > 40 { shown.append("…") }
        return "\(title) > (\(n.kids.count)" + (shown.isEmpty ? ")" : ": " + shown.joined(separator: " · ") + ")")
    }

    /// Most characters the listing shows of a title of the user's own things (a page, a bookmark, a document).
    static let ownTitleMax = 70

    /// The title at the end of `path` as the listing shows it: clipped to `ownTitleMax` with "…" if it's one of the
    /// user's own things (`ownItem`). Clipped, it still picks the item in a path (`menuMatches`).
    static func shownTitle(_ path: [String]) -> String {
        guard let title = path.last else { return "" }
        return path.count > 1 && ownItem(path) ? clip(title, ownTitleMax) : title
    }

    /// "File > Open Recent > report.pdf", each title as `shownTitle`.
    static func shownPath(_ path: [String]) -> String {
        path.indices.map { shownTitle(Array(path[...$0])) }.joined(separator: " > ")
    }

    /// Normalised for matching: case, "..." vs "…", and spacing don't matter. (Menu items, and targets' labels.)
    static func menuKey(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "...", with: "…").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether lower-case `s` is its own `menuKey` for sure (plain ASCII, no dots, single spaces between words):
    /// a quick test that spares the work for most labels.
    static func ownKey(_ s: String) -> Bool {
        var last: UInt8 = 0x20  // a leading space isn't
        for b in s.utf8 {
            if b >= 0x80 || b == 0x2E || b < 0x20 || (b == 0x20 && last == 0x20) { return false }
            last = b
        }
        return last != 0x20 || s.isEmpty
    }

    /// A command's name as a name alone (`menu {item: "Export as PDF…"}`) matches it: as `menuKey`, and a
    /// closing "…" doesn't matter either ("Export as PDF" is "Export as PDF…").
    static func nameKey(_ s: String) -> String {
        var k = menuKey(s)
        while k.hasSuffix("…") { k.removeLast() }
        return k.trimmingCharacters(in: .whitespaces)
    }

    /// `menuKey` for matching a name by its start: without a closing "…", so one clipped in a note or an error
    /// ("Open Link in New Private Wi…") is the start of the whole name. As it is if that leaves nothing.
    static func startKey(_ s: String) -> String {
        let k = nameKey(s)
        return k.isEmpty ? menuKey(s) : k
    }

    /// Which of a menu's `titles` `want` names (their indices): those the same (`menuKey`), else those it's the
    /// start of, else those containing it (these two by `startKey`). Not exactly one: ambiguous, or a miss.
    static func menuMatches(_ titles: [String], _ want: String) -> [Int] {
        let k = menuKey(want), start = startKey(want), keys = titles.map(menuKey)
        var hits = keys.indices.filter { keys[$0] == k }
        if hits.isEmpty { hits = keys.indices.filter { keys[$0].hasPrefix(start) } }
        if hits.isEmpty { hits = keys.indices.filter { keys[$0].contains(start) } }
        return hits
    }

    /// Top-level menus that list the user's own things (pages, bookmarks, profiles, open windows) rather
    /// than the app's commands. English titles.
    static let userMenus: Set<String> = ["history", "bookmarks", "favorites", "favourites", "profiles", "people", "window"]

    static func userMenu(_ title: String) -> Bool { userMenus.contains(menuKey(title)) }

    /// An item in a menu of the user's own things: under one of `userMenus`, or in a submenu whose title
    /// says "recent" (Open Recent, Recently Closed, Recent Folders, …) or is History, Bookmarks or Favorites.
    /// A name alone never runs one, so a page, bookmark or document that shares a command's name can't
    /// be opened by accident (its full path still runs it).
    static func ownItem(_ path: [String]) -> Bool {
        guard let top = path.first else { return false }
        return userMenu(top) || path.dropFirst().dropLast().contains { title in
            let k = menuKey(title)
            return ["history", "bookmarks", "favorites", "favourites"].contains(k)
                || k.split(separator: " ").contains { $0.hasPrefix("recent") }
        }
    }

    /// The commands a name alone can mean: items without a submenu, named exactly that (`nameKey`),
    /// outside the user's own menus (`ownItem`).
    static func commandsNamed(_ name: String, in items: [MenuItem]) -> [MenuItem] {
        let k = nameKey(name)
        return items.filter { !$0.hasSubmenu && !ownItem($0.path) && nameKey($0.path.last ?? "") == k }
    }

    /// Why a name alone ran nothing, and what it could mean by full path (standing in for `menus(name)`):
    /// commands with exactly that name, then the user's own items with it, then items containing it.
    /// `whole`: false if the walk ran out of time or items before the end.
    static func nameMiss(_ name: String, in items: [MenuItem], whole: Bool = true) -> String {
        let k = nameKey(name), leaves = items.filter { !$0.hasSubmenu }
        func named(_ i: MenuItem) -> Bool { nameKey(i.path.last ?? "") == k }
        let commands = leaves.filter { named($0) && !ownItem($0.path) }, own = leaves.filter { named($0) && ownItem($0.path) }
        let near = leaves.filter { i in
            !named(i) && (menuKey(i.path.joined(separator: " > ")).contains(k)
                || i.shortcut.map { comboKey($0) == comboKey(name) } == true)
        }
        var head: String
        if commands.count > 1 {
            head = "\"\(name)\" names \(commands.count) menu commands"
        } else if commands.count == 1 {
            head = "the menus are too long to check that \"\(name)\" is the only one"
        } else if !own.isEmpty {
            head = "\"\(name)\" is only in menus that list the user's own things (History, Bookmarks, recent items, "
                + "Window), and a name alone never runs those"
        } else if !near.isEmpty {
            head = "no menu command is named exactly \"\(name)\""
        } else {
            return "nothing was run: no menu item matches \"\(name)\"" + (whole ? "" : " in the part of the menus read in time")
                + " (menus with a query searches every item: try another word)"
        }
        let list = commands + own + near.filter { !ownItem($0.path) } + near.filter { ownItem($0.path) }, cap = 12
        let shown = list.prefix(cap)
        if !commands.isEmpty || own.isEmpty, shown.contains(where: { ownItem($0.path) }) {
            head += " (\"full path only\": in the user's own History, Bookmarks, recent items or Window menu)"
        }
        if !whole, commands.count != 1 { head += "; the menus were too long to read them all" }
        let lines = shown.map { i in
            "  " + i.path.joined(separator: " > ") + (i.shortcut.map { " · \($0)" } ?? "") + (ownItem(i.path) ? " (full path only)" : "")
        } + (list.count > cap ? ["  … \(list.count - cap) more (menus \"\(name)\" lists them)"] : [])
        return "nothing was run: \(head). Give the full path of the one you mean:\n" + lines.joined(separator: "\n")
    }

    /// The full path of the one command a name alone means (`commandsNamed`); anything else runs nothing
    /// and fails saying what the name could mean (`nameMiss`). The commands are read first: the user's own
    /// menus (a browser's History and Bookmarks: thousands of items) only to explain a miss.
    static func commandPath(pid: pid_t, name: String) throws -> [String] {
        guard !nameKey(name).isEmpty else { throw HelperError("menu needs an item: a path like \"File > Save\", or a command's name") }
        let bar = menuBar(pid: pid)
        guard !bar.isEmpty else { throw HelperError("the app exposes no menu bar") }
        let start = Date(), budget: TimeInterval = 3
        let commands = menuItems(pid: pid, budget: budget, tops: bar.filter { !userMenu($0.1) })
        let whole = commands.count < 3000 && Date().timeIntervalSince(start) < budget
        let named = commandsNamed(name, in: commands)
        if whole, named.count == 1 { return named[0].path }
        let own = menuItems(pid: pid, budget: 1, tops: bar.filter { userMenu($0.1) })
        throw HelperError(nameMiss(name, in: commands + own, whole: whole))
    }

    /// Press the item at `path` (["File", "Export as PDF…"]); each step matches exactly, else by a unique
    /// prefix, else by a unique substring (`menuMatches`). A name alone (["Export as PDF…"]) is the one command
    /// with that name (`commandPath`). Returns the full path pressed, and the item's shortcut if the
    /// menu shows it disabled (then that's pressed instead: see the menu action).
    /// `check` sees the item's title before it's pressed, and can refuse it.
    static func pressMenu(pid: pid_t, path: [String], check: (String) throws -> Void = { _ in }) throws -> (String, String?) {
        let path = path.count == 1 ? try commandPath(pid: pid, name: path[0]) : path
        guard path.count >= 2 else { throw HelperError("menu needs an item: a path like \"File > Save\", or a command's name") }
        var level: [(AXUIElement, String)] = menuBar(pid: pid)
        guard !level.isEmpty else { throw HelperError("the app exposes no menu bar") }
        var chosen: [String] = []
        for (i, want) in path.enumerated() {
            let hits = menuMatches(level.map(\.1), want).map { level[$0] }
            let place = chosen.isEmpty ? "the menu bar" : chosen.joined(separator: " > ")
            guard hits.count == 1 else {
                let names = optionList((hits.isEmpty ? level : hits).map(\.1), near: want)
                throw HelperError(hits.isEmpty ? "no \"\(want)\" in \(place) (has: \(names))"
                                               : "\"\(want)\" is ambiguous in \(place): \(names)")
            }
            let (el, title) = hits[0]
            chosen.append(title)
            let name = chosen.joined(separator: " > ")
            if i == 1, menuKey(title) == "services" {
                throw HelperError("Services hand what's selected to other apps; puter-use doesn't use them")
            }
            if i == path.count - 1 {
                try check(title)
                if let sub = children(el).first, !children(sub).isEmpty {
                    let names = children(sub).compactMap { value($0, kAXTitleAttribute) as? String }.filter { !$0.isEmpty }
                    throw HelperError("\(name) opens a submenu: name one of its items (\(listed(names, max: 20)))")
                }
                if value(el, kAXEnabledAttribute) as? Bool == false {
                    let fields = ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdGlyph"]
                    if let key = shortcutText(char: value(el, fields[0]) as? String, mods: value(el, fields[1]) as? Int ?? 0,
                                              virtualKey: value(el, fields[2]) as? Int, glyph: value(el, fields[3]) as? Int) {
                        return (name, key)
                    }
                    throw HelperError("\(name) is disabled right now")
                }
                guard act(el, kAXPressAction) == .success else {
                    throw HelperError("couldn't press \(name) (disabled?)")
                }
                return (name, nil)
            }
            guard let sub = children(el).first else { throw HelperError("\(chosen.joined(separator: " > ")) has no submenu") }
            level = children(sub).compactMap { item in
                guard let t = value(item, kAXTitleAttribute) as? String, !t.isEmpty else { return nil }
                return (item, t)
            }
        }
        throw HelperError("empty menu path")
    }

    /// A shortcut as a set of key names, so "shift+cmd+E" and "cmd+shift+e" are the same. Every name
    /// `Keys.modifiers` presses as Command reads as "cmd": "super+q" is "cmd+q".
    static func comboKey(_ s: String) -> Set<String> {
        let alias = ["command": "cmd", "meta": "cmd", "super": "cmd", "win": "cmd", "windows": "cmd", "control": "ctrl",
                     "opt": "option", "alt": "option", "⌘": "cmd", "⇧": "shift"]
        return Set(s.lowercased().split(separator: "+").map { k in
            let n = Keys.normalize(String(k).trimmingCharacters(in: .whitespaces))
            return alias[n] ?? n
        })
    }

    /// "File > Export as PDF…" or ["File", "Export as PDF…"] → path components.
    static func menuPath(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        guard let s = v as? String else { return [] }
        return s.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
