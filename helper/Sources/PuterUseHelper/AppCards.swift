import AppKit

/// The first time an agent looks at an app, a few lines it would otherwise spend steps finding out:
/// whether the app can be scripted (often far quicker than its UI), its most useful keyboard
/// shortcuts, quirks of driving it in the background, and the macros saved for it. Once per app per
/// session. The reply it comes with names the app already, so the card doesn't.
enum AppCards {
    static var enabled: Bool {
        get { Session.current.cards }
        set { Session.current.cards = newValue }
    }
    static var shown: Store<String, Bool> { Session.current.carded }

    @MainActor static func card(pid: pid_t) -> String? {
        guard enabled, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        let id = app.bundleIdentifier ?? "pid \(pid)"
        guard shown[id] == nil else { return nil }
        shown[id] = true
        var parts: [String] = []
        if let tip = quirk(kind(app), id: app.bundleIdentifier ?? "") { parts.append(tip) }
        if scriptable(app) { parts.append("scriptable (sdef \"\(app.bundleURL?.path ?? app.localizedName ?? id)\")") }
        let keys = shortcuts(pid)
        if !keys.isEmpty { parts.append("shortcuts: " + keys.joined(separator: " · ")) }
        if let saved = savedMacros(Macros.list(pid: pid)) { parts.append(saved) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// "saved macros: export pdf (file), tidy up" for the card: the first 8 of the app's macros by name, with
    /// their vars (no steps). Nil when it has none.
    static func savedMacros(_ saved: [Macros.Entry]) -> String? {
        guard !saved.isEmpty else { return nil }
        let names = saved.prefix(8).map { m in
            AX.clip(m.name, 28) + (m.vars.isEmpty ? "" : " (\(AX.clip(m.vars.joined(separator: ", "), 28)))")
        }
        let more = saved.count > 8 ? ", +\(saved.count - 8) more (macros lists all)" : ""
        return "saved macros: " + names.joined(separator: ", ") + more
    }

    /// AppleScript support, as the app declares it.
    static func scriptable(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
        return info["NSAppleScriptEnabled"] as? Bool == true || (info["NSAppleScriptEnabled"] as? String)?.lowercased() == "yes"
            || info["OSAScriptingDefinition"] != nil
    }

    /// Everyone knows these; they'd only take room. As `AX.menuKey` has them ("..." is "…").
    static let obvious: Set<String> = [
        "undo", "redo", "cut", "copy", "paste", "paste and match style", "select all", "minimize", "close", "close window",
        "close tab", "close all", "hide others", "show all", "bring all to front", "emoji & symbols", "start dictation…",
        "enter full screen", "exit full screen", "zoom", "print…", "page setup…", "help", "autofill", "start dictation",
        // The standard commands of any Mac app's File, Edit, Format and View menus.
        "settings…", "preferences…", "new", "new window", "new tab", "new document", "open", "open…", "open file…",
        "save", "save…", "save as…", "duplicate", "rename…", "revert to saved", "delete", "find", "find…",
        "find in page…", "find next", "find again", "find previous", "find and replace…", "use selection for find",
        "jump to selection", "check document now", "show spelling and grammar", "bold", "italic", "underline",
        "show fonts", "show colors", "reload", "reload page", "reload this page", "zoom in", "zoom out", "actual size",
        "back", "forward",
    ]

    /// The most shortcuts a card lists: past the standard ones, an app has only a few of its own worth knowing.
    static let maxShortcuts = 8

    /// Up to 8 shortcuts from the app's own menus, in menu order, skipping the obvious ones. The walk stops at
    /// the 8th, and leaves the menus of the user's own things unread (`opens`).
    static func shortcuts(_ pid: pid_t) -> [String] {
        var out: [String] = []
        _ = AX.menuItems(pid: pid, budget: 1.2, enter: opens, until: { item in
            if let s = shortcut(item) { out.append(s) }
            return out.count == maxShortcuts
        })
        return out
    }

    /// Whether the card's walk opens the menu at `path` (a top-level menu, or a submenu): not one listing the
    /// user's own things (History, Bookmarks, Profiles, Window; Open Recent and other recent items), which can
    /// be long and hold no commands of the app's, nor Help (none of its items go on the card).
    static func opens(_ path: [String]) -> Bool {
        if path.count == 1 { return !AX.userMenu(path[0]) && AX.menuKey(path[0]) != "help" }
        return !AX.ownItem(path + [""])  // an item in it would be one of the user's own
    }

    /// "Export as PDF… cmd+shift+e" for the card, or nil for an item without a shortcut, one that opens a
    /// submenu, an obvious one, or one in Window or Help.
    static func shortcut(_ item: AX.MenuItem) -> String? {
        guard let keys = item.shortcut, !item.hasSubmenu else { return nil }
        let title = item.path.last ?? ""
        let key = AX.menuKey(title)
        if obvious.contains(key) || ["hide ", "quit ", "undo ", "redo ", "show all tabs"].contains(where: key.hasPrefix)
            || (key.hasPrefix("new ") && keys == "cmd+n")  // New Message, New Note, …
            || item.path.first == "Window"
            || item.path.first == "Help" { return nil }
        return "\(AX.clip(title, 28)) \(keys)"
    }

    /// Kinds of app driven differently in the background.
    enum Kind { case electron, chromium, firefox }

    static func kind(_ app: NSRunningApplication) -> Kind? {
        if Windows.isElectron(app.processIdentifier) { return .electron }
        if Windows.isChromium(app.processIdentifier) { return .chromium }
        if (app.bundleIdentifier?.lowercased() ?? "").hasPrefix("org.mozilla.") { return .firefox }
        return nil
    }

    /// What's different about driving the app with bundle id `id`, of kind `kind`: its own quirk, then its
    /// kind's (Slack is an Electron app, and still never sends anything without the user's OK).
    static func quirk(_ kind: Kind?, id: String) -> String? {
        var tips: [String] = []
        switch id.lowercased() {
        case "com.apple.finder": tips.append("file moves, copies and renames are quicker and surer as shell commands (mv, cp, open)")
        case "com.apple.terminal", "com.googlecode.iterm2": tips.append("run commands in your own shell rather than typing into the user's terminal")
        case "com.apple.mail", "com.apple.mobilesms", "com.tinyspeck.slackmacgap": tips.append("never send anything without the user's OK")
        case "com.apple.systempreferences", "com.apple.systemsettings": tips.append("settings changes need the user's OK")
        default: break
        }
        switch kind {
        case .electron: tips.append("Electron app: if it ignores background input, use foreground=true")
        case .chromium: tips.append("in the background, shortcuts only work if they're in its menus; browse in your own window (navigate)")
        case .firefox: tips.append("hover menus follow the real pointer, so click instead of hovering")
        case nil: break
        }
        return tips.isEmpty ? nil : tips.joined(separator: "; ")
    }
}
