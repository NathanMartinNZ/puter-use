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
        if field == nil, let f = AX.focusedElement(pid: r.pid), AX.isTextInput(f) {
            let role = AX.value(f, kAXRoleAttribute) as? String ?? ""
            field = AX.Node(element: f, frame: AX.frame(f), role: role, label: AX.label(f), name: AX.roleNames[role] ?? "field")
        }
        let length = field.flatMap { (AX.value($0.element, kAXValueAttribute) as? String).map { ($0 as NSString).length } }
        if a["clear"] as? Bool == true {
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
            await Input.sleep(typist.between())
        } else if let field, let length {  // the click landed mid-text: type after what's there
            AX.select(field.element, CFRange(location: length, length: 0))
        }
        try await typeText(text, r)
        if a["submit"] as? Bool == true {
            await Input.sleep(typist.between())
            try await press(["Return"], r)
        }
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
        for (i, f) in fields.enumerated() {
            if i > 0 { await Input.sleep(typist.between()) }
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
            } catch {
                throw HelperError("field \(i + 1): \(error)")
            }
        }
        guard a["submit"] != nil else { return }
        await Input.sleep(typist.between())
        do {
            if let click = submitClick {
                try await perform(confirmed(click), run)
            } else if a["submit"] as? Bool == true {
                try await press(["Return"], try route(run.target, at: nil, foreground: run.foreground))
            }
        } catch let stop as Policy.NeedsOK {
            throw partway(stop, "submit", filled: fields.count)
        }
    }

    static func setChecked(_ f: [String: Any], _ want: Bool, _ run: Run) async throws {
        guard let n = try elementNode(f, run.target) else { throw HelperError("checked needs element or target") }
        guard let v = AX.value(n.element, kAXValueAttribute) as? NSNumber else { throw HelperError("the \(n.name) isn't a checkbox or switch") }
        if (v.intValue != 0) == want { return }
        var click: [String: Any] = ["type": "click"]
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
        if let c = AX.center(n) {
            await pointer.move(to: c, try route(run.target, at: c, foreground: false))
            pointer.click()
        }
        let chose = try await AX.choose(n.element, option) { try Policy.checkItem(a, $0) }
        if AX.menuKey(chose) != AX.menuKey(option) { notes.append("selected \"\(chose)\"") }
    }

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
            guard let nw = await run.newWindow(pid: w.pid, timeout: 4) else { throw HelperError("cmd+n opened no new window") }
            agentWindows.insert(nw.id)
            try await run.moveTo(nw, note: "opened its own window #\(nw.id)")
            r = try route(run.target, at: nil, foreground: run.foreground)
            await Input.sleep(0.3)  // it focuses its address bar
        }
        try await press(["cmd", "l"], r)
        await Input.sleep(typist.between())
        try await typeText(url, r)
        await Input.sleep(typist.between())
        try await press(["Return"], r)
        let timeout = min(max(num(a["timeout_ms"]) ?? 10000, 0), 30000) / 1000
        if case .window(let now) = run.target, !(await AX.waitForPage(pid: now.pid, wid: now.id, timeout: timeout)) {
            notes.append("the page was still loading after \(Int(timeout)) s")
        }
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
            if let appURL {
                opened = try await NSWorkspace.shared.open([u], withApplicationAt: appURL, configuration: cfg)
            } else {
                opened = try await NSWorkspace.shared.open(u, configuration: cfg)
            }
        } else if let appURL {
            what = appURL.deletingPathExtension().lastPathComponent
            opened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        } else {
            throw HelperError("open needs url, path or app")
        }
        let name = opened.localizedName ?? "the app"
        let did = what == name || appURL != nil && a["url"] == nil && a["path"] == nil && a["file"] == nil
            ? "opened \(name)" : "opened \(what) in \(name)"
        if let nw = await run.newWindow(pid: opened.processIdentifier, timeout: 6) {
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
    /// any of the app's windows, or with gone=true until none is.
    static func waitFor(_ a: [String: Any], _ run: Run) async throws {
        guard case .window(let w) = run.target else { throw HelperError("wait_for needs a window target") }
        let q = a["text"] as? String ?? a["label"] as? String ?? ""
        let role = (a["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard !q.isEmpty || role != nil else { throw HelperError("wait_for needs text (and/or role)") }
        let gone = a["gone"] as? Bool == true
        let ms = num(a["timeout_ms"] ?? a["ms"]) ?? 5000
        guard (0...30000).contains(ms) else { throw HelperError("wait_for's timeout_ms is 0-30000") }
        let timeout = ms / 1000
        let start = Date()
        let what = (role.map { "\($0) " } ?? "") + (q.isEmpty ? "" : "\"\(q)\"")
        // An app with nothing in its accessibility tree (a canvas, a game): watch the pixels instead.
        let byEye = !q.isEmpty && AX.search(pid: w.pid, query: "", limit: 1, budget: 0.5).isEmpty
        while true {
            let found = byEye ? !((try? await ocrFind(q, run.target)) ?? []).isEmpty
                : !AX.search(pid: w.pid, query: q, role: role, limit: 1, budget: 1).isEmpty
            let waited = Date().timeIntervalSince(start)
            if found != gone {
                if waited > 0.5 { notes.append("\(what) \(gone ? "went away" : "appeared") after \(String(format: "%.1f", waited)) s") }
                return
            }
            if waited >= timeout {
                throw HelperError("wait_for: \(gone ? "still showing" : "no") \(what) after \(String(format: "%.1f", timeout)) s")
            }
            await Input.ms(150)
        }
    }
}

extension AX {
    /// Pick `option` in a pop-up button, combo box or menu button through accessibility: its menu is
    /// opened (if its items aren't already readable) and the matching item pressed. Matches exactly,
    /// else by a unique prefix, else a unique substring. `check` sees the title matched before it's
    /// chosen (the policy's say on it). Returns the title picked.
    @MainActor static func choose(_ el: AXUIElement, _ option: String,
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
            guard AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, pick as CFString) == .success else {
                throw HelperError("it didn't take the value \"\(pick)\"")
            }
            // Confirm, as Return would, so the app acts on the new value. Not in browsers: there a combo
            // box is often a search field, and confirming would submit it.
            var names: CFArray?
            AXUIElementCopyActionNames(el, &names)
            if let pid = pidOf(el), !Handlers.isBrowser(pid), (names as? [String] ?? []).contains(kAXConfirmAction) {
                AXUIElementPerformAction(el, kAXConfirmAction as CFString)
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
            let err = AXUIElementPerformAction(el, open as CFString)
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
            if opened, let m = menu() { AXUIElementPerformAction(m, kAXCancelAction as CFString) }
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
        guard AXUIElementPerformAction(hits[0].0, kAXPressAction as CFString) == .success else {
            close()
            throw HelperError("couldn't pick \"\(hits[0].1)\" (disabled?)")
        }
        // The item is chosen, but a menu opened through accessibility can stay open (taking the user's
        // typing): close it.
        if opened, let pid = pidOf(el) {
            for _ in 0..<8 {  // it may still be on its way up
                if let m = openMenu(pid: pid) {
                    await Input.ms(80)
                    closeMenu(m)
                    break
                }
                await Input.ms(50)
            }
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
        guard expanded == false, AXUIElementSetAttributeValue(el, kAXExpandedAttribute as CFString, kCFBooleanTrue) == .success
        else { return [] }
        for _ in 0..<10 {
            await Input.ms(40)
            found = read()
            if !found.isEmpty { break }
        }
        AXUIElementSetAttributeValue(el, kAXExpandedAttribute as CFString, kCFBooleanFalse)
        return found
    }

    /// After a navigation: true once the window's web page says it has loaded (false on timeout). Pages
    /// that don't say (no AXLoaded) count as loaded; the batch's end settle covers them.
    @MainActor static func waitForPage(pid: pid_t, wid: CGWindowID, timeout: Double) async -> Bool {
        await Input.sleep(min(0.4, timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let win = window(pid: pid, wid: wid), let page = webArea(win) else { return true }
            if (value(page, "AXLoaded") as? Bool) != false, (value(page, "AXBusy") as? Bool) != true { return true }
            await Input.ms(200)
        }
        return false
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
