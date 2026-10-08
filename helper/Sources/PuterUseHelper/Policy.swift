import AppKit
import ApplicationServices

/// What an agent may do in each app, and what it must have the user's OK for. The defaults below can
/// be changed in `~/Library/Application Support/puter-use/policy.json` (the agent's tools can't):
///
///     {"apps": {"com.apple.Terminal": "full", "Slack": "view"},
///      "confirm": ["delete", "send"],
///      "secure_fields": "allow"}
///
/// - apps: by bundle id or name. `deny`: not even looked at (left out of screen captures too);
///   `view`: screenshots, find and menus, but no actions; `click`: the pointer, but no typing, keys or
///   menu commands (one typed line in a terminal can run anything); `full`: everything.
/// - confirm: a press on a control whose label has one of these words or phrases stops the batch until
///   the user agrees (the action is repeated with confirm: true). [] turns it off.
/// - secure_fields: `block` (default) refuses to type or paste into password fields.
///
/// An entry that can't be understood is reported (in `windows`) and read the safe way: an app with an
/// unknown level is `deny`. A file that isn't JSON at all leaves the defaults in force.
enum Policy {
    enum Level: String, Comparable {
        case deny, view, click, full
        static func < (a: Level, b: Level) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
        static let order: [Level] = [.deny, .view, .click, .full]
    }

    static let defaultApps: [String: Level] = [
        // Password managers: nothing for an agent to do there.
        "com.1password.1password": .deny, "com.agilebits.onepassword7": .deny, "com.agilebits.onepassword-osx": .deny,
        "com.bitwarden.desktop": .deny, "com.apple.keychainaccess": .deny, "com.apple.passwords": .deny,
        "com.lastpass.lastpass": .deny, "org.keepassxc.keepassxc": .deny, "com.dashlane.dashlanephonefinal": .deny,
        "in.sinew.enpass-desktop": .deny, "com.proton.pass": .deny,
        // Terminals: typing is running commands.
        "com.apple.terminal": .click, "com.googlecode.iterm2": .click, "dev.warp.warp-stable": .click,
        "com.mitchellh.ghostty": .click, "org.alacritty": .click, "net.kovidgoyal.kitty": .click,
        "com.github.wez.wezterm": .click,
    ]

    static let defaultConfirm = [
        "delete", "remove", "erase", "discard", "don't save", "revert", "move to trash", "send", "pay", "buy",
        "purchase", "place order", "checkout", "check out", "transfer", "publish", "post", "empty trash",
        "uninstall", "deactivate",
    ]

    /// Labels that only look risky: arranging layers isn't sending anything.
    static let harmless = ["send to back", "send backward"]

    /// Lowercase words separated by single spaces, as labels and confirm words are compared:
    /// "Don't Save…" is "don t save".
    static func phrase(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    struct Config {
        var apps: [String: Level] = Policy.defaultApps
        var confirm: [String] = Policy.defaultConfirm.map(Policy.phrase)
        var allowSecureFields = false
        var problem: String?  // the file couldn't be read: the defaults apply
    }

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/puter-use/policy.json")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: Date?, config: Config)?

    /// The policy in force: the defaults, overridden by the file (re-read when it changes).
    static var config: Config {
        lock.lock()
        defer { lock.unlock() }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if let cache, cache.stamp == stamp { return cache.config }
        var c = Config()
        if stamp != nil {
            var problems: [String] = []
            do {
                guard let data = try? Data(contentsOf: file) else { throw HelperError("couldn't be read") }
                guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw HelperError("isn't valid JSON") }
                guard let d = obj as? [String: Any] else {
                    throw HelperError("isn't a JSON object like {\"apps\": {…}, \"confirm\": […], \"secure_fields\": \"block\"}")
                }
                for k in d.keys.sorted() where !["apps", "confirm", "secure_fields"].contains(k) {
                    problems.append("unknown key \"\(k)\" (ignored)")
                }
                if let v = d["apps"] {
                    if let apps = v as? [String: Any] {
                        for (app, v) in apps.sorted(by: { $0.key < $1.key }) {
                            if let s = v as? String, let level = Level(rawValue: s.lowercased()) {
                                c.apps[app.lowercased()] = level
                            } else {
                                c.apps[app.lowercased()] = .deny  // what was meant isn't known: the safe reading
                                problems.append("apps.\(app) must be full, click, view or deny (treated as deny)")
                            }
                        }
                    } else {
                        problems.append("apps must be an object like {\"Slack\": \"view\"} (ignored)")
                    }
                }
                if let v = d["confirm"] {
                    if let words = v as? [String] {
                        c.confirm = words.map(phrase).filter { !$0.isEmpty }
                    } else {
                        problems.append("confirm must be a list like [\"delete\", \"send\"] (using the default list)")
                    }
                }
                if let v = d["secure_fields"] {
                    switch (v as? String)?.lowercased() {
                    case "allow": c.allowSecureFields = true
                    case "block": break
                    default: problems.append("secure_fields must be \"block\" or \"allow\" (blocking)")
                    }
                }
            } catch {
                c = Config()
                problems = ["\(error) (using the defaults)"]
            }
            if !problems.isEmpty { c.problem = "\(file.path): " + problems.joined(separator: "; ") }
        }
        cache = (stamp, c)
        return c
    }

    static func level(_ pid: pid_t) -> Level {
        guard pid > 0, pid != Windows.ownPID, let app = NSRunningApplication(processIdentifier: pid) else { return .full }
        let apps = config.apps
        if let id = app.bundleIdentifier?.lowercased(), let l = apps[id] { return l }
        if let name = app.localizedName?.lowercased(), let l = apps[name] { return l }
        return .full
    }

    static func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    static func refusal(_ pid: pid_t, _ level: Level, doing: String) -> HelperError {
        let what: String
        switch level {
        case .deny: what = "keeps agents out of \(appName(pid)) entirely"
        case .view: what = "lets agents look at \(appName(pid)) but not act in it"
        case .click: what = "lets agents click in \(appName(pid)) but not type, press keys or run menu commands"
        case .full: what = "allows it"
        }
        return HelperError("not allowed: puter-use's policy \(what) (\(doing)). The user can change that in \(file.path)")
    }

    /// Looking at an app (screenshot, find, menus).
    static func checkLook(_ pid: pid_t?) throws {
        guard let pid else { return }
        let l = level(pid)
        if l == .deny { throw refusal(pid, l, doing: "looking") }
    }

    /// Actions that are typing, keys or commands rather than the pointer.
    static let keyboard: Set<String> = [
        "type", "type_text", "keypress", "key", "press_key", "hotkey", "key_down", "keydown", "key_up", "keyup",
        "hold_key", "hold", "paste", "set_value", "navigate", "goto", "go_to", "menu",
    ]
    /// What `view` still allows: nothing the app acts on (scrolling and hovering only change what's shown).
    static let looking: Set<String> = ["wait", "sleep", "wait_for", "waitfor", "clipboard", "scroll", "move", "mouse_move", "hover",
                                       "screenshot"]

    /// The action being run (set by act), for routes that only find their app at the point (`.screen`).
    nonisolated(unsafe) static var running: [String: Any]?

    /// Before an action on an app: may the agent do it there?
    static func checkAction(_ a: [String: Any], pid: pid_t?) throws {
        guard let pid else { return }
        let l = level(pid)
        let kind = Handlers.kind(a)
        if looking.contains(kind) && l >= .view { return }
        if l <= .view { throw refusal(pid, l, doing: kind) }
        if l == .click {
            let typing = keyboard.contains(kind)
                || kind == "fill" && (a["fields"] as? [[String: Any]] ?? []).contains { $0["text"] != nil || $0["value"] != nil }
                || kind == "fill" && a["submit"] as? Bool == true
            if typing { throw refusal(pid, l, doing: kind) }
        }
    }

    /// Input to whichever app is at a point of the screen (or the frontmost, for keys).
    static func checkRoute(pid: pid_t, keyboard: Bool) throws {
        if let a = running { return try checkAction(a, pid: pid) }
        let l = level(pid)
        if l <= .view || (keyboard && l == .click) { throw refusal(pid, l, doing: keyboard ? "keys" : "pointer") }
    }

    // MARK: - confirmation

    /// The user hasn't OK'd a press that looks irreversible.
    struct NeedsOK: Error, CustomStringConvertible {
        let label: String
        let word: String
        /// What the action had already done when it stopped (a context menu opened to find the item).
        var partly: String?
        var description: String { "\"\(AX.clip(label, 60))\" looks like it can't be undone (\(word))" }
    }

    /// The confirm word or phrase in `label`, matched as whole words.
    static func riskyWord(_ label: String) -> String? {
        var l = " " + phrase(label) + " "
        for h in harmless { l = l.replacingOccurrences(of: " \(h) ", with: " ") }
        return config.confirm.first { l.contains(" \($0) ") }
    }

    /// A press on `node` (or on whatever control is at `p`) needs the user's OK first, unless the action
    /// says it has it (`confirm: true`).
    @MainActor
    static func checkPress(_ a: [String: Any], node: AX.Node?, at p: CGPoint?, pid: pid_t) throws {
        guard a["confirm"] as? Bool != true, !config.confirm.isEmpty else { return }
        var label: String?
        if let node { label = AX.label(node.element) ?? node.label }
        if label == nil, let p, let el = Macros.control(pid, at: p) { label = AX.label(el) }
        if let label, let word = riskyWord(label) { throw NeedsOK(label: label, word: word) }
    }

    /// Choosing a menu item or option: the same OK, by its title.
    static func checkItem(_ a: [String: Any], _ title: String) throws {
        guard a["confirm"] as? Bool != true, !config.confirm.isEmpty else { return }
        if let word = riskyWord(title) { throw NeedsOK(label: title, word: word) }
    }

    /// A menu item chosen with the pointer at `click`: one that puts text in (Paste, AutoFill) is typing
    /// by other means.
    static func checkPointerItem(_ pid: pid_t, _ title: String) throws {
        guard level(pid) == .click else { return }
        let k = phrase(title)
        if k.hasPrefix("paste") || k.hasPrefix("autofill") || k.hasPrefix("passwords") {
            throw refusal(pid, .click, doing: "choosing \"\(AX.clip(title, 40))\", which puts text in")
        }
    }

    /// A key that puts text in: a character (with Shift or Option or neither), a space, or a paste.
    static func typesText(_ combo: [String]) -> Bool {
        let keys = combo.map(Keys.normalize)
        let mods = keys.compactMap { Keys.modifiers[$0] }, rest = keys.filter { Keys.modifiers[$0] == nil }
        if rest == ["v"] && mods.contains(.maskCommand) { return true }
        guard rest.count == 1, mods.allSatisfy({ $0 == .maskShift || $0 == .maskAlternate }) else { return false }
        return rest[0].count == 1 || rest[0] == "space"
    }

    /// Keys that do what a risky press would: the shortcut of a menu command with a confirm word in its
    /// title, Return while the window's (or its sheet's) default button has one, or Space on a focused
    /// button that has one. `textArea` says whether a Return goes into a text area (a new line, no
    /// button); by default, whether the focus is in one now.
    @MainActor static func checkKeys(_ a: [String: Any], _ seq: [[String]], _ r: Route, textArea: Bool? = nil) throws {
        try checkShortcuts(a, seq, r.pid)
        try checkFocusKeys(a, seq, r, textArea: textArea)
    }

    /// The shortcuts in `seq` of menu commands that need the user's OK (wherever the focus is).
    @MainActor static func checkShortcuts(_ a: [String: Any], _ seq: [[String]], _ pid: pid_t) throws {
        guard a["confirm"] as? Bool != true, !config.confirm.isEmpty else { return }
        for keys in seq where AX.comboKey(keys.joined(separator: "+")).contains("cmd") {
            if let (_, title) = AX.menuItem(pid: pid, shortcut: keys), let word = riskyWord(title) {
                throw NeedsOK(label: "\(title) (\(keys.joined(separator: "+")))", word: word)
            }
        }
    }

    /// Return and Space in `seq`, judged by where the focus is now.
    @MainActor static func checkFocusKeys(_ a: [String: Any], _ seq: [[String]], _ r: Route, textArea: Bool? = nil) throws {
        guard a["confirm"] as? Bool != true, !config.confirm.isEmpty, !seq.isEmpty else { return }
        let combos = seq.map { AX.comboKey($0.joined(separator: "+")) }
        let returns = combos.contains { $0 == ["return"] || $0 == ["enter"] || $0 == ["kpenter"] }
        let space = combos.contains { $0 == ["space"] }
        guard returns || space else { return }
        let focus = AX.focusedElement(pid: r.pid)
        let focusRole = focus.flatMap { AX.value($0, kAXRoleAttribute) as? String }
        if returns, !(textArea ?? (focusRole == "AXTextArea")), let win = AX.window(pid: r.pid, wid: r.wid) {
            // A sheet's default button answers Return before its window's.
            let sheets = AX.children(win).filter { AX.value($0, kAXRoleAttribute) as? String == "AXSheet" }
            for host in sheets.reversed() + [win] {
                guard let b = AX.value(host, kAXDefaultButtonAttribute), CFGetTypeID(b) == AXUIElementGetTypeID() else { continue }
                if let label = AX.label(b as! AXUIElement), let word = riskyWord(label) { throw NeedsOK(label: label, word: word) }
                break
            }
        }
        if space, focusRole == "AXButton", let focus, let label = AX.label(focus), let word = riskyWord(label) {
            throw NeedsOK(label: label, word: word)
        }
    }

    // MARK: - password fields

    /// Typing or pasting into the app's focused element: refused when it's a password field.
    static func checkSecureFocus(_ pid: pid_t) throws {
        guard !config.allowSecureFields else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let f = AX.value(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return }
        if isSecure(f as! AXUIElement) { throw secureRefusal() }
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        AX.value(el, kAXSubroleAttribute) as? String == "AXSecureTextField"
    }

    static func secureRefusal() -> HelperError {
        HelperError("not allowed: that's a password field, and puter-use doesn't type into those. Ask the user to "
            + "fill it in (or they can set \"secure_fields\": \"allow\" in \(file.path))")
    }
}
