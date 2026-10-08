import AppKit
import ApplicationServices

/// Macros: a batch that worked, saved under a name (`act` with `save_as`) and replayed later as one
/// action (`macro {name, vars}`), with no screenshot needed. Steps are saved in a form that doesn't
/// depend on one: controls by what they say, with where they were in the window (points from its
/// top-left corner) to fall back on, and everything else by that position. Values that change from run
/// to run are variables, `{{name}}` in the saved steps.
@MainActor
enum Macros {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/puter-use/macros", isDirectory: true)
    }

    static func file(_ name: String) throws -> URL {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 60, n.unicodeScalars.allSatisfy(ok.contains), !n.hasPrefix(".") else {
            throw HelperError("a macro name is 1-60 letters, digits, spaces, - _ or .")
        }
        return dir.appendingPathComponent(n.lowercased() + ".json")
    }

    static func load(_ name: String, pid: pid_t?) throws -> [String: Any] {
        let url = try file(name)
        guard let data = try? Data(contentsOf: url) else {
            let known = list(pid: pid).map { $0.name }
            throw HelperError("no macro \"\(name)\"" + (known.isEmpty ? "" : " (saved for this app: \(known.joined(separator: ", ")))"))
        }
        guard let m = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperError("macro \"\(name)\" is not a JSON object (\(url.path))")
        }
        return m
    }

    struct Entry {
        let name: String
        let line: String
    }

    /// Whether macro `m` was saved in the app running as `pid`: by bundle id, or by name for an app that
    /// has none (a bare executable).
    static func sameApp(_ m: [String: Any], _ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let id = (m["app"] as? String ?? "").lowercased(), here = (app.bundleIdentifier ?? "").lowercased()
        if !id.isEmpty || !here.isEmpty { return id == here }
        let name = (m["app_name"] as? String ?? "").lowercased()
        return !name.isEmpty && name == (app.localizedName ?? "").lowercased()
    }

    static func stepCount(_ n: Int) -> String { n == 1 ? "1 step" : "\(n) steps" }

    /// Saved macros, of one app or (pid nil) all.
    static func list(pid: pid_t?) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let pid, !sameApp(m, pid) { return nil }
            let app = m["app"] as? String ?? ""
            let name = m["name"] as? String ?? url.deletingPathExtension().lastPathComponent
            var line = "\(name) (\(m["app_name"] as? String ?? app)"
            line += ", \(stepCount((m["steps"] as? [Any])?.count ?? 0))"
            if let vars = m["vars"] as? [String], !vars.isEmpty { line += ", vars: \(vars.joined(separator: ", "))" }
            line += ")"
            if let d = m["description"] as? String, !d.isEmpty { line += ": \(d)" }
            return Entry(name: name, line: line)
        }
    }

    /// macros {window?, all?, delete?}: the macros saved for the window's app (or all of them).
    static func command(_ p: [String: Any]) throws -> [String: Any] {
        if let name = p["delete"] as? String {
            let url = try file(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw HelperError("no macro \"\(name)\"") }
            try FileManager.default.removeItem(at: url)
            return ["text": "deleted macro \"\(name)\""]
        }
        var pid: pid_t?
        var out: [String: Any] = [:]
        if p["all"] as? Bool != true, p["window"] != nil || Handlers.current != nil,
           let t = try? Handlers.resolve(p["window"]), let app = Handlers.pid(t) {
            pid = app
            out["window"] = Handlers.describe(t)
        }
        let entries = list(pid: pid)
        let whose = pid == nil ? "" : " for this app (all=true lists every app's)"
        out["text"] = entries.isEmpty ? "(no macros saved\(whose))"
            : entries.map(\.line).joined(separator: "\n") + "\nrun one: act [{type: macro, name, vars: {…}}]"
        return out
    }

    // MARK: - replay

    /// The actions with each `macro` step replaced by its saved steps, variables filled in.
    /// `offset`: how many actions of the batch come before these (for the notes' numbers).
    static func expand(_ actions: [[String: Any]], pid: pid_t?, depth: Int = 0, offset: Int = 0,
                       within: String? = nil) throws -> ([[String: Any]], [String]) {
        guard actions.contains(where: { Handlers.kind($0) == "macro" }) else { return (actions, []) }
        guard depth < 4 else { throw HelperError("macro \"\(within ?? "?")\" nests macros too deep (does one run itself?)") }
        var out: [[String: Any]] = []
        var notes: [String] = []
        for a in actions {
            guard Handlers.kind(a) == "macro" else {
                out.append(a)
                continue
            }
            guard let name = (a["name"] ?? a["macro"]) as? String else { throw HelperError("macro needs name") }
            let m = try load(name, pid: pid)
            if let pid, !sameApp(m, pid) {
                throw HelperError("macro \"\(name)\" was saved in \(m["app_name"] as? String ?? m["app"] as? String ?? "another app"), "
                    + "not this window's app")
            }
            let given = (a["vars"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            let needed = m["vars"] as? [String] ?? []
            let missing = needed.filter { given[$0] == nil }
            if !missing.isEmpty { throw HelperError("macro \"\(name)\" needs vars: \(missing.joined(separator: ", "))") }
            let extra = given.keys.filter { !needed.contains($0) }.sorted()
            if !extra.isEmpty {
                throw HelperError("macro \"\(name)\" has no var \(extra.joined(separator: ", "))"
                    + (needed.isEmpty ? " (it takes none)" : " (its vars: \(needed.joined(separator: ", ")))"))
            }
            // A replay the user OK'd (confirm: true) carries that to the presses it makes.
            let ok = a["confirm"] as? Bool == true
            let steps = (m["steps"] as? [[String: Any]] ?? []).map { step -> [String: Any] in
                var s = fill(step, given) as! [String: Any]
                if ok { s["confirm"] = true }
                return s
            }
            let (inner, more) = try expand(steps, pid: pid, depth: depth + 1, offset: offset + out.count, within: name)
            notes.append("macro \"\(name)\": actions \(offset + out.count + 1)-\(offset + out.count + inner.count)")
            out += inner
            notes += more
            guard out.count <= 1000 else { throw HelperError("macro \"\(name)\" comes to more than 1000 actions") }
        }
        return (out, notes)
    }

    /// `v` with each `{{name}}` replaced by its value.
    static func fill(_ v: Any, _ vars: [String: String]) -> Any {
        if let s = v as? String {
            var r = s
            for (k, val) in vars { r = r.replacingOccurrences(of: "{{\(k)}}", with: val) }
            return r
        }
        if let d = v as? [String: Any] { return d.mapValues { fill($0, vars) } }
        if let a = v as? [Any] { return a.map { fill($0, vars) } }
        return v
    }

    // MARK: - recording

    /// Controls worth naming in a saved step: pressing them does the same wherever they've moved to.
    /// (A click in text or a canvas depends on exactly where it lands, so that keeps its position.)
    static let named: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXLink", "AXTab", "AXDisclosureTriangle", "AXSwitch", "AXToggle",
    ]
    static let clicks: Set<String> = ["click", "left_click", "double_click", "triple_click", "right_click", "middle_click"]

    /// The step to save for action `a`, about to run on window `t`: element numbers (this session's
    /// only) and screenshot pixels become names and window points.
    static func record(_ a: [String: Any], _ t: Target) -> [String: Any] {
        var s = a
        s["confirm"] = nil  // the user's OK was for that time: a replay asks again
        guard case .window(let w) = t, a["units"] as? String != "pt" else { return s }
        let frame = Windows.info(w.id)?.frame ?? w.frame
        func rel(_ g: CGPoint) -> [NSNumber] {  // to a tenth of a point, saved as written (586.9, not 586.8999…)
            [g.x - frame.minX, g.y - frame.minY].map { NSDecimalNumber(string: String(format: "%.1f", $0)) }
        }
        func px(_ v: Any?) -> CGPoint? {
            guard let q = Handlers.point(v) else { return nil }
            return try? Handlers.toGlobal(t, q.x, q.y)
        }
        var moved = false
        func place(_ g: CGPoint) {
            let r = rel(g)
            s["x"] = r[0]
            s["y"] = r[1]
            moved = true
        }
        let xy: CGPoint? = Handlers.num(a["x"]).flatMap { x in Handlers.num(a["y"]).map { CGPoint(x: x, y: $0) } }
        if let idx = Handlers.num(a["element"]) {
            s["element"] = nil
            if let n = try? AX.node(w.id, Int(idx)) {
                if let label = n.label ?? AX.label(n.element), !label.isEmpty {
                    s["target"] = ["text": label, "role": n.name]
                    // A name others share only picks out the one at the saved spot on replay.
                    let hits = Handlers.matches(Handlers.Spec(text: label, role: n.name), w)
                    if !(hits.count == 1 && CFEqual(hits[0].element, n.element)) { s["spot"] = true }
                }
                if let c = AX.center(n) { place(c) }
            }
        } else if a["target"] == nil, let g = xy.flatMap({ try? Handlers.toGlobal(t, $0.x, $0.y) }) ?? px(a["coordinate"]) {
            s["coordinate"] = nil
            place(g)
            if clicks.contains(Handlers.kind(a)), let name = anchor(w, at: g) { s["target"] = name }
        }
        if let path = a["path"] as? [Any] {
            s["path"] = path.compactMap(px).map(rel)
            moved = true
        }
        for k in ["from", "to", "start", "end", "start_coordinate"] {
            if let g = px(a[k]) {
                s[k] = rel(g)
                moved = true
            }
        }
        if Handlers.kind(a) == "scroll", let m = Handlers.meta[t.key] {
            let ptPerPx = m.size.width / Double(m.width)
            for k in ["scroll_x", "scroll_y", "dx", "dy"] {
                if let v = Handlers.num(a[k]) { s[k] = (v * ptPerPx).rounded() }
            }
            moved = true
        }
        if let fields = a["fields"] as? [[String: Any]] { s["fields"] = fields.map { record($0, t) } }
        if let idx = Handlers.num(a["submit"]), CFGetTypeID(a["submit"]! as CFTypeRef) != CFBooleanGetTypeID() {
            s["submit"] = record(["element": idx], t)
        }
        if moved {
            s["units"] = "pt"
            // By position alone: it means the same only with the same things open over the window.
            if s["target"] == nil { s["over"] = WindowSet.of(w).over.count }
        }
        return s
    }

    /// A step that acts at a saved position alone (no name to find it by).
    nonisolated static func positional(_ a: [String: Any]) -> Bool {
        if Handlers.kind(a) == "fill" { return (a["fields"] as? [[String: Any]] ?? []).contains(where: positional) }
        guard a["units"] as? String == "pt", a["target"] == nil, a["element"] == nil else { return false }
        return ["x", "y", "coordinate", "path", "from", "to", "start", "end", "start_coordinate"].contains { a[$0] != nil }
    }

    /// What a macro step that names a control and where it was (`g`) acts on, when the name doesn't find
    /// it alone, or when it was saved as one of several with that name (`spot`): of the matches, the
    /// one at that spot; of none (its label changed), the element at the spot if it's of the same kind.
    /// Otherwise nil: a remembered position alone could act on something else entirely (another row's
    /// "Delete"). Never on something behind a sheet or dialog.
    static func spot(_ v: Any, _ t: Target, at g: CGPoint, strict: Bool = false) throws -> (CGPoint, AX.Node)? {
        guard case .window(let w) = t, let sp = try? Handlers.spec(v) else { return nil }
        let all = Handlers.matches(sp, w)
        let open = all.filter { AX.blockedBy($0.element) == nil }
        if open.count > 1 || (strict && !open.isEmpty) {
            let here = open.filter { $0.frame?.insetBy(dx: -2, dy: -2).contains(g) == true }
            guard here.count == 1 else { return nil }
            let n = try AX.node(w.id, Handlers.number(here[0], w.id))
            return AX.center(n).map { ($0, n) }
        }
        guard all.isEmpty, let role = sp.role, let el = element(w.pid, at: g, role: role), AX.blockedBy(el) == nil else {
            return nil
        }
        Handlers.notes.append("\(sp.description) wasn't there by name: used the \(role) where it was")
        let r = AX.value(el, kAXRoleAttribute) as? String ?? ""
        return (g, AX.Node(element: el, frame: AX.frame(el), role: r, label: AX.label(el), name: role))
    }

    /// The element at global point `g` (or holding it) whose kind, by outline name ("button", "field"),
    /// is `role`.
    static func element(_ pid: pid_t, at g: CGPoint, role: String) -> AXUIElement? {
        guard var el = control(pid, at: g, controlsOnly: false) else { return nil }
        for _ in 0..<4 {
            if let r = AX.value(el, kAXRoleAttribute) as? String, (AX.roleNames[r] ?? String(r.dropFirst(2)).lowercased()) == role {
                return el
            }
            guard let parent = AX.value(el, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            el = parent as! AXUIElement
        }
        return nil
    }

    /// The name of the control at global point `g`, if that name finds it alone in the window.
    static func anchor(_ w: WinInfo, at g: CGPoint) -> [String: Any]? {
        guard let el = control(w.pid, at: g), let role = AX.value(el, kAXRoleAttribute) as? String,
              let label = AX.label(el), !label.isEmpty else { return nil }
        let name = AX.roleNames[role] ?? String(role.dropFirst(2)).lowercased()
        let hits = Handlers.matches(Handlers.Spec(text: label, role: name), w)
        guard hits.count == 1, CFEqual(hits[0].element, el) else { return nil }
        return ["text": label, "role": name]
    }

    /// The control (button, checkbox, …) at global point `g`, or the element itself if it's none.
    static func control(_ pid: pid_t, at g: CGPoint, controlsOnly: Bool = true) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(g.x), Float(g.y), &hit) == .success, var el = hit else { return nil }
        let first = el
        for _ in 0..<3 {
            if let role = AX.value(el, kAXRoleAttribute) as? String, named.contains(role) { return el }
            guard let parent = AX.value(el, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            el = parent as! AXUIElement
        }
        return controlsOnly ? nil : first
    }

    /// The name and vars of a `save_as`, checked before the batch runs (so a bad one costs nothing).
    static func check(_ spec: Any) throws -> (String, URL, [String: String]) {
        let d = spec as? [String: Any] ?? [:]
        guard let name = (spec as? String ?? d["name"] as? String)?.trimmingCharacters(in: .whitespaces) else {
            throw HelperError("save_as is a name, or {name, vars?, description?}")
        }
        let url = try file(name)
        let vars = (d["vars"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        if let empty = vars.first(where: { $0.value.isEmpty }) { throw HelperError("var \(empty.key) has no value to replace") }
        if let bad = vars.keys.first(where: { $0.isEmpty || $0.contains("{") || $0.contains("}") }) {
            throw HelperError("\"\(bad)\" can't be a var name")
        }
        return (name, url, vars)
    }

    /// The parts of a step a var may stand in: what's typed, chosen or opened, not what the step is or
    /// aims at (a var "a" mustn't turn "cmd+a" into "cmd+{{a}}").
    static let content: Set<String> = ["text", "value", "option", "item", "url", "path"]

    /// Save `steps` (a batch that ran to the end) as macro `spec`: a name, or {name, vars, description}.
    /// Each var's value, where it appears in what the steps type, choose or open, becomes `{{var}}`: a
    /// value of 3 characters or more wherever it appears in one, a shorter one only as the whole of one.
    static func save(_ spec: Any, steps: [[String: Any]], pid: pid_t?) throws -> String {
        let d = spec as? [String: Any] ?? [:]
        let (name, url, vars) = try check(spec)
        // Longest values first, so one that contains another is replaced whole.
        let order = vars.sorted { $0.value.count > $1.value.count }
        var unused = Set(vars.keys)
        func templ(_ s: String) -> String {
            var s = s
            for (k, val) in order where val.count >= 3 ? s.contains(val) : s == val {
                s = s.replacingOccurrences(of: val, with: "{{\(k)}}")
                unused.remove(k)
            }
            return s
        }
        func step(_ a: [String: Any]) -> [String: Any] {
            var out = a
            for (k, v) in a {
                if content.contains(k), let str = v as? String { out[k] = templ(str) }
                if k == "fields", let fields = v as? [[String: Any]] { out[k] = fields.map(step) }
            }
            return out
        }
        let saved = steps.map(step)
        let used = vars.keys.filter { !unused.contains($0) }.sorted()
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let m: [String: Any] = [
            "name": name, "app": app?.bundleIdentifier ?? "", "app_name": app?.localizedName ?? "",
            "description": d["description"] as? String ?? "", "vars": used, "steps": saved,
            "saved": ISO8601DateFormatter().string(from: Date()),
        ]
        let replacing = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var note = "saved as macro \"\(name)\" (\(stepCount(saved.count))"
        if !used.isEmpty { note += ", vars: \(used.joined(separator: ", "))" }
        note += "): replay it with {type: macro, name: \"\(name)\"\(used.isEmpty ? "" : ", vars: {…}")}"
        if replacing { note += ". It replaces the macro saved under that name before" }
        if !unused.isEmpty {
            note += ". Not in what the steps typed or chose, so not variables: \(unused.sorted().joined(separator: ", "))"
        }
        return note
    }
}
