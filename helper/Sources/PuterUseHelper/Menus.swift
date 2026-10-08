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

    /// Every item, in menu order, up to 3 levels deep (top menu > item > submenu item > …).
    static func menuItems(pid: pid_t, budget: TimeInterval = 3) -> [MenuItem] {
        let start = Date()
        let fields = [kAXTitleAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey",
                      "AXMenuItemCmdGlyph", kAXChildrenAttribute] as CFArray
        var out: [MenuItem] = []
        func walk(_ menu: AXUIElement, _ path: [String], _ depth: Int) {
            for item in children(menu) {
                guard out.count < 3000, Date().timeIntervalSince(start) < budget else { return }
                var raw: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, fields, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                      let v = raw as? [AnyObject], v.count == 6, let title = v[0] as? String, !title.isEmpty
                else { continue }  // separators have no title
                // Services hand what's selected to other apps, and `menu` refuses them: not listed.
                if depth == 1, menuKey(title) == "services" { continue }
                let sub = (v[5] as? [AXUIElement])?.first
                out.append(MenuItem(path: path + [title],
                                    shortcut: shortcutText(char: v[1] as? String, mods: (v[2] as? Int) ?? 0,
                                                           virtualKey: v[3] as? Int, glyph: v[4] as? Int),
                                    element: item, hasSubmenu: sub != nil))
                if let sub, depth < 3 { walk(sub, path + [title], depth + 1) }
            }
        }
        for (top, title) in menuBar(pid: pid) {
            if let menu = children(top).first { walk(menu, [title], 1) }
        }
        return out
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

    /// The menu bar as text. Without a query: one line per menu, e.g.
    /// `File: New Window cmd+n · Export as PDF… cmd+shift+e · Share > Email Link`. With one: the items whose
    /// name or shortcut matches, one per line with its full path.
    static func menuListing(pid: pid_t, query: String?) -> String {
        let items = menuItems(pid: pid)
        guard !items.isEmpty else { return "(no menu bar: the app has none, or exposes none to accessibility)" }
        func label(_ i: MenuItem) -> String { i.path.joined(separator: " > ") + (i.shortcut.map { " · \($0)" } ?? "") }
        if let q = query?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty {
            let hits = items.filter { i in
                !i.hasSubmenu && (i.path.joined(separator: " > ").lowercased().contains(q)
                    || i.shortcut.map { comboKey($0) == comboKey(q) } == true)
            }
            if hits.isEmpty { return "(no menu item matches \"\(q)\")" }
            return hits.prefix(40).map(label).joined(separator: "\n")
                + (hits.count > 40 ? "\n… \(hits.count - 40) more; narrow the query" : "")
        }
        var lines: [String] = []
        var chars = 0
        for (_, top) in menuBar(pid: pid) {
            let entries = items.filter { $0.path.first == top && $0.path.count > 1 && !$0.hasSubmenu }.map { i in
                i.path.dropFirst().joined(separator: " > ") + (i.shortcut.map { " \($0)" } ?? "")
            }
            guard !entries.isEmpty else { continue }
            // Long menus (History, Bookmarks, recent files) are mostly the user's own items: list the start.
            let shown = entries.prefix(40)
            let line = "\(top): " + shown.joined(separator: " · ")
                + (entries.count > shown.count ? " · … \(entries.count - shown.count) more (search with a query)" : "")
            chars += line.count
            if chars > 9000 { lines.append("… (more menus; pass a query to search them)"); break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Normalised for matching: case, "..." vs "…", and spacing don't matter.
    static func menuKey(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "...", with: "…").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Press the item at `path` (["File", "Export as PDF…"]); each step matches exactly, else by a unique
    /// prefix, else by a unique substring. Returns the full path pressed, and the item's shortcut if the
    /// menu shows it disabled (then that's pressed instead: see the menu action).
    /// `check` sees the item's title before it's pressed, and can refuse it.
    static func pressMenu(pid: pid_t, path: [String], check: (String) throws -> Void = { _ in }) throws -> (String, String?) {
        guard path.count >= 2 else { throw HelperError("menu needs a path like \"File > Save\" (a menu and an item)") }
        var level: [(AXUIElement, String)] = menuBar(pid: pid)
        guard !level.isEmpty else { throw HelperError("the app exposes no menu bar") }
        var chosen: [String] = []
        for (i, want) in path.enumerated() {
            let k = menuKey(want)
            var hits = level.filter { menuKey($0.1) == k }
            if hits.isEmpty { hits = level.filter { menuKey($0.1).hasPrefix(k) } }
            if hits.isEmpty { hits = level.filter { menuKey($0.1).contains(k) } }
            let place = chosen.isEmpty ? "the menu bar" : chosen.joined(separator: " > ")
            guard hits.count == 1 else {
                let names = (hits.isEmpty ? level : hits).prefix(30).map(\.1).joined(separator: ", ")
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
                    throw HelperError("\(name) opens a submenu: name one of its items (\(names.prefix(20).joined(separator: ", ")))")
                }
                if value(el, kAXEnabledAttribute) as? Bool == false {
                    let fields = ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdGlyph"]
                    if let key = shortcutText(char: value(el, fields[0]) as? String, mods: value(el, fields[1]) as? Int ?? 0,
                                              virtualKey: value(el, fields[2]) as? Int, glyph: value(el, fields[3]) as? Int) {
                        return (name, key)
                    }
                    throw HelperError("\(name) is disabled right now")
                }
                guard AXUIElementPerformAction(el, kAXPressAction as CFString) == .success else {
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

    /// A shortcut as a set of key names, so "shift+cmd+E" and "cmd+shift+e" are the same.
    static func comboKey(_ s: String) -> Set<String> {
        let alias = ["command": "cmd", "control": "ctrl", "opt": "option", "alt": "option", "⌘": "cmd", "⇧": "shift"]
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
