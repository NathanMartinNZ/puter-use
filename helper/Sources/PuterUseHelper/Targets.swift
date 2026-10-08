import AppKit
import ApplicationServices

/// Naming what to act on by what it says: `target: "Save"` or `{text, role, nth}`, looked up when the
/// action runs (so it survives the window changing since the last look), and `find`. Ties fail with the
/// candidates rather than guess; with no accessibility tree, the text is read off the screen instead.
extension Handlers {
    struct Spec {
        var text: String
        var role: String?
        var nth: Int?
        var description: String { (role.map { "\($0) " } ?? "") + "\"\(text)\"" + (nth.map { " #\($0)" } ?? "") }
    }

    static func spec(_ v: Any) throws -> Spec {
        if let s = v as? String, !s.isEmpty { return Spec(text: s) }
        if let d = v as? [String: Any], let text = (d["text"] ?? d["label"] ?? d["name"]) as? String {
            return Spec(text: text, role: (d["role"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        nth: num(d["nth"] ?? d["index"]).map { Int($0) })
        }
        throw HelperError("target is the text an element shows, e.g. \"Save\" or {\"text\": \"Save\", \"role\": \"button\"}")
    }

    /// Elements of window `w`, or of a sheet, popover or menu of its app over it, showing `spec`'s text:
    /// whole-label matches if there are any, and controls before bare labels saying the same thing.
    static func matches(_ sp: Spec, _ w: WinInfo, limit: Int = 30) -> [AX.Match] {
        // Over it: a menu, popover or panel, or a sheet or dialog (not another of the app's own windows).
        let over = Windows.popups(over: w).filter { o in
            o.frame.intersects(w.frame)
                && AX.window(pid: w.pid, wid: o.id).map { AX.value($0, kAXSubroleAttribute) as? String != "AXStandardWindow" } != false
        }
        var hits = AX.search(pid: w.pid, windows: Set([w.id] + over.map(\.id)), query: sp.text, role: sp.role, limit: limit)
        let exact = hits.filter(\.exact)
        if !exact.isEmpty { hits = exact }
        if sp.role == nil {
            let controls = hits.filter { $0.role != "text" }
            if !controls.isEmpty { hits = controls }
        }
        return hits
    }

    /// Give a match a number in the window's registry, so it can be named as `element` from now on.
    @discardableResult
    static func number(_ m: AX.Match, _ wid: CGWindowID) -> Int {
        let role = AX.value(m.element, kAXRoleAttribute) as? String ?? ""
        let label = role == "AXStaticText" ? nil : AX.label(m.element)
        return AX.registry(wid).number(AX.Node(element: m.element, frame: m.frame, role: role, label: label, name: m.role))
    }

    static func describe(_ m: AX.Match, id: Int, _ t: Target) -> String {
        var s = "[\(id)] \(m.role) \"\(AX.clip(m.label, 50))\""
        if let f = m.frame, let px = toPixels(t, CGPoint(x: f.midX, y: f.midY)) { s += " at (\(px[0]),\(px[1]))" }
        return s
    }

    struct NotFound: Error, CustomStringConvertible { let description: String }
    /// What's named is there, but behind a sheet or dialog: never worked around.
    struct Behind: Error, CustomStringConvertible { let description: String }

    /// The single element `v` names in window `w`: its number and node.
    static func findOne(_ v: Any, _ t: Target) throws -> (Int, AX.Node) {
        guard case .window(let w) = t else { throw HelperError("target needs a window") }
        let sp = try spec(v)
        var hits = matches(sp, w)
        if hits.isEmpty { throw NotFound(description: "nothing shows \(sp.description) in the window") }
        // With a sheet or dialog open, what's behind it can't be used; what's in it can.
        let open = hits.filter { AX.blockedBy($0.element) == nil }
        if open.isEmpty, let why = AX.blockedBy(hits[0].element) {
            throw Behind(description: "\(sp.description) is behind \(why) that's open over the window: deal with that first")
        }
        hits = open
        if let nth = sp.nth {
            guard nth >= 1, nth <= hits.count else { throw HelperError("\(sp.description): only \(hits.count) match") }
            hits = [hits[nth - 1]]
        }
        guard hits.count == 1 else {
            let list = hits.prefix(6).map { describe($0, id: number($0, w.id), t) }.joined(separator: "; ")
            throw HelperError("\(sp.description) matches \(hits.count) elements: \(list)"
                + "\(hits.count > 6 ? "; and \(hits.count - 6) more" : ""). Name one by its number, or add role or nth")
        }
        let id = number(hits[0], w.id)
        return (id, try AX.node(w.id, id))
    }

    /// The element an action names: `element` (a number) or `target` (what it says), or nil if neither.
    static func elementNode(_ a: [String: Any], _ t: Target) throws -> AX.Node? {
        if let idx = num(a["element"]) {
            guard case .window(let w) = t else { throw HelperError("element needs a window target") }
            let n = try AX.node(w.id, Int(idx))
            try reachable(n.element, "element \(Int(idx))")
            return n
        }
        if let v = a["target"] {
            // A macro step names what it acted on and where it was: see Macros.spot.
            let saved = a["units"] as? String == "pt" ? num(a["x"]).flatMap { x in num(a["y"]).map { (x, $0) } } : nil
            if let (x, y) = saved, a["spot"] as? Bool == true {
                if let (_, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a), strict: true) { return n }
                throw HelperError("\(try spec(v).description) isn't where it was when the macro was saved (others show the "
                    + "same), so nothing was done")
            }
            do { return try findOne(v, t).1 } catch {
                if let (x, y) = saved, !(error is Behind) {
                    if let (_, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a)) { return n }
                    throw HelperError("\(error) (a macro step: what it acted on isn't where it was, so nothing was done)")
                }
                if let e = error as? NotFound { throw HelperError("\(e)") }
                throw error
            }
        }
        return nil
    }

    /// Where `v`'s text is on screen, read off the pixels: for apps without an accessibility tree.
    static func readOffScreen(_ v: Any, _ t: Target) async throws -> CGPoint {
        let sp = try spec(v)
        // The screen shows text, not what kind of element it is.
        if sp.role != nil { throw HelperError("nothing shows \(sp.description) in the window") }
        let hits = try await ocrFind(sp.text, t)
        var pick = hits.filter(\.exact)
        if pick.isEmpty { pick = hits }
        if let nth = sp.nth, nth >= 1, nth <= pick.count { pick = [pick[nth - 1]] }
        guard !pick.isEmpty else { throw HelperError("nothing shows \(sp.description) (accessibility or on screen)") }
        guard pick.count == 1 else {
            let list = pick.prefix(6).map { h -> String in
                let px = toPixels(t, CGPoint(x: h.rect.midX, y: h.rect.midY)).map { " at (\($0[0]),\($0[1]))" } ?? ""
                return "\"\(AX.clip(h.line, 50))\"\(px)"
            }.joined(separator: "; ")
            throw HelperError("\(sp.description) is on screen \(pick.count) times: \(list). Add nth, or click by x,y")
        }
        notes.append("\(sp.description) found by reading the screen (no accessibility element)")
        return CGPoint(x: pick[0].rect.midX, y: pick[0].rect.midY)
    }

    /// OCR of the whole window at a resolution good for small text.
    /// For apps with no accessibility tree. One that had a tree and has none now isn't answering (the
    /// screen is locked, say): reading pixels instead would find text where controls used to be.
    static func ocrFind(_ text: String, _ t: Target) async throws -> [OCR.Hit] {
        if Windows.screenLocked { throw HelperError("the screen is locked, so the window can't be read: wait until the user unlocks it") }
        if case .window(let w) = t, AX.registries[w.id].map({ !$0.nodes.isEmpty }) == true, AX.window(pid: w.pid, wid: w.id) == nil {
            throw HelperError("the window's accessibility isn't answering just now (it was before): try again in a moment")
        }
        return try await OCR.find(text, in: try await sharpShot(t, region: nil))
    }

    static func sharpShot(_ t: Target, region: CGRect?) async throws -> Shot {
        var o = Opts([:])
        o.sizing.scale = 1.5
        o.sizing.zoomScale = 2
        o.sizing.maxTokens = 40_000
        let full: CGRect? = region ?? { if case .window(let w) = t { return Windows.info(w.id)?.frame ?? w.frame } else { return nil } }()
        return try await plan(t, region: full, o).run()
    }

    /// find {query, role?}: the elements showing that text, numbered for `element`, with where they are.
    static func find(_ p: [String: Any]) async throws -> [String: Any] {
        let t = try resolve(p["window"])
        current = t.key
        guard case .window(let w) = t else { throw HelperError("find needs a window") }
        try Policy.checkLook(w.pid)
        let q = p["query"] as? String ?? ""
        let sp = Spec(text: q, role: (p["role"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        guard !q.isEmpty || sp.role != nil else { throw HelperError("find needs a query (and/or role)") }
        if meta[t.key] == nil, let shot = try? await plan(t, region: nil, Opts(p)).run() { remember(t, shot, Signature(shot.image)) }
        let limit = max(1, min(int(p["limit"], 20), 100))
        let hits = matches(sp, w, limit: limit)
        var lines = hits.map { describe($0, id: number($0, w.id), t) }
        if hits.isEmpty, !q.isEmpty, sp.role == nil {
            let seen = try await ocrFind(q, t)
            lines = seen.prefix(limit).map { h in
                let px = toPixels(t, CGPoint(x: h.rect.midX, y: h.rect.midY)).map { " at (\($0[0]),\($0[1]))" } ?? ""
                return "text \"\(AX.clip(h.line, 60))\"\(px) (read off the screen: click it by x,y)"
            }
        }
        var out: [String: Any] = ["window": describe(t), "text": lines.isEmpty ? "(nothing shows \(sp.description))" : lines.joined(separator: "\n")]
        AppCards.enabled = p["app_cards"] as? Bool != false
        if let card = AppCards.card(pid: w.pid) { out["card"] = card }
        return out
    }
}
