import AppKit

/// The first time an agent looks at an app, a few lines it would otherwise spend steps finding out:
/// whether the app can be scripted (often far quicker than its UI), its most useful keyboard
/// shortcuts, quirks of driving it in the background, and the macros saved for it. Once per app per
/// session.
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
        let name = app.localizedName ?? id
        var parts: [String] = []
        if let tip = quirk(app) { parts.append(tip) }
        if scriptable(app) {
            parts.append("scriptable: osascript -e 'tell application \"\(name)\" to …' is often quicker than its UI "
                + "(commands: sdef \"\(app.bundleURL?.path ?? name)\")")
        }
        let keys = shortcuts(pid)
        if !keys.isEmpty { parts.append("shortcuts: " + keys.joined(separator: " · ") + " (menus lists all)") }
        if let saved = savedMacros(Macros.list(pid: pid)) { parts.append(saved) }
        return parts.isEmpty ? nil : "\(name): " + parts.joined(separator: "; ")
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

    /// Everyone knows these; they'd only take room.
    static let obvious: Set<String> = [
        "undo", "redo", "cut", "copy", "paste", "paste and match style", "select all", "minimize", "close", "close window",
        "close tab", "close all", "hide others", "show all", "bring all to front", "emoji & symbols", "start dictation…",
        "enter full screen", "exit full screen", "zoom", "print…", "page setup…", "help", "autofill", "start dictation",
    ]

    /// Up to a dozen shortcuts from the app's own menus, in menu order, skipping the obvious ones. The walk
    /// stops at the 12th, so menus further along (a browser's History, Bookmarks) aren't read.
    static func shortcuts(_ pid: pid_t) -> [String] {
        var out: [String] = []
        _ = AX.menuItems(pid: pid, budget: 1.2) { item in
            if let s = shortcut(item) { out.append(s) }
            return out.count == 12
        }
        return out
    }

    /// "Export as PDF… cmd+shift+e" for the card, or nil for an item without a shortcut, one that opens a
    /// submenu, an obvious one, or one in Window or Help.
    static func shortcut(_ item: AX.MenuItem) -> String? {
        guard let keys = item.shortcut, !item.hasSubmenu else { return nil }
        let title = item.path.last ?? ""
        let key = title.lowercased()
        if obvious.contains(key) || ["hide ", "quit ", "undo ", "redo ", "show all tabs"].contains(where: key.hasPrefix)
            || item.path.first == "Window"
            || item.path.first == "Help" { return nil }
        return "\(AX.clip(title, 28)) \(keys)"
    }

    /// What's different about driving this app.
    static func quirk(_ app: NSRunningApplication) -> String? {
        let id = app.bundleIdentifier?.lowercased() ?? ""
        let pid = app.processIdentifier
        if Windows.isElectron(pid) { return "Electron app: if it ignores background input, use foreground=true" }
        if Windows.isChromium(pid) { return "Chromium: in the background, shortcuts only work if they're in its menus; browse in your own window (navigate)" }
        if id.hasPrefix("org.mozilla.") { return "Firefox: hover menus follow the real pointer, so click instead of hovering" }
        switch id {
        case "com.apple.finder": return "file moves, copies and renames are quicker and surer as shell commands (mv, cp, open)"
        case "com.apple.terminal", "com.googlecode.iterm2": return "run commands in your own shell rather than typing into the user's terminal"
        case "com.apple.mail", "com.apple.mobilesms", "com.tinyspeck.slackmacgap": return "never send anything without the user's OK"
        case "com.apple.systempreferences", "com.apple.systemsettings": return "settings changes need the user's OK"
        default: return nil
        }
    }
}
