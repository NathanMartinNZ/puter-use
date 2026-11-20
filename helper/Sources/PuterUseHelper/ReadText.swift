import AppKit
import ApplicationServices

/// `screenshot(read: …)`: the whole text of a text area, text field or document, the parts scrolled
/// out of view too, a page at a time. A look like any other: nothing is pressed, typed or changed, and
/// the clipboard isn't used. Whole web pages aren't read this way (yet).
extension Handlers {
    /// Roles whose value is the text they show.
    nonisolated static let readable: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXStaticText"]

    /// Whether a request's `read` asks for a read (a number, text, a target spec or true; not false).
    nonisolated static func readRequested(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { return (v as? Bool) == true }
        return true
    }

    /// Characters `offset..<offset+limit` of `s`, where that part ends, and how many characters `s` has.
    /// Past the end, the part is empty and ends at `offset`.
    nonisolated static func page(_ s: String, offset: Int, limit: Int) -> (text: String, end: Int, total: Int) {
        let total = s.count
        guard offset < total else { return ("", offset, total) }
        let part = String(s.dropFirst(offset).prefix(limit))
        return (part, offset + part.count, total)
    }

    /// How a read names what it read: `[12] textarea "Notes"`.
    nonisolated static func readName(_ id: Int, _ name: String, _ label: String?) -> String {
        "[\(id)] \(name == "web" ? "web area" : name)" + (label.map { " \"\(AX.clip($0, 40))\"" } ?? "")
    }

    /// `read`: the element's text from `offset` (`limit` characters, as `clipboard` pages), with what it
    /// is and where that part is in the whole: `read_range` = [offset, end, total].
    static func readText(_ t: Target, _ what: Any, _ p: [String: Any]) throws -> [String: Any] {
        guard case .window(let w) = t else { throw HelperError("read needs a window, not the screen") }
        let (id, n) = try readTarget(what, w, t)
        let role = AX.value(n.element, kAXRoleAttribute) as? String ?? n.role
        let label = role == "AXStaticText" ? AX.value(n.element, kAXValueAttribute) as? String : AX.label(n.element)
        let it = readName(id, n.name, label.flatMap { $0.isEmpty ? nil : $0 })
        if role == "AXWebArea" {
            throw HelperError("\(it): reading a whole web page isn't supported yet. Scroll and look, or read part of "
                + "it with region and image=false")
        }
        if Policy.isSecure(n.element) { throw HelperError("not allowed: \(it) is a password field") }
        guard readable.contains(role) else {
            throw HelperError("\(it) has no text to read: read takes a text area, text field or document (its number "
                + "or what it shows), or true for the focused one")
        }
        guard let s = AX.value(n.element, kAXValueAttribute) as? String else {
            throw HelperError("\(it) doesn't give its text to accessibility: read what's shown with region and image=false")
        }
        let offset = max(0, int(p["offset"], 0))
        let limit = min(max(1, int(p["limit"], Clipboard.readLimit)), Clipboard.maxRead)
        let part = page(s, offset: offset, limit: limit)
        return ["window": describe(t), "read": part.text, "read_of": it, "read_range": [offset, part.end, part.total]]
    }

    /// The element `what` names in `w`: a number, what it shows (as `target`), or true for the focused text.
    static func readTarget(_ what: Any, _ w: WinInfo, _ t: Target) throws -> (Int, AX.Node) {
        if CFGetTypeID(what as CFTypeRef) == CFBooleanGetTypeID() { return try readFocused(w, t) }
        if let n = what as? NSNumber { return (n.intValue, try numbered(w, n.intValue, t)) }
        if let s = what as? String, let idx = Int(s.trimmingCharacters(in: .whitespaces)) {
            return (idx, try numbered(w, idx, t))
        }
        do { return try findOne(what, t) } catch let e as NotFound { throw try missError(e, what, t) }  // as a target's miss
    }

    /// The text that has the keyboard focus in `w` (or in what's open over it); else the window's only
    /// text area. Otherwise it fails, listing the text areas and fields to choose from.
    static func readFocused(_ w: WinInfo, _ t: Target) throws -> (Int, AX.Node) {
        if let f = AX.value(AX.appElement(w.pid), kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            let role = AX.value(el, kAXRoleAttribute) as? String ?? ""
            if readable.contains(role) || role == "AXWebArea", let wid = AX.windowID(el), wid == w.id || openOver(w).contains(wid) {
                var name = AX.roleNames[role] ?? String(role.dropFirst(2)).lowercased()
                switch AX.value(el, kAXSubroleAttribute) as? String {
                case "AXSearchField": name = "search"
                case "AXSecureTextField": name = "password"
                default: break
                }
                let id = AX.registry(w.id).number(AX.Node(element: el, frame: AX.frame(el), role: role,
                                                          label: role == "AXStaticText" ? nil : AX.label(el), name: name))
                return (id, try AX.node(w.id, id))
            }
        }
        let areas = AX.search(pid: w.pid, windows: [w.id], query: "", role: "textarea", limit: 10)
        if areas.count == 1 {
            let id = number(areas[0], w.id)
            return (id, try AX.node(w.id, id))
        }
        let all = areas + AX.search(pid: w.pid, windows: [w.id], query: "", role: "field", limit: 10)
        let list = all.prefix(8).map { describe($0, id: number($0, w.id), t) }
        throw HelperError("read: true reads the focused text, and the keyboard focus isn't on text in this window. "
            + (list.isEmpty ? "The window shows no text areas or fields: name what to read by its number or what it shows"
                : "Name what to read by its number or what it shows: " + list.joined(separator: "; ")
                    + (all.count > 8 ? "; and \(all.count - 8) more" : "")))
    }
}
