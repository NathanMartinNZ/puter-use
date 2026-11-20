import AppKit
import ApplicationServices

/// Actions that do in one step what a person does in several: type into a field, fill a form, go to a
/// web address, open a file or app, pick from a pop-up, wait for something to appear.
extension Handlers {
    static let textInputs: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Windows the agent opened this session (by navigate or open, or followed into): its own, so
    /// navigating one doesn't replace a page the user was reading.
    static var agentWindows: Set<CGWindowID> {
        get { Session.current.agentWindows }
        set { Session.current.agentWindows = newValue }
    }

    /// type {text, element|x,y, clear, submit}: click into the field first if one is given, optionally
    /// empty it, type, and optionally press Return.
    static func typeInto(_ a: [String: Any], _ text: String, _ run: Run) async throws {
        var node: AX.Node?
        if a["element"] != nil || a["target"] != nil {
            node = try elementNode(a, run.target)
            // The keys go wherever the focus ends up: not into a button that was named by mistake.
            if let n = node, !AX.isTextInput(n.element) {
                throw HelperError("that's a \(AX.describe(n.element)), not a text field to type into")
            }
        }
        // A Return outside a text area presses the window's default button: if that needs the user's OK,
        // stop before anything is clicked, emptied or typed.
        if a["submit"] as? Bool == true || text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let r = try route(run.target, at: nil, foreground: run.foreground)
            try Policy.checkFocusKeys(Policy.running ?? a, [["return"]], r, textArea: node.map { $0.role == "AXTextArea" })
        }
        if a["element"] != nil || a["target"] != nil || a["x"] != nil || a["coordinate"] != nil {
            var click: [String: Any] = ["type": "click", "_pointer": true]  // a real click: it puts the caret there
            for k in ["element", "target", "x", "y", "coordinate", "units"] { if let v = a[k] { click[k] = v } }
            if let node { click["_node"] = node }  // the field checked above, not found again
            try await perform(click, run)
            await Input.sleep(typist.between())
        }
        let r = try route(run.target, at: nil, foreground: run.foreground)
        if run.foreground { prepareForeground(r) }
        var field: AX.Node?  // the text input typed into: its text can be selected exactly
        if let n = node, AX.isTextInput(n.element) {
            // The click should have put the caret in it; if the app didn't take it (a click spent on
            // activating it), focus it directly rather than type into whatever had the focus.
            func focused() -> Bool { AX.focusedElement(pid: r.pid).map { AX.isInside($0, n.element) } ?? false }
            if !focused() {
                _ = AX.focus(n)
                await Input.ms(60)
                guard focused() else { throw HelperError("couldn't put the caret in the \(AX.describe(n.element)); nothing was typed") }
            }
            field = n
        }
        if field == nil, let f = AX.focusedElement(pid: r.pid), AX.isInWindow(f, r.wid), AX.isTextInput(f) {
            let role = AX.value(f, kAXRoleAttribute) as? String ?? ""
            field = AX.Node(element: f, frame: AX.frame(f), role: role, label: AX.label(f), name: AX.roleNames[role] ?? "field")
        }
        let length = field.flatMap { (AX.value($0.element, kAXValueAttribute) as? String).map { ($0 as NSString).length } }
        // A browser's address bar holds one address: a new one replaces it. (A click selects the old one
        // there, and moving the caret to its end made two URLs run together.)
        let addressBar = field.map { AX.isBrowserAddressBar($0.element, pid: r.pid) } ?? false
        let replace = a["clear"] as? Bool ?? addressBar
        if replace {
            guard field != nil else {
                // Select-all and delete on whatever has the focus could empty a list of mail, not a field.
                let focus = AX.focusedElement(pid: r.pid).map(AX.describe) ?? "nothing"
                throw HelperError("clear needs a text field, and the focus is on \(focus)")
            }
            if let field, let length, length > 0, AX.select(field.element, CFRange(location: 0, length: length)) {
                try await press(["BackSpace"], r)
            } else if (length ?? 1) > 0 {
                try await press(["cmd", "a"], r)
                await Input.sleep(typist.between())
                try await press(["BackSpace"], r)
            }
            if Connection.current?.work.fields == nil { Connection.current?.work.did.append("emptied the field") }
            await Input.sleep(typist.between())
        } else if let field, let length {
            // Keep a selection the app made itself (a click in one selects all): typing replaces it, as
            // it would for a person. Otherwise the click landed mid-text: type after what's there.
            if (AX.selectedRange(field.element)?.length ?? 0) == 0 {
                AX.select(field.element, CFRange(location: length, length: 0))
            }
        }
        // An address sent from the address bar is checked as navigate checks it: a Return that went nowhere
        // (or a page that didn't load) gets a note, not a quiet success.
        let newline: (Character) -> Bool = { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        let goes = addressBar && (a["submit"] as? Bool == true || text.contains(where: newline))
        let shown = goes ? shownPage(run) : nil
        try await typeText(text, r)
        if let field, !text.contains(where: { newline($0) || $0 == "\t" }),
           AX.value(field.element, kAXSubroleAttribute) as? String != "AXSecureTextField" {
            try await readBack(field, text, whole: replace, r)
        }
        if a["submit"] as? Bool == true {
            await Input.sleep(typist.between())
            await closeSuggestions(r.pid, before: "pressing Return", route: r)
            try await press(["Return"], r)
            Connection.current?.work.did.append("pressed Return")
        }
        if goes {
            let address = text.split(whereSeparator: newline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            try await awaitPage(address, before: shown, run, timeout: pageTimeout(a))
        }
    }

    /// Typed text that didn't land as typed (an autocomplete took over, a mask reformatted it, a key was
    /// lost) gets a note; only letters and digits are compared, as fields format the rest. Typing that
    /// went to another window or a pop-up instead is an error: the batch stops before a Return.
    static func readBack(_ field: AX.Node, _ text: String, whole: Bool, _ r: Route) async throws {
        func plain(_ s: String) -> String {
            String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        }
        let want = plain(text)
        guard !want.isEmpty else { return }
        var shows = ""
        for i in 0..<7 {  // a web page updates its fields a moment later
            if i > 0 { try await Run.pause(0.05) }
            shows = AX.value(field.element, kAXValueAttribute) as? String ?? ""
            if whole ? plain(shows) == want : plain(shows).contains(want) { return }
        }
        let typed = "\"\(AX.clip(text, 60))\""
        if let f = AX.focusedElement(pid: r.pid), !AX.isInside(f, field.element) {
            if !AX.isInWindow(f, r.wid) {
                throw HelperError("the typing went to \(AX.describe(f)), which took the focus from the field: look before going on")
            }
            if AX.isTextInput(f) {  // the page moves it on (a code box per digit)
                notes.append("the focus moved on to \(AX.describe(f)) while typing \(typed): look before typing more")
                return
            }
        }
        notes.append(plain(shows).isEmpty
            ? "the field shows nothing after typing \(typed); some editors keep their text elsewhere, so look before typing it again"
            : "the field shows \"\(AX.clip(shows, 60))\" after typing \(typed): look before typing it again")
    }

    /// fill {fields: [{element|x,y, text} | {element, option} | {element, checked}], submit}
    static func fill(_ a: [String: Any], _ run: Run) async throws {
        guard let fields = a["fields"] as? [[String: Any]], !fields.isEmpty else {
            throw HelperError("fill needs fields: [{element: 3, text: \"Ada\"}, {element: 5, option: \"Blue\"}, …]")
        }
        // The fill's own clicks carry its confirm (the user OK'd the form as a whole).
        let ok = a["confirm"] as? Bool == true
        func confirmed(_ d: [String: Any]) -> [String: Any] {
            var d = d
            if ok { d["confirm"] = true }
            return d
        }
        var submitClick: [String: Any]?
        if let submit = a["submit"] {
            if CFGetTypeID(submit as CFTypeRef) != CFBooleanGetTypeID(), let idx = num(submit) {  // an element (JSON 1 isn't true)
                submitClick = ["type": "click", "element": idx]
            } else if submit is String {  // the button's text
                submitClick = ["type": "click", "target": submit]
            } else if let spec = submit as? [String: Any] {  // {target, …} or a macro's {target, x, y, units}
                submitClick = spec.merging(["type": "click"]) { _, new in new }
            }
        }
        // What needs the user's OK is found before anything is filled in, so a stop leaves the form as it was.
        let app = pid(run.target) ?? run.pidAtStart
        for (i, f) in fields.enumerated() {
            do {
                if let option = f["option"] ?? f["select"] {
                    if let n = try elementNode(f, run.target), let match = AX.optionTitle(n.element, "\(option)") {
                        try Policy.checkItem(a, match)
                    }
                } else if let want = f["checked"] as? Bool, let n = try elementNode(f, run.target),
                          let v = AX.value(n.element, kAXValueAttribute) as? NSNumber, (v.intValue != 0) != want {
                    try Policy.checkPress(a, node: n, at: nil, pid: app)
                }
            } catch let stop as Policy.NeedsOK {
                throw stop
            } catch {
                throw HelperError("field \(i + 1): \(error)")
            }
        }
        if let click = submitClick, click["element"] != nil || click["target"] != nil, let n = try? elementNode(click, run.target) {
            try Policy.checkPress(a, node: n, at: nil, pid: app)
        } else if a["submit"] as? Bool == true {
            let last = fields.last.flatMap { try? elementNode($0, run.target) }
            try Policy.checkFocusKeys(a, [["return"]], try route(run.target, at: nil, foreground: run.foreground),
                                      textArea: last.map { $0.role == "AXTextArea" })
        }
        // A stop found only as it goes (an option's real title, a label read at the click) comes after
        // some fields were filled: it says so.
        func partway(_ stop: Policy.NeedsOK, _ what: String, filled: Int) -> Error {
            filled == 0 ? stop : HelperError("\(what): \(stop); fields 1-\(filled) were filled in already. Ask the user; "
                + "if they agree, repeat the fill with \"confirm\": true")
        }
        Connection.current?.work.fields = (0, fields.count)
        for (i, f) in fields.enumerated() {
            if i > 0 {
                await Input.sleep(typist.between())
                await closeSuggestions(app, before: "field \(i + 1)", route: try? route(run.target, at: nil, foreground: run.foreground))
            }
            Connection.current?.work.typed = 0
            do {
                if let option = f["option"] ?? f["select"] {
                    var s = confirmed(f)
                    s["type"] = "select"
                    s["option"] = option
                    try await perform(s, run)
                } else if let checked = f["checked"] as? Bool {
                    try await setChecked(confirmed(f), checked, run)
                } else if let text = f["text"] as? String ?? f["value"] as? String {
                    var t = f
                    t["clear"] = f["clear"] as? Bool ?? true
                    try await typeInto(t, text, run)
                } else {
                    throw HelperError("give text, option or checked")
                }
            } catch let stop as Policy.NeedsOK {
                throw partway(stop, "field \(i + 1)", filled: i)
            } catch is Cancelled {
                throw Cancelled()
            } catch {
                throw HelperError("field \(i + 1): \(error)")
            }
            Connection.current?.work.fields = (i + 1, fields.count)
            Connection.current?.work.typed = 0
        }
        guard a["submit"] != nil else { return }
        await Input.sleep(typist.between())
        await closeSuggestions(app, before: "submitting", route: try? route(run.target, at: nil, foreground: run.foreground))
        do {
            if let click = submitClick {
                try await perform(confirmed(click), run)
            } else if a["submit"] as? Bool == true {
                try await press(["Return"], try route(run.target, at: nil, foreground: run.foreground))
            }
            Connection.current?.work.did.append("submitted")
        } catch let stop as Policy.NeedsOK {
            throw partway(stop, "submit", filled: fields.count)
        }
    }

    static func setChecked(_ f: [String: Any], _ want: Bool, _ run: Run) async throws {
        guard let n = try elementNode(f, run.target) else { throw HelperError("checked needs element or target") }
        guard let v = AX.value(n.element, kAXValueAttribute) as? NSNumber else { throw HelperError("the \(n.name) isn't a checkbox or switch") }
        if (v.intValue != 0) == want { return }
        var click: [String: Any] = ["type": "click", "_node": n]  // the one just read, not found again
        for k in ["element", "target", "x", "y", "units", "confirm"] { if let v = f[k] { click[k] = v } }
        try await perform(click, run)
    }

    /// select {element, option}: pick an item of a pop-up button, combo box or menu button by its title.
    static func select(_ a: [String: Any], _ run: Run) async throws {
        guard let option = (a["option"] ?? a["value"] ?? a["text"]).map({ "\($0)" }), !option.isEmpty else {
            throw HelperError("select needs option (the item's title)")
        }
        guard let n = try elementNode(a, run.target) else { throw HelperError("select needs element or target") }
        let role = AX.value(n.element, kAXRoleAttribute) as? String ?? ""
        guard ["AXPopUpButton", "AXComboBox", "AXMenuButton"].contains(role) else {
            throw HelperError("that's a \(AX.describe(n.element)), not a pop-up or combo box to select from")
        }
        if let match = AX.optionTitle(n.element, option) { try Policy.checkItem(a, match) }
        let shown = try await reveal(n, aimName(a))  // scrolled to first if it's out of view
        if let c = shown.map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? AX.center(n) {
            await pointer.move(to: c, try route(run.target, at: c, foreground: false))
            pointer.click()
        }
        let chose = try await AX.choose(n.element, option, menuLater: a["_last"] as? Bool == true) { try Policy.checkItem(a, $0) }
        if AX.menuKey(chose) != AX.menuKey(option) { notes.append("selected \"\(chose)\"") }
    }

    /// Whether `AX.choose` looks for its menu only once after the pick, not for 0.4 s: as the batch's last
    /// action (`menuLater`), in a window `act` doesn't wait in full for (`waitsInFull`; nil, not known: it waits).
    nonisolated static func looksOnce(menuLater: Bool, waitsInFull: Bool?) -> Bool { menuLater && waitsInFull == false }

    static let browsers: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", "app.zen-browser.zen", "org.torproject.torbrowser", "com.kagi.kagimacos",
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.brave.browser",
        "com.brave.browser.beta", "com.brave.browser.nightly", "company.thebrowser.browser", "company.thebrowser.dia",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.operasoftware.operagx", "org.chromium.chromium",
        "com.sigmaos.sigmaos.macos", "ai.perplexity.comet", "com.openai.atlas", "net.imput.helium",
    ]

    static func isBrowser(_ pid: pid_t) -> Bool {
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() ?? ""
        return browsers.contains(id)  // not every app embedding Chromium (Spotify, Steam) is a browser
    }

    /// navigate {url, new_window}: go to a web address in a browser window: cmd+l, the address, Return,
    /// then wait for the page to load. In a window the agent didn't open, it opens its own first
    /// (new_window defaults to true there), so the user's tabs are left alone.
    static func navigate(_ a: [String: Any], _ run: Run) async throws {
        guard let url = (a["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            throw HelperError("navigate needs url")
        }
        guard case .window(let w) = run.target, isBrowser(w.pid) else {
            throw HelperError("navigate works in web browsers (to open a URL from elsewhere, use open)")
        }
        var r = try route(run.target, at: nil, foreground: run.foreground)
        if a["new_window"] as? Bool ?? !agentWindows.contains(w.id) {
            try await press(["cmd", "n"], r)
            guard let nw = try await run.newWindow(pid: w.pid, timeout: 4) else { throw HelperError("cmd+n opened no new window") }
            agentWindows.insert(nw.id)
            try await run.moveTo(nw, note: "opened its own window #\(nw.id)")
            r = try route(run.target, at: nil, foreground: run.foreground)
            // It focuses its address bar: go on once it has (cmd+l needs the keyboard in it, and the address is
            // pasted only into an address bar), or after 0.6 s anyway.
            _ = try await Run.pollUntil(floor: 0.05, every: 0.04, cap: 0.6) { readyForAddress(pid: nw.pid, wid: nw.id) }
        }
        try await press(["cmd", "l"], r)
        await Input.sleep(typist.between())
        try await typeText(url, r)
        await Input.sleep(typist.between())
        let before = shownPage(run)
        try await press(["Return"], r)
        try await awaitPage(url, before: before, run, timeout: pageTimeout(a))
    }

    /// A browser window ready for an address: the app's key window, with its focus on a text input in it
    /// (a new window focuses its address bar).
    static func readyForAddress(pid: pid_t, wid: CGWindowID) -> Bool {
        guard AX.focusedWindow(pid: pid) == wid, let f = AX.focusedElement(pid: pid) else { return false }
        return AX.isInWindow(f, wid) && AX.isTextInput(f)
    }

    /// How long to wait for a page to load after a Return in the address bar (timeout_ms, ≤ 30 s).
    static func pageTimeout(_ a: [String: Any]) -> Double { min(max(num(a["timeout_ms"]) ?? 10000, 0), 30000) / 1000 }

    /// What a browser window shows: its page's address and its title (nil if neither can be read).
    static func shownPage(_ run: Run) -> [String?]? {
        guard case .window(let now) = run.target else { return nil }
        let s = [AX.pageURL(pid: now.pid, wid: now.id), Windows.info(now.id)?.title]
        return s.allSatisfy { $0 == nil } ? nil : s
    }

    /// After the Return that goes to `url` from the address bar: wait for the page to load, with a note when
    /// it hasn't, or when the window still shows the page it showed `before` (Return didn't take).
    static func awaitPage(_ url: String, before: [String?]?, _ run: Run, timeout: Double) async throws {
        if case .window(let now) = run.target,
           !(try await AX.waitForPage(pid: now.pid, wid: now.id, timeout: timeout, first: firstPagePause(before, url))) {
            notes.append("the page was still loading after \(Int(timeout)) s")
        } else if let before, !sameAddress(before[0], url), case .window(let now) = run.target {
            // "Loaded" may be the old page: Firefox keeps it, loaded and idle, until the new one answers.
            let until = Date().addingTimeInterval(timeout)
            var shown = shownPage(run)
            while shown.map({ $0 == before }) == true, Date() < until {
                try await Run.pause(0.1)
                shown = shownPage(run)
            }
            if shown.map({ $0 == before }) == true {
                notes.append("the window still shows \"\(AX.clip((before[0] ?? before[1]) ?? "", 60))\" \(Int(timeout)) s after "
                    + "Return: the page may still be loading, or Return didn't reach the address bar. Look before navigating again")
            } else if until.timeIntervalSinceNow > 0.5,
                      !(try await AX.waitForPage(pid: now.pid, wid: now.id, timeout: until.timeIntervalSinceNow,
                                                 first: secondPagePause(before, shown))) {
                notes.append("the page was still loading after \(Int(timeout)) s")
            }
        }
    }

    /// The pause before the first look at whether the page has loaded. When what the window showed is known
    /// and the typed address isn't its own, a short one: the wait for the window to change (above) keeps the
    /// old page from passing for the new one. Otherwise (the same address, or nothing to compare) 0.4 s.
    static func firstPagePause(_ before: [String?]?, _ url: String) -> Double {
        if let before, !sameAddress(before[0], url) { return 0.1 }
        return 0.4
    }

    /// The pause before the look once the window shows something else: none when its page's address has
    /// changed (the new page is in place), 0.4 s when only its title has.
    static func secondPagePause(_ before: [String?], _ now: [String?]?) -> Double {
        if let u = now?[0], u != before[0] { return 0 }
        return 0.4
    }

    /// Whether a page's address is the one typed (so it's not expected to change): scheme, "www." and a
    /// trailing slash aside.
    static func sameAddress(_ shown: String?, _ typed: String) -> Bool {
        func bare(_ s: String) -> String {
            var s = s.lowercased()
            for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
            if s.hasPrefix("www.") { s.removeFirst(4) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return shown.map { bare($0) == bare(typed) } ?? false
    }

    /// open {url | path, app}: open a web address, file or app the way a double-click would, without
    /// bringing it to the front. Only http(s) and mailto links and documents: nothing that runs code.
    static func open(_ a: [String: Any], _ run: Run) async throws {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        let appName = (a["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var appURL: URL?
        if let appName {
            appURL = Windows.appURL(appName) ?? Windows.runningApp(appName)?.bundleURL
            guard appURL != nil else { throw HelperError("app not found: \(appName)") }
        }
        let opened: NSRunningApplication
        var what: String
        if let s = (a["url"] ?? a["path"] ?? a["file"]) as? String, !s.isEmpty {
            let u = try openable(s)
            // A terminal or script runner given the document would run it, whatever its name.
            if let appURL, let id = Bundle(url: appURL)?.bundleIdentifier?.lowercased(), runners.contains(id) || runnerApps.contains(id) {
                throw HelperError("won't open \(u.lastPathComponent) with \(appURL.deletingPathExtension().lastPathComponent): it could run it")
            }
            what = u.isFileURL ? u.lastPathComponent : u.absoluteString
            try Connection.check()
            if let appURL {
                opened = try await NSWorkspace.shared.open([u], withApplicationAt: appURL, configuration: cfg)
            } else {
                opened = try await NSWorkspace.shared.open(u, configuration: cfg)
            }
        } else if let appURL {
            what = appURL.deletingPathExtension().lastPathComponent
            try Connection.check()
            opened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        } else {
            throw HelperError("open needs url, path or app")
        }
        let name = opened.localizedName ?? "the app"
        let did = what == name || appURL != nil && a["url"] == nil && a["path"] == nil && a["file"] == nil
            ? "opened \(name)" : "opened \(what) in \(name)"
        if let nw = try await run.newWindow(pid: opened.processIdentifier, timeout: 6) {
            agentWindows.insert(nw.id)
            try await run.moveTo(nw, note: "\(did): now on its window #\(nw.id)")
        } else {
            notes.append("\(did); no new window appeared (windows lists the ones it has)")
        }
    }

    static let runnable: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "terminal", "scpt", "scptd",
        "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "iso", "jar", "mobileconfig", "prefpane",
        "saver", "kext", "plugin", "bundle", "osax", "fileloc", "webloc", "inetloc", "py", "pyw", "rb", "pl",
        "php", "lua", "tcl", "shortcut", "appex", "systemextension", "dext", "qlgenerator", "mdimporter",
        "alfredworkflow", "ipa", "xpc", "textclipping", "service",
    ]
    /// Apps that run what they open, beyond the default handlers in `runners`.
    static let runnerApps: Set<String> = [
        "dev.warp.warp-stable", "com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "com.apple.automator", "com.apple.scripteditor2", "com.apple.shortcuts", "com.runningwithcrayons.alfred",
        "com.apple.archiveutility", "com.apple.systemevents",
    ]
    static let runners: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.apple.installer", "org.python.pythonlauncher",
        "com.apple.systempreferences", "com.apple.automator.runner", "com.apple.shortcuts", "com.apple.scripteditor2",
    ]

    /// A URL `open` may hand to the system, or why not.
    static func openable(_ s: String) throws -> URL {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            guard let u = URL(string: s) else { throw HelperError("bad URL: \(s)") }
            return u
        }
        if !lower.hasPrefix("file:"), !s.hasPrefix("/"), !s.hasPrefix("~"), let colon = s.firstIndex(of: ":") {
            throw HelperError("open takes http(s) and mailto links and files, not \(s[..<colon]): links (they can make other apps act)")
        }
        let path = lower.hasPrefix("file:") ? (URL(string: s)?.path ?? "") : (s as NSString).expandingTildeInPath
        let u = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw HelperError("no such file: \(u.path)") }
        let handler = NSWorkspace.shared.urlForApplication(toOpen: u).flatMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() }
        if runnable.contains(u.pathExtension.lowercased()) || (!isDir.boolValue && FileManager.default.isExecutableFile(atPath: u.path))
            || handler.map(runners.contains) == true {
            throw HelperError("won't open \(u.lastPathComponent): opening it could run code or change settings; ask the user to")
        }
        return u
    }

    /// wait_for {text, role, gone, timeout_ms}: until an element showing `text` (and of `role`) is in
    /// the batch's window, what's open over it, or a window that appeared since the batch began (not the
    /// app's other windows: they may be the user's), or with gone=true until none is.
    /// wait_for {change: true, timeout_ms}: see `waitForChange`.
    static func waitFor(_ a: [String: Any], _ run: Run) async throws {
        guard case .window(let w) = run.target else { throw HelperError("wait_for needs a window target") }
        let q = a["text"] as? String ?? a["label"] as? String ?? ""
        let role = (a["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ms = num(a["timeout_ms"] ?? a["ms"]) ?? 5000
        guard (0...30000).contains(ms) else { throw HelperError("wait_for's timeout_ms is 0-30000") }
        let timeout = ms / 1000
        if waitsForChange(a) {
            guard q.isEmpty, role == nil, a["gone"] as? Bool != true else {
                throw HelperError("wait_for takes change: true or text (and/or role), not both")
            }
            return try await waitForChange(timeout, run)
        }
        guard !q.isEmpty || role != nil else { throw HelperError("wait_for needs text (and/or role), or change: true") }
        let gone = a["gone"] as? Bool == true
        let start = Date()
        let what = (role.map { "\($0) " } ?? "") + (q.isEmpty ? "" : "\"\(q)\"")
        // An app with nothing in its accessibility tree (a canvas, a game): watch the pixels instead.
        let byEye = !q.isEmpty && AX.search(pid: w.pid, windows: waitScope(w, run), query: "", limit: 1, budget: 0.5).isEmpty
        while true {
            let found = byEye ? !((try? await ocrFind(q, run.target)) ?? []).isEmpty
                : !AX.search(pid: w.pid, windows: waitScope(w, run), query: q, role: role, limit: 1, budget: 1).isEmpty
            let waited = Date().timeIntervalSince(start)
            if found != gone {
                if waited > 0.5 { notes.append("\(what) \(gone ? "went away" : "appeared") after \(String(format: "%.1f", waited)) s") }
                return
            }
            if waited >= timeout {
                throw HelperError("wait_for: \(gone ? "still showing" : "no") \(what) after \(String(format: "%.1f", timeout)) s")
            }
            try await Run.pause(0.15)
        }
    }

    /// Where wait_for looks for text: window `w`, what's open over it, and the app's windows on screen now
    /// that weren't when the batch began.
    static func waitScope(_ w: WinInfo, _ run: Run) -> Set<CGWindowID> {
        waitScope(w.id, over: openOver(w), shown: Windows.all(onScreenOnly: true).filter { $0.pid == w.pid },
                  atStart: run.visibleBefore) { systemWindow($0, AX.window(pid: $0.pid, wid: $0.id)) }
    }

    /// Not macOS's own windows shown in the app's name (`system`: the dictation orb).
    nonisolated static func waitScope(_ target: CGWindowID, over: [CGWindowID], shown: [WinInfo],
                                      atStart: Set<CGWindowID>, system: (WinInfo) -> Bool) -> Set<CGWindowID> {
        Set([target] + over + shown.filter { !atStart.contains($0.id) && !system($0) }.map(\.id))
    }

    nonisolated static func waitsForChange(_ a: [String: Any]) -> Bool {
        ["wait_for", "waitfor"].contains(kind(a)) && a["change"] as? Bool == true
    }

    /// The keys wait_for takes. It also reads `label` and `ms` (older names), and every action may have
    /// `type`/`action`, `confirm` and puter-use's own "_" keys.
    nonisolated static let waitForKeys = ["text", "role", "gone", "change", "timeout_ms"]

    /// Why action `a` can't run as given, or nil: a wait_for with a key it doesn't read, which would otherwise
    /// be ignored without a word (`timeout` for `timeout_ms` waited the default 5 s). Only wait_for: other
    /// actions read their keys in many places, under the OpenAI and Anthropic names too, so no list of them
    /// is kept to check against.
    nonisolated static func unknownKeys(_ a: [String: Any]) -> String? {
        guard ["wait_for", "waitfor"].contains(kind(a)) else { return nil }
        let known = Set(waitForKeys + ["label", "ms", "type", "action", "confirm"])
        let bad = a.keys.filter { !known.contains($0) && !$0.hasPrefix("_") }.sorted()
        guard !bad.isEmpty else { return nil }
        let named = bad.map { k in "\"\(k)\"" + (closest(k, waitForKeys).map { " (did you mean \($0)?)" } ?? "") }
        return "has \(bad.count == 1 ? "an unknown key" : "unknown keys") \(named.joined(separator: ", ")): wait_for takes "
            + waitForKeys.joined(separator: ", ")
    }

    /// The one of `names` that `key` most likely meant, if any is close: the same but for case and "_"/"-"
    /// (timeoutMs), the same first four letters (timeout, changed), or a typo or two (txt).
    nonisolated static func closest(_ key: String, _ names: [String]) -> String? {
        let meant = ["target": "text", "query": "text", "seconds": "timeout_ms", "wait": "timeout_ms"]
        func plain(_ s: String) -> String { s.lowercased().filter { $0 != "_" && $0 != "-" } }
        let k = plain(key)
        if let m = meant[k], names.contains(m) { return m }
        if let n = names.first(where: { plain($0) == k }) { return n }
        if k.count >= 4, let n = names.first(where: { plain($0).commonPrefix(with: k).count >= 4 }) { return n }
        func distance(_ a: String, _ b: String) -> Int {  // edits from one to the other (Levenshtein)
            let b = Array(b)
            var row = Array(0...b.count)
            for (i, ca) in a.enumerated() {
                var prev = row[0]
                row[0] = i + 1
                for (j, cb) in b.enumerated() {
                    let cur = row[j + 1]
                    row[j + 1] = min(cur + 1, row[j] + 1, prev + (ca == cb ? 0 : 1))
                    prev = cur
                }
            }
            return row[b.count]
        }
        return names.map { ($0, distance(plain($0), k)) }.filter { $0.1 <= 2 && $0.1 < k.count }.min { $0.1 < $1.1 }?.0
    }

    /// The window as wait_for {change} compares it: the same capture size whatever the call's options.
    static func changeLook(_ t: Target) async throws -> Signature {
        Signature(try await plan(t, region: nil, Opts([:])).run().image)
    }

    /// How much of the window (a fraction of its signature's cells) has to look different for wait_for
    /// {change}: a page or list redrawn, a dialog. A caret, a spinner, a focus ring, a line of status text
    /// or a browser's loading signs (its tab spinner, Stop button, "Waiting for…" line) stay under it.
    nonisolated static let changeThreshold = 0.01

    nonisolated static func changed(from base: Signature, to now: Signature) -> Bool {
        guard let d = base.diff(now, outW: now.w, outH: now.h) else { return false }
        return d.fraction > changeThreshold
    }

    /// What ended a wait_for {change}: the window's picture, or a window (it closed, one opened, or the
    /// batch is on another window by now).
    enum ChangeSeen: Equatable { case picture, window }

    /// wait_for {change: true}: until the window looks different from the start of the batch (so a change
    /// that began during an earlier action counts), or a window opens or it closes; then, for a change in
    /// the picture, until it settles. Nothing in time is a note, not an error: the batch goes on.
    static func waitForChange(_ timeout: Double, _ run: Run) async throws {
        guard case .window(let w) = run.target else { throw HelperError("wait_for needs a window target") }
        guard let base = run.changeBase else {
            throw HelperError("wait_for: the window couldn't be captured when the batch began, so there's nothing to compare with")
        }
        let clock = { ProcessInfo.processInfo.systemUptime }
        let start = clock()
        var shotPlan: CapturePlan?, madeFor: PlanBasis?
        let seen = try await awaitChange(
            from: base.wid == w.id ? base.sig : nil, timeout: timeout,
            look: {
                // A new plan when something opens over the window or it moves (as for act's screenshot).
                let now = PlanBasis.of(run.target)
                if shotPlan == nil || now != madeFor {
                    (shotPlan, madeFor) = (try? await Handlers.plan(run.target, region: nil, Opts([:])), now)
                }
                let sig = (try? await shotPlan?.run()).map { Signature($0.image) }
                if Trace.on, let sig { Trace.log(["k": "change", "fraction": base.sig.diff(sig, outW: sig.w, outH: sig.h)?.fraction ?? 0]) }
                return sig
            },
            window: { Windows.info(w.id)?.onScreen != true || !newWindows(w, run).isEmpty },
            pause: { try await Run.pause(0.15) }, clock: clock)
        guard let seen else {
            notes.append("wait_for: no visible change within \(String(format: "%.1f", timeout)) s (a spinner or a line of "
                + "text doesn't count)")
            return
        }
        let after = String(format: "%.1f", seen.after)
        guard seen.seen == .picture else {
            if base.wid != w.id { return }  // the batch moved to a window it opened (and said so)
            notes.append(Windows.info(w.id)?.onScreen != true ? "the window closed after \(after) s" : "a new window opened")
            return
        }
        do {
            _ = try await settle(basis: { PlanBasis.of(run.target) }, makePlan: { try await Handlers.plan(run.target, region: nil, Opts([:])) },
                                 capture: { try await $0.run() }, pause: { try await Run.pause(0.15) })
        } catch let e as Cancelled { throw e } catch {}  // gone meanwhile: nothing left to settle
        notes.append("the window changed after \(after) s (settled at \(String(format: "%.1f", clock() - start)) s)")
    }

    /// `waitForChange`'s loop, apart from the screen (unit-tested): a look each `pause` until one differs from
    /// `base` by more than `changeThreshold` (no `base`: the batch is on another window, a change in itself),
    /// or `window` says one opened or closed. How long that took, or nil after `timeout` seconds.
    static func awaitChange(from base: Signature?, timeout: Double, look: () async throws -> Signature?,
                            window: () -> Bool, pause: () async throws -> Void,
                            clock: () -> Double) async throws -> (seen: ChangeSeen, after: Double)? {
        let start = clock()
        while true {
            guard let base, !window() else { return (.window, clock() - start) }
            if let now = try await look(), changed(from: base, to: now) { return (.picture, clock() - start) }
            if clock() - start >= timeout { return nil }
            try await pause()
        }
    }

    /// The app's windows that have appeared since the batch began and aren't in `w`'s picture: not a sheet
    /// within it, nor a tooltip or popover.
    static func newWindows(_ w: WinInfo, _ run: Run) -> [WinInfo] {
        appeared(Windows.all(onScreenOnly: true), over: Windows.info(w.id) ?? w, atStart: run.visibleBefore) {
            systemWindow($0, AX.window(pid: $0.pid, wid: $0.id))
        }
    }

    /// Of `wins`, `w`'s app's windows not on screen at `atStart` and not in `w`'s picture (a sheet within it,
    /// a tooltip, a popover), nor macOS's own shown in the app's name (`system`: the dictation orb, which
    /// can open when a text field takes the focus).
    nonisolated static func appeared(_ wins: [WinInfo], over w: WinInfo, atStart: Set<CGWindowID>,
                                     system: (WinInfo) -> Bool) -> [WinInfo] {
        wins.filter {
            $0.pid == w.pid && $0.layer == 0 && !atStart.contains($0.id) && $0.frame.width >= 200
                && $0.frame.height >= 120 && !w.frame.contains($0.frame) && !system($0)
        }
    }
}

extension AX {
    /// Pick `option` in a pop-up button, combo box or menu button through accessibility: its menu is
    /// opened (if its items aren't already readable) and the matching item pressed. Matches exactly,
    /// else by a unique prefix, else a unique substring. `check` sees the title matched before it's
    /// chosen (the policy's say on it). Returns the title picked. `menuLater`: this is the batch's last
    /// action, and the end of the batch looks for a menu left open as long as this would (`Handlers.marked`).
    @MainActor static func choose(_ el: AXUIElement, _ option: String, menuLater: Bool = false,
                                  check: (String) throws -> Void = { _ in }) async throws -> String {
        let role = value(el, kAXRoleAttribute) as? String ?? ""
        let want = menuKey(option)
        if let cur = value(el, kAXValueAttribute) as? String, menuKey(cur) == want { return cur }
        if role == "AXComboBox" {
            // Its options, if it shows them (a list it may have to drop down first).
            let options = await comboOptions(el)
            var pick = option
            if !options.isEmpty {
                var hits = options.filter { menuKey($0) == want }
                if hits.isEmpty { hits = options.filter { menuKey($0).hasPrefix(want) } }
                if hits.isEmpty { hits = options.filter { menuKey($0).contains(want) } }
                guard hits.count == 1 else {
                    let names = (hits.isEmpty ? options : hits).prefix(40).map { "\"\($0)\"" }.joined(separator: ", ")
                    throw HelperError(hits.isEmpty ? "no option \"\(option)\" (options: \(names)); to enter other text, type it"
                                                   : "\"\(option)\" matches several: \(names)")
                }
                pick = hits[0]
            } else if let pid = pidOf(el), Policy.level(pid) == .click {
                // With no options to match, this is typing the text in.
                throw Policy.refusal(pid, .click, doing: "setting a combo box's text")
            }
            try check(pick)
            guard write(el, kAXValueAttribute, pick as CFString) == .success else {
                throw HelperError("it didn't take the value \"\(pick)\"")
            }
            // Confirm, as Return would, so the app acts on the new value. Not in browsers: there a combo
            // box is often a search field, and confirming would submit it.
            var names: CFArray?
            AXUIElementCopyActionNames(el, &names)
            if let pid = pidOf(el), !Handlers.isBrowser(pid), (names as? [String] ?? []).contains(kAXConfirmAction) {
                act(el, kAXConfirmAction)
            }
            if options.isEmpty { Handlers.notes.append("couldn't read its options: set its text to \"\(pick)\"") }
            return pick
        }
        func menu() -> AXUIElement? {
            children(el).first { ["AXMenu", "AXList"].contains(value($0, kAXRoleAttribute) as? String ?? "") }
        }
        func items() -> [(AXUIElement, String)] {
            guard let m = menu() else { return [] }
            return children(m).compactMap { item in
                guard let t = (value(item, kAXTitleAttribute) as? String) ?? (value(item, kAXValueAttribute) as? String),
                      !t.isEmpty else { return nil }
                return (item, t)
            }
        }
        var list = items()
        var opened = false
        if list.isEmpty {
            var names: CFArray?
            AXUIElementCopyActionNames(el, &names)
            let acts = names as? [String] ?? []
            let open = acts.contains(kAXPressAction) ? kAXPressAction : kAXShowMenuAction
            guard acts.isEmpty || acts.contains(open) else { throw HelperError("it has no menu to choose from (\(role.dropFirst(2)))") }
            // Some apps open the menu before replying and only reply once it closes: don't wait on that.
            AXUIElementSetMessagingTimeout(el, 0.6)
            let err = act(el, open)
            AXUIElementSetMessagingTimeout(el, 0)
            guard err == .success || err == .cannotComplete else { throw HelperError("couldn't open its menu (\(err.rawValue))") }
            opened = true
            for _ in 0..<30 {
                await Input.ms(50)
                list = items()
                if !list.isEmpty { break }
            }
        }
        func close() {
            if opened, let m = menu() { cleanup(m, kAXCancelAction) }
        }
        guard !list.isEmpty else {
            close()
            throw HelperError("couldn't read its options")
        }
        var hits = list.filter { menuKey($0.1) == want }
        if hits.isEmpty { hits = list.filter { menuKey($0.1).hasPrefix(want) } }
        if hits.isEmpty { hits = list.filter { menuKey($0.1).contains(want) } }
        guard hits.count == 1 else {
            close()
            let names = (hits.isEmpty ? list : hits).prefix(40).map { "\"\($0.1)\"" }.joined(separator: ", ")
            throw HelperError(hits.isEmpty ? "no option \"\(option)\" (options: \(names))" : "\"\(option)\" matches several: \(names)")
        }
        do { try check(hits[0].1) } catch {
            close()
            throw error
        }
        guard act(hits[0].0, kAXPressAction) == .success else {
            close()
            throw HelperError("couldn't pick \"\(hits[0].1)\" (disabled?)")
        }
        // The item is chosen, but a menu opened through accessibility can stay open (taking the user's
        // typing): close it. As the batch's last action (`menuLater`), the end of the batch looks for one
        // as long and closes it with no note (`pickedFromMenu`), so in a native app it's looked for once
        // here. Not where `act` waits in full (a browser): its first frame there would come sooner.
        if opened, let pid = pidOf(el) {
            let full = windowID(el).flatMap { Windows.info($0) }.map { Handlers.waitsInFull(.window($0)) }
            let once = Handlers.looksOnce(menuLater: menuLater, waitsInFull: full)
            for _ in 0..<8 {  // it may still be on its way up
                if let m = openMenu(pid: pid) {
                    await Input.ms(80)
                    closeMenu(m)
                    break
                }
                if once { break }
                await Input.ms(50)
            }
            if menuLater { Handlers.pickedFromMenu(pid: pid) }
        }
        return hits[0].1
    }

    /// The title of the option `option` would choose, when it can be read without opening anything (for
    /// the confirm policy); else `option` itself.
    static func optionTitle(_ el: AXUIElement, _ option: String) -> String? {
        let want = menuKey(option)
        let titles = children(el).filter { value($0, kAXRoleAttribute) as? String == "AXMenu" }.flatMap { children($0) }
            .compactMap { value($0, kAXTitleAttribute) as? String }.filter { !$0.isEmpty }
        var hits = titles.filter { menuKey($0) == want }
        if hits.isEmpty { hits = titles.filter { menuKey($0).hasPrefix(want) } }
        if hits.isEmpty { hits = titles.filter { menuKey($0).contains(want) } }
        return hits.count == 1 ? hits[0] : option
    }

    /// A combo box's options: from its list, dropping it down for a moment if it has to.
    @MainActor static func comboOptions(_ el: AXUIElement) async -> [String] {
        func read() -> [String] {
            for k in children(el) where ["AXList", "AXTable", "AXScrollArea"].contains(value(k, kAXRoleAttribute) as? String ?? "") {
                var out: [String] = []
                func walk(_ e: AXUIElement, _ depth: Int) {
                    guard depth < 5, out.count < 200 else { return }
                    for c in children(e) {
                        let r = value(c, kAXRoleAttribute) as? String ?? ""
                        if r == "AXStaticText" || r == "AXTextField", let s = (value(c, kAXValueAttribute) as? String) ?? caption(c),
                           !s.isEmpty { out.append(s) } else { walk(c, depth + 1) }
                    }
                }
                walk(k, 0)
                if !out.isEmpty { return out }
            }
            return []
        }
        var found = read()
        if !found.isEmpty { return found }
        let expanded = value(el, kAXExpandedAttribute) as? Bool
        guard expanded == false, write(el, kAXExpandedAttribute, kCFBooleanTrue) == .success
        else { return [] }
        for _ in 0..<10 {
            await Input.ms(40)
            found = read()
            if !found.isEmpty { break }
        }
        cleanup(el, set: kAXExpandedAttribute, kCFBooleanFalse)  // even after a cancel
        return found
    }

    /// After a navigation: true once the window's web page says it has loaded (false on timeout). Pages
    /// that don't say (no AXLoaded) count as loaded; the batch's end settle covers them. The first look
    /// comes after `first` s, then every 0.1 s.
    @MainActor static func waitForPage(pid: pid_t, wid: CGWindowID, timeout: Double, first: Double = 0.4) async throws -> Bool {
        try await Run.pause(min(first, timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let win = window(pid: pid, wid: wid), let page = webArea(win) else { return true }
            if (value(page, "AXLoaded") as? Bool) != false, (value(page, "AXBusy") as? Bool) != true { return true }
            try await Run.pause(0.1)
        }
        return false
    }

    /// The address of the window's (first) web page, if it says.
    static func pageURL(pid: pid_t, wid: CGWindowID) -> String? {
        guard let win = window(pid: pid, wid: wid), let page = webArea(win), let u = value(page, kAXURLAttribute) else { return nil }
        if CFGetTypeID(u) == CFURLGetTypeID() { return (u as! URL).absoluteString }
        return u as? String
    }

    /// The window's (first) web page, looked for breadth-first a few levels down.
    static func webArea(_ win: AXUIElement) -> AXUIElement? {
        var level = [win]
        for _ in 0..<12 {
            var next: [AXUIElement] = []
            for el in level {
                if (value(el, kAXRoleAttribute) as? String) == "AXWebArea" { return el }
                next += children(el)
            }
            if next.isEmpty || next.count > 400 { return nil }
            level = next
        }
        return nil
    }
}
