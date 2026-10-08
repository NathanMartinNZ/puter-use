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
        let start = Date()
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let wantRole = role.map(roleKey)
        var out: [Match] = []
        guard let wins = value(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let menus = menuWindows(pid)
        for win in wins {
            var id: CGWindowID = 0
            if let wids, _AXUIElementGetWindow(win, &id) != .success || !wids.contains(id) { continue }
            guard let wf = frame(win), wf.width > 0 else { continue }
            let visible = wf.insetBy(dx: -2, dy: -2)
            func walk(_ el: AXUIElement, depth: Int) {
                guard depth < 60, out.count < limit, Date().timeIntervalSince(start) < budget else { return }
                var raw: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                      let vals = raw as? [AnyObject], vals.count == attrs.count else { return }
                let r = vals[0] as? String ?? ""
                if r == "AXColumn" { return }
                var rect: CGRect?
                var pt = CGPoint.zero, sz = CGSize.zero
                if CFGetTypeID(vals[6]) == AXValueGetTypeID(), CFGetTypeID(vals[7]) == AXValueGetTypeID(),
                   AXValueGetValue(vals[6] as! AXValue, .cgPoint, &pt), AXValueGetValue(vals[7] as! AXValue, .cgSize, &sz) {
                    rect = CGRect(origin: pt, size: sz)
                }
                if let rr = rect, rr.width > 0, rr.height > 0, !rr.intersects(visible), r != "AXWindow" { return }
                if r == "AXMenu", !menuOpen(rect, menus) { return }  // a pop-up's menu, closed
                let subrole = vals[1] as? String
                var name = roleNames[r] ?? String(r.dropFirst(2)).lowercased()
                if subrole == "AXSearchField" { name = "search" }
                if subrole == "AXSecureTextField" { name = "password" }
                if subrole == "AXTabButton" { name = "tab" }
                let texts = [2, 3, 10, 12].compactMap { vals[$0] as? String }
                    + (subrole == "AXSecureTextField" ? [] : [vals[4] as? String].compactMap { $0 })
                if r != "AXWindow", !name.isEmpty, wantRole == nil || roleKey(name) == wantRole,
                   let hit = texts.first(where: { q.isEmpty ? !$0.isEmpty : $0.lowercased().contains(q) })
                    ?? (q.isEmpty && wantRole != nil ? "" : nil) {
                    out.append(Match(element: el, role: name, label: hit, frame: rect,
                                     exact: hit.lowercased().trimmingCharacters(in: .whitespaces) == q))
                    if leaves.contains(r) { return }  // its own text children would only repeat it
                }
                for k in vals[5] as? [AXUIElement] ?? [] { walk(k, depth: depth + 1) }
            }
            walk(win, depth: 0)
        }
        return out
    }
}
