import AppKit

/// The first time an agent looks at an app, a few lines it would otherwise spend steps finding out:
/// whether the app can be scripted (often far quicker than its UI), its most useful keyboard
/// shortcuts, and quirks of driving it in the background. Once per app per session.
enum AppCards {
    static var enabled: Bool {
        get { Session.current.cards }
        set { Session.current.cards = newValue }
    }
    static var shown: Set<String> {
        get { Session.current.carded }
        set { Session.current.carded = newValue }
    }

    static func card(pid: pid_t) -> String? {
        guard enabled, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        let id = app.bundleIdentifier ?? "pid \(pid)"
        guard !shown.contains(id) else { return nil }
        shown.insert(id)
        let name = app.localizedName ?? id
        var parts: [String] = []
        if let tip = quirk(app) { parts.append(tip) }
        if scriptable(app) {
            parts.append("scriptable: osascript -e 'tell application \"\(name)\" to …' is often quicker than its UI "
                + "(commands: sdef \"\(app.bundleURL?.path ?? name)\")")
        }
        let keys = shortcuts(pid)
        if !keys.isEmpty { parts.append("shortcuts: " + keys.joined(separator: " · ") + " (menus lists all)") }
        return parts.isEmpty ? nil : "\(name): " + parts.joined(separator: "; ")
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

    /// Up to a dozen shortcuts from the app's own menus, in menu order, skipping the obvious ones.
    static func shortcuts(_ pid: pid_t) -> [String] {
        var out: [String] = []
        for item in AX.menuItems(pid: pid, budget: 1.2) where item.shortcut != nil && !item.hasSubmenu {
            let title = item.path.last ?? ""
            let key = title.lowercased()
            if obvious.contains(key) || ["hide ", "quit ", "undo ", "redo ", "show all tabs"].contains(where: key.hasPrefix)
                || item.path.first == "Window"
                || item.path.first == "Help" { continue }
            out.append("\(AX.clip(title, 28)) \(item.shortcut!)")
            if out.count == 12 { break }
        }
        return out
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
