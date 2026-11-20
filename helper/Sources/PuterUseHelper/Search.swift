import AppKit
import ApplicationServices

/// Finding elements by what they say, across the app's visible windows (its dialogs and sheets too).
extension AX {
    struct Match {
        let element: AXUIElement
        let role: String  // outline name: "button", "field", "text", …
        let label: String  // the text that matched (title, description, value or placeholder)
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
                "toggle": "switch", "image": "image"][k] ?? k
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
        for (win, wf) in roots {
            let visible = wf.insetBy(dx: -2, dy: -2)
            // `outside`: something it's in is outside the window (`search` skips all of that).
            func walk(_ el: AXUIElement, depth: Int, outside: Bool) {
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
                if r == "AXMenu", !menuOpen(rect, menus) { return }  // a pop-up's menu, closed
                let subrole = vals[1] as? String
                var name = roleNames[r] ?? String(r.dropFirst(2)).lowercased()
                if subrole == "AXSearchField" { name = "search" }
                if subrole == "AXSecureTextField" { name = "password" }
                if subrole == "AXTabButton" { name = "tab" }
                let texts = [2, 3, 10, 12].compactMap { vals[$0] as? String }
                    + (subrole == "AXSecureTextField" ? [] : [vals[4] as? String].compactMap { $0 })
                if r != "AXWindow", !name.isEmpty, wantRole == nil || roleKey(name) == wantRole,
                   let hit = texts.first(where: shows) ?? (q.isEmpty && wantRole != nil ? "" : nil) {
                    if away == offScreen {
                        out.append(Match(element: el, role: name, label: hit, frame: rect,
                                         exact: whole(hit), offScreen: offScreen))
                    }
                    if leaves.contains(r) { return }  // its own text children would only repeat it
                } else if let near, r != "AXWindow", !name.isEmpty {
                    near.consider(el, role: name, texts: texts, frame: rect, offScreen: away)
                }
                for k in vals[5] as? [AXUIElement] ?? [] { walk(k, depth: depth + 1, outside: away) }
            }
            walk(win, depth: 0, outside: false)
        }
        return (out, !cut)
    }
}
