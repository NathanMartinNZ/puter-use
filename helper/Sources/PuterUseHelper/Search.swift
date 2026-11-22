import AppKit
import ApplicationServices

/// Finding elements by what they say, across the app's visible windows (its dialogs and sheets too).
extension AX {
    struct Match {
        let element: AXUIElement
        let role: String  // outline name: "button", "field", "text", …
        let label: String  // the text that matched (title, description, value, placeholder, or the text titling it)
        let frame: CGRect?
        let exact: Bool  // the whole label equals the query
        var offScreen = false  // outside its window (scrolled out of view): found by an off-screen search
    }

    /// Role names an agent might use for the outline's names.
    static func roleKey(_ r: String) -> String {
        let k = r.lowercased().replacingOccurrences(of: "ax", with: "", options: .anchored)
        return ["textfield": "field", "input": "field", "textbox": "field", "searchfield": "search",
                "statictext": "text", "label": "text", "dropdown": "popup", "select": "popup",
                "popupbutton": "popup", "menubutton": "menubutton", "radiobutton": "radio",
                "toggle": "switch", "image": "image",
                // The accessibility names of the roles the outline calls by a shorter word.
                "busyindicator": "busy", "relevanceindicator": "relevance", "timefield": "time", "helptag": "tooltip",
                "rulermarker": "marker", "genericelement": "generic"][k] ?? k
    }

    static let leaves: Set<String> = [
        "AXStaticText", "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox", "AXTab", "AXSlider", "AXImage",
    ]

    /// Visible elements whose label or value contains `query` (case-insensitive; "" matches any), optionally
    /// of one `role`, in reading order. `windows` limits the search; nil = all the app's on-screen windows.
    static func search(pid: pid_t, windows wids: Set<CGWindowID>? = nil, query: String, role: String? = nil,
                       limit: Int = 50, budget: TimeInterval = 1.5) -> [Match] {
        searchAll(pid: pid, windows: wids, query: query, role: role, limit: limit, budget: budget).matches
    }

    /// `search`, and whether it looked at everything (not when it ran out of time or reached `limit`).
    /// `offScreen`: instead, only elements outside their window (scrolled out of view, or kept off screen),
    /// which `search` skips; this walks the whole tree, so it's run only when it's needed. `near` collects
    /// the elements on the way that don't show the text but are near it (see `Near`).
    static func searchAll(pid: pid_t, windows wids: Set<CGWindowID>? = nil, query: String, role: String? = nil,
                          limit: Int = 50, budget: TimeInterval = 1.5, offScreen: Bool = false,
                          near: Near? = nil) -> (matches: [Match], complete: Bool) {
        guard let wins = value(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] else { return ([], true) }
        var roots: [(AXUIElement, CGRect)] = []
        for win in wins {
            var id: CGWindowID = 0
            if let wids, _AXUIElementGetWindow(win, &id) != .success || !wids.contains(id) { continue }
            guard let wf = frame(win), wf.width > 0 else { continue }
            roots.append((win, wf))
        }
        return search(in: roots, menus: menuWindows(pid), query: query, role: role, limit: limit, budget: budget,
                      offScreen: offScreen, near: near)
    }

    /// `searchAll` over window elements `roots` (with their frames), the app's open menus at `menus`.
    /// `now` and `read` are there for tests.
    static func search(in roots: [(AXUIElement, CGRect)], menus: [CGRect], query: String, role: String?, limit: Int,
                       budget: TimeInterval, offScreen: Bool, near: Near? = nil, now: () -> TimeInterval = uptime,
                       read: (AXUIElement) -> [AnyObject]? = readAttrs) -> (matches: [Match], complete: Bool) {
        let end = now() + budget
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // A label that's the query but for case, spacing and "..." vs "…" (`menuKey`) is the same label: a whole-
        // label match. (Only short texts can be: no long value is normalised.) `low`: a text in lower case.
        let key = menuKey(query), most = key.utf16.count * 3 + 20
        func same(_ low: String) -> Bool { low.utf16.count <= most && (ownKey(low) ? low : menuKey(low)) == key }
        func shows(_ s: String) -> Bool {
            if q.isEmpty { return !s.isEmpty }
            let low = s.lowercased()
            return low.contains(q) || same(low)
        }
        func whole(_ s: String) -> Bool {
            let low = s.lowercased()
            return low.trimmingCharacters(in: .whitespaces) == q || same(low)
        }
        let wantRole = role.map(roleKey)
        var out: [Match] = []
        var cut = false
        var said: [AXUIElement: String] = [:]  // the texts walked, and what they say: a label is met before its field
        for (win, wf) in roots {
            let visible = wf.insetBy(dx: -2, dy: -2)
            // `outside`: something it's in is outside the window (`search` skips all of that). `view`: the part of the
            // screen it can be seen in, its window clipped to the scroll areas and web pages it's in (as `AX.sight`
            // says); `hidden`: something it's in is scrolled out of that view though inside the window (a list's rows
            // above its visible part): found by `search`, but tagged off screen.
            func walk(_ el: AXUIElement, depth: Int, outside: Bool, view: CGRect = wf, hidden: Bool = false) {
                guard depth < 60, !cut else { return }
                if out.count >= limit || now() >= end { cut = true; return }
                guard let vals = read(el) else { return }
                let r = vals[0] as? String ?? ""
                if r == "AXColumn" { return }
                var rect: CGRect?
                var pt = CGPoint.zero, sz = CGSize.zero
                if CFGetTypeID(vals[6]) == AXValueGetTypeID(), CFGetTypeID(vals[7]) == AXValueGetTypeID(),
                   AXValueGetValue(vals[6] as! AXValue, .cgPoint, &pt), AXValueGetValue(vals[7] as! AXValue, .cgSize, &sz) {
                    rect = CGRect(origin: pt, size: sz)
                }
                var away = outside
                if let rr = rect, rr.width > 0, rr.height > 0, !rr.intersects(visible), r != "AXWindow" {
                    if !offScreen { return }
                    away = true
                }
                // In the window but scrolled out of the view it's in: not shown well enough to see or act on.
                var clipped = hidden
                if !away, !clipped, let rr = rect, r != "AXWindow", view != wf {
                    clipped = Handlers.offScreen(Sight(frame: rr, view: view))
                }
                if r == "AXMenu", !menuOpen(rect, menus) { return }  // a pop-up's menu, closed
                let subrole = vals[1] as? String
                var name = roleNames[r] ?? String(r.dropFirst(2)).lowercased()
                if subrole == "AXSearchField" { name = "search" }
                if subrole == "AXSecureTextField" { name = "password" }
                if subrole == "AXTabButton" { name = "tab" }
                var texts = [2, 3].compactMap { vals[$0] as? String }
                if r == "AXStaticText", let s = textSays(vals), !s.allSatisfy(\.isWhitespace) { said[el] = s }
                // A control with no name of its own goes by what titles it (a form's "Email" beside its field), so a
                // target naming the label finds the field too, and the field comes before the label (`narrowed`).
                if texts.allSatisfy(\.isEmpty), r != "AXStaticText", r != "AXWindow", !name.isEmpty,
                   wantRole == nil || roleKey(name) == wantRole, let te = titleElement(vals), !CFEqual(te, el),
                   let t = said[te] ?? titleText(te, read: read) {
                    texts.append(t)
                }
                texts += [10, 12].compactMap { vals[$0] as? String }
                texts += subrole == "AXSecureTextField" ? [] : [vals[4] as? String].compactMap { $0 }
                if r != "AXWindow", !name.isEmpty, wantRole == nil || roleKey(name) == wantRole,
                   let hit = texts.first(where: shows) ?? (q.isEmpty && wantRole != nil ? "" : nil) {
                    if away == offScreen {
                        out.append(Match(element: el, role: name, label: hit, frame: rect,
                                         exact: whole(hit), offScreen: offScreen || clipped))
                    }
                    if leaves.contains(r) { return }  // its own text children would only repeat it
                } else if let near, r != "AXWindow", !name.isEmpty {
                    near.consider(el, role: name, texts: texts, frame: rect, offScreen: away || clipped)
                }
                var inner = view
                if r == "AXScrollArea" || r == "AXWebArea", let rr = rect, rr.width > 0, rr.height > 0 { inner = view.intersection(rr) }
                for k in vals[5] as? [AXUIElement] ?? [] { walk(k, depth: depth + 1, outside: away, view: inner, hidden: clipped) }
            }
            walk(win, depth: 0, outside: false)
        }
        return (out, !cut)
    }
}
