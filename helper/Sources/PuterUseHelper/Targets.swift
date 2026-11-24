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
        narrowed(candidates(sp, w, limit: limit), sp)
    }

    /// Every element of `w` (or of what's open over it) showing `spec`'s text, as all or part of its label,
    /// looked for for `budget` seconds at most.
    static func candidates(_ sp: Spec, _ w: WinInfo, limit: Int, budget: TimeInterval = 1.5) -> [AX.Match] {
        AX.search(pid: w.pid, windows: Set([w.id] + openOver(w)), query: sp.text, role: sp.role, limit: limit, budget: budget)
    }

    /// What's open over window `w`: a menu, popover or panel, or a sheet or dialog (not another of the
    /// app's own windows).
    static func openOver(_ w: WinInfo) -> [CGWindowID] {
        Windows.popups(over: w).filter { o in
            o.frame.intersects(w.frame)
                && AX.window(pid: w.pid, wid: o.id).map { AX.value($0, kAXSubroleAttribute) as? String != "AXStandardWindow" } != false
        }.map(\.id)
    }

    /// Whole-label matches if there are any, and controls before bare labels saying the same thing.
    static func narrowed(_ all: [AX.Match], _ sp: Spec) -> [AX.Match] {
        var hits = all
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
        // What it was found by (its own name, the text that titles it, or the words in it), for messages about it.
        return AX.registry(wid).number(AX.Node(element: m.element, frame: m.frame, role: role, label: label, name: m.role,
                                               away: m.offScreen, shown: m.label.isEmpty ? nil : m.label))
    }

    static func describe(_ m: AX.Match, id: Int, _ t: Target) -> String {
        var s = "[\(id)] \(m.role) \"\(AX.clip(m.label, 50))\""
        if m.offScreen { return s + " (off screen)" }
        if let f = m.frame, let px = toPixels(t, CGPoint(x: f.midX, y: f.midY)) { s += " at (\(px[0]),\(px[1]))" }
        return s
    }

    struct NotFound: Error, CustomStringConvertible {
        let description: String
        var offScreen = ""  // what's off screen showing it, numbered: added to the error the miss ends in
        var near = ""  // what in the window is near it (`nearHint`): added after that
        /// Every search for it looked everywhere (none stopped early, out of time).
        var complete = true
        var hint: String { offScreen + near }
        /// Nothing anywhere shows it: the search on screen looked everywhere, and nothing off screen shows the
        /// text either (`offScreen` lists those, or says the search stopped early), and that search looked
        /// everywhere too (`complete`). Similar labels don't count.
        var clean: Bool { offScreen.isEmpty && complete }
    }

    /// A target nothing in the window shows, wherever it was looked for (on screen, off screen, read off the
    /// pixels): not several candidates, not one behind a dialog, not a search that stopped early. The only miss
    /// an optional step is skipped on. Reads as the error it replaces.
    struct Missing: Error, CustomStringConvertible { let description: String }

    /// The error a target's miss `e` ends in (target `v`, in `t`): where it was in a menu just closed, or what
    /// it says with what's off screen showing the text and what's near it. `Missing` when nothing shows it at
    /// all (and it wasn't in a menu just closed: that one is there, in the menu).
    static func missError(_ e: NotFound, _ v: Any, _ t: Target) throws -> Error {
        if let hint = menuHint(try spec(v), t) { return HelperError(hint) }
        let text = "\(e)\(e.hint)"
        return e.clean ? Missing(description: text) : HelperError(text)
    }
    /// What's named is there, but behind a sheet or dialog: never worked around.
    struct Behind: Error, CustomStringConvertible { let description: String }

    /// The single element `v` names in window `w`: its number and node. Found, it's said so to the action's
    /// `TargetLookup`.
    static func findOne(_ v: Any, _ t: Target) throws -> (Int, AX.Node) {
        let (id, n) = try lookUp(v, t)
        TargetLookup.current?.found = true
        return (id, n)
    }

    private static func lookUp(_ v: Any, _ t: Target) throws -> (Int, AX.Node) {
        guard case .window(let w) = t else { throw HelperError("target needs a window") }
        let sp = try spec(v)
        let start = Date()
        let (shown, complete) = AX.searchAll(pid: w.pid, windows: Set([w.id] + openOver(w)), query: sp.text, role: sp.role, limit: 30)
        var hits = narrowed(shown, sp)
        Trace.log(["k": "search", "ms": (Date().timeIntervalSince(start) * 10000).rounded() / 10, "hits": hits.count])
        if hits.isEmpty {
            // A search that stopped early didn't look at all that's shown: what it missed may show the text.
            guard complete else {
                throw NotFound(description: "nothing shows \(sp.description) in the window",
                               offScreen: "; the search stopped early (the app answered slowly), so part of the window wasn't looked at")
            }
            // Nothing on screen: one scrolled out of view, if it's the only one (it's scrolled to before it's used).
            return try findOffScreen(sp, w)
        }
        // With a sheet or dialog open, what's behind it can't be used; what's in it can.
        let open = hits.filter { AX.blockedBy($0.element) == nil }
        if open.isEmpty, let why = AX.blockedBy(hits[0].element) {
            throw Behind(description: "\(sp.description) is behind \(why) that's open over the window: deal with that first")
        }
        hits = open
        // Only part of a label on screen shows the text: not used if a whole label off screen does (a quick look).
        if !sp.text.isEmpty, !hits.contains(where: \.exact) {
            let whole = offScreenCandidates(sp, w, limit: 10, budget: conflictBudget).matches.filter(\.exact)
            if let why = partialConflict(hits, whole, sp, w, t) { throw HelperError(why) }
        }
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

    /// The element numbered `idx` in `w`. When it's gone, first checks whether the window's app stopped drawing
    /// it (`checkDrawn`: if brought forward and drawn again, retries once); otherwise the error lists the elements
    /// like it now there, with their numbers and where they are (none is picked: it could be another row's).
    static func numbered(_ w: WinInfo, _ idx: Int, _ t: Target, again: Bool = false) async throws -> AX.Node {
        do { return try AX.node(w.id, idx) } catch let gone as AX.Gone {
            if !again {
                do { try await checkDrawn(t) } catch is Redrawn {
                    return try await numbered(w, idx, t, again: true)
                } catch let e as NotDrawn {
                    throw e
                }
            }
            throw HelperError(gone.text { r in toPixels(t, CGPoint(x: r.midX, y: r.midY)).map { "(\($0[0]),\($0[1]))" } })
        }
    }

    /// `findOne(v, t)`, checking whether the window's app stopped drawing it on a miss (`NotFound`): if brought
    /// forward and drawn again (`Redrawn`), looks once more; if still not drawn (`NotDrawn`), throws `e.missing(...)`.
    static func findOneOrRevive(_ v: Any, _ t: Target, again: Bool = false) async throws -> (Int, AX.Node) {
        do { return try findOne(v, t) } catch let e as NotFound {
            if !again {
                do { try await checkDrawn(t) } catch is Redrawn {
                    return try await findOneOrRevive(v, t, again: true)
                } catch let nd as NotDrawn {
                    throw nd.missing(try spec(v).description)
                }
            }
            throw try missError(e, v, t)
        }
    }

    /// The element an action names: `element` (a number) or `target` (what it says), or nil if neither.
    static func elementNode(_ a: [String: Any], _ t: Target) async throws -> AX.Node? {
        if let idx = num(a["element"]) {
            guard case .window(let w) = t else { throw HelperError("element needs a window target") }
            let n = try await numbered(w, Int(idx), t)
            try reachable(n.element, "element \(Int(idx))")
            return n
        }
        if let v = a["target"] {
            // A macro step names what it acted on and where it was: see Macros.spot.
            let saved = a["units"] as? String == "pt" ? num(a["x"]).flatMap { x in num(a["y"]).map { (x, $0) } } : nil
            if let (x, y) = saved, a["spot"] as? Bool == true {
                if let (_, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a), strict: true) {
                    TargetLookup.current?.found = true
                    return n
                }
                throw HelperError("\(try spec(v).description) isn't where it was when the macro was saved (others show the "
                    + "same), so nothing was done")
            }
            if saved == nil, a["spot"] as? Bool == true { throw Macros.noSpot(v) }
            if let (x, y) = saved {
                do { return try findOne(v, t).1 } catch {
                    if !(error is Behind) {
                        if let (_, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a)) {
                            TargetLookup.current?.found = true
                            return n
                        }
                        throw HelperError("\(error) (a macro step: what it acted on isn't where it was, so nothing was done)")
                    }
                    throw error
                }
            }
            return try await findOneOrRevive(v, t).1
        }
        return nil
    }

    /// Where `v`'s text is on screen, read off the pixels: for apps without an accessibility tree. Nothing there
    /// showing it (and it wasn't in a menu just closed) is `Missing`. With the whole line it was read in (`line`):
    /// what a press there is judged by, with no element to ask (`Policy.checkReadPress`).
    static func readOffScreen(_ v: Any, _ t: Target) async throws -> (point: CGPoint, line: String) {
        let sp = try spec(v)
        func nothing(_ text: String) -> Error {
            if let hint = menuHint(sp, t) { return HelperError(hint) }
            return Missing(description: text)
        }
        // The screen shows text, not what kind of element it is.
        if sp.role != nil {
            do { try await checkDrawn(t) } catch let e as NotDrawn { throw e.missing(sp.description) }
            throw nothing("nothing shows \(sp.description) in the window")
        }
        let hits: [OCR.Hit]
        do { hits = try await ocrFind(sp.text, t) } catch let e as NotDrawn { throw e.missing(sp.description) }
        var pick = hits.filter(\.exact)
        if pick.isEmpty { pick = hits }
        if let nth = sp.nth, nth >= 1, nth <= pick.count { pick = [pick[nth - 1]] }
        guard !pick.isEmpty else { throw nothing("nothing shows \(sp.description) (accessibility or on screen)") }
        guard pick.count == 1 else {
            let list = pick.prefix(6).map { h -> String in
                let px = toPixels(t, CGPoint(x: h.rect.midX, y: h.rect.midY)).map { " at (\($0[0]),\($0[1]))" } ?? ""
                return "\"\(AX.clip(h.line, 50))\"\(px)"
            }.joined(separator: "; ")
            throw HelperError("\(sp.description) is on screen \(pick.count) times: \(list). Add nth, or click by x,y")
        }
        notes.append("\(sp.description) found by reading the screen (no accessibility element)")
        TargetLookup.current?.found = true
        return (CGPoint(x: pick[0].rect.midX, y: pick[0].rect.midY), pick[0].line)
    }

    /// For text that isn't there but was in a menu of this window closed in this call or the last one: say
    /// so, and how to choose from it.
    static func menuHint(_ sp: Spec, _ t: Target) -> String? {
        let s = Session.current
        guard case .window(let w) = t, let last = s.lastClosedMenu, last.wid == w.id, s.acts - last.act <= 1 else { return nil }
        let k = AX.menuKey(sp.text)
        var found = last.titles.first(where: { AX.menuKey($0) == k || AX.menuKey($0) == k + " >" })
        // A long title clipped in the note ("Open Link in New Private Wi…"): the one whole title it starts.
        if found == nil, k.hasSuffix("…"), AX.startKey(sp.text).count >= 20 {
            let starts = last.titles.filter { AX.menuKey($0).hasPrefix(AX.startKey(sp.text)) }
            if starts.count == 1 { found = starts[0] }
        }
        guard let item = found else { return nil }
        let name = item.hasSuffix(" >") ? String(item.dropLast(2)) : item
        let when = last.act == s.acts ? "earlier in this call" : "in your last call"
        return "nothing shows \(sp.description): \"\(name)\" was in a menu closed \(when) (an open menu takes the user's "
            + "typing). Open it again and choose in the same click, with item: \"\(name)\""
    }

    /// OCR of the whole window at a resolution good for small text (`ocrShot`).
    static func ocrFind(_ text: String, _ t: Target) async throws -> [OCR.Hit] {
        try await OCR.find(text, in: try await ocrShot(t))
    }

    /// The window as `ocrFind` reads it (one picture can be read for several texts).
    /// For apps with no accessibility tree. One that had a tree and has none now isn't answering (the
    /// screen is locked, say): reading pixels instead would find text where controls used to be. Nor one its app
    /// isn't drawing (`NotDrawn`): its picture shows what was there before.
    static func ocrShot(_ t: Target) async throws -> Shot {
        if Windows.screenLocked { throw HelperError("the screen is locked, so the window can't be read: wait until the user unlocks it") }
        if case .window(let w) = t, AX.registries[w.id].map({ !$0.nodes.isEmpty }) == true, AX.window(pid: w.pid, wid: w.id) == nil {
            throw HelperError("the window's accessibility isn't answering just now (it was before): try again in a moment")
        }
        try await checkDrawn(t)
        return try await sharpShot(t, region: nil)
    }

    static func sharpShot(_ t: Target, region: CGRect?) async throws -> Shot {
        var o = Opts([:])
        o.sizing.scale = 1.5
        o.sizing.zoomScale = 2
        o.sizing.maxTokens = 40_000
        let full: CGRect? = region ?? { if case .window(let w) = t { return Windows.info(w.id)?.frame ?? w.frame } else { return nil } }()
        return try await plan(t, region: full, o).run()
    }

    /// `find`'s lines for text read off the screen (no accessibility element shows it): saying so once, then
    /// `text "…" at (x,y)` for each (`px`: a point's screenshot pixels). None for none.
    static func screenLines(_ hits: [OCR.Hit], _ px: (CGPoint) -> [Int]?) -> [String] {
        guard !hits.isEmpty else { return [] }
        return ["(read off the screen: click these by x,y)"] + hits.map { h in
            "text \"\(AX.clip(h.line, 60))\"" + (px(CGPoint(x: h.rect.midX, y: h.rect.midY)).map { " at (\($0[0]),\($0[1]))" } ?? "")
        }
    }

    /// At most this many texts in one find.
    nonisolated static let findMaxQueries = 10
    /// The matches several texts list in one find, between them: each lists an even share at most.
    nonisolated static let findShared = 40
    /// How long a find of several texts spends looking, in all (s): one not reached by then says so.
    static let findBudget: TimeInterval = 5

    /// The texts a find looks for: `query`, then each of `queries` (a list, or one text), blank ones and
    /// repeats left out.
    nonisolated static func findQueries(_ p: [String: Any]) -> [String] {
        let many: [Any] = p["queries"] as? [Any] ?? (p["queries"] as? String).map { [$0] } ?? []
        let given: [Any] = (p["query"].map { [$0] } ?? []) + many
        var out: [String] = []
        for case let q as String in given where !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !out.contains(q) {
            out.append(q)
        }
        return out
    }

    /// How many matches each of `count` texts lists: `limit` (1-100; 20 by default for one text, 5 for
    /// several), and for several, no more than an even share of `findShared`.
    nonisolated static func findCap(count: Int, limit: Any?) -> Int {
        let asked = max(1, min(int(limit, count > 1 ? 5 : 20), 100))
        return count > 1 ? max(1, min(asked, findShared / count)) : asked
    }

    /// The first and last lines of a find by role alone (`role`) that found `found` elements (all there are,
    /// if `complete`) and lists the first `listed`: how many of how many, so a list cut short says so.
    nonisolated static func roleSummary(_ role: String, found: Int, listed: Int, complete: Bool) -> (header: String, tail: String?) {
        let what = "role \"\(role)\""
        guard listed < found else {
            return (complete ? "\(what), all \(found):" : "\(what), \(found) found (the search stopped early, so there may be more):", nil)
        }
        return ("\(what), the first \(listed) of \(found)\(complete ? "" : " or more") (add a query to narrow it):",
                "+\(found - listed) \(complete ? "more" : "or more")")
    }

    /// Matches of the search on screen (`AX.search`) with those it tagged off screen (in the window, but scrolled out
    /// of the list or page they're in) after the rest, each part in its order.
    nonisolated static func shownFirst(_ found: [AX.Match]) -> [AX.Match] {
        found.filter { !$0.offScreen } + found.filter(\.offScreen)
    }

    /// find by role alone: the elements of that role, those on screen in reading order, then those scrolled out
    /// of view (tagged): the first `cap`, with how many there are (counted up to a few times `cap`).
    static func roleLines(_ role: String, _ w: WinInfo, _ t: Target, cap: Int) -> [String] {
        let sp = Spec(text: "", role: role), count = max(cap * 5, 100)
        let (found, shownAll) = AX.searchAll(pid: w.pid, windows: Set([w.id] + openOver(w)), query: "", role: role, limit: count)
        var away: [AX.Match] = [], complete = shownAll
        if shownAll { (away, complete) = offScreenCandidates(sp, w, limit: max(1, count - found.count)) }
        let all = shownFirst(found) + away
        guard !all.isEmpty else { return [complete ? "(no \(role) in the window)" : "(no \(role) found: the search stopped early)"] }
        let listed = all.prefix(cap)
        let (header, tail) = roleSummary(role, found: all.count, listed: listed.count, complete: complete)
        return [header] + listed.map { describe($0, id: number($0, w.id), t) } + (tail.map { [$0] } ?? [])
    }

    /// What `find` finds for one text (`sp`): the elements showing it, whole labels first, then those scrolled out
    /// of view (tagged: acting on one scrolls to it first), `cap` at most; then up to `partials` that only
    /// contain it. With none, what the screen shows of it (`screen`: an app with no accessibility tree), else
    /// up to three similar labels (`similar`). Its searches stop by `deadline` (uptime); `complete`: the one off
    /// screen looked everywhere.
    static func findLines(_ sp: Spec, _ w: WinInfo, _ t: Target, cap: Int, partials: Int, deadline: TimeInterval,
                          screen: (String) async throws -> [OCR.Hit]) async throws -> (lines: [String], similar: [String], complete: Bool) {
        let q = sp.text
        func left(_ most: TimeInterval) -> TimeInterval { min(most, max(0.05, deadline - AX.uptime())) }
        let all = shownFirst(candidates(sp, w, limit: cap + 5, budget: left(1.5)))
        var hits = Array(narrowed(all, sp).prefix(cap))
        // Then what's scrolled out of view (a search of its own), tagged: acting on one scrolls to it first.
        // Whole-label ones follow whole-label ones shown; the rest go with those that only contain the text.
        // With nothing shown, that search also notes what's near the text, for when there's none at all.
        let near = hits.isEmpty ? AX.Near(q) : nil
        // A whole label shown already: only a quick look (`conflictBudget`) for more off screen.
        let quick = hits.contains(where: \.exact) ? conflictBudget : 1.5
        let (away, complete) = hits.count < cap ? offScreenCandidates(sp, w, limit: cap + 5, budget: left(quick), near: near) : ([], true)
        hits += narrowed(hits.contains(where: \.exact) ? away.filter(\.exact) : away, sp).prefix(cap - hits.count)
        // A whole label off screen comes before ones shown that only contain the text: those go under "partial matches".
        if hits.contains(where: \.exact) { hits = hits.filter(\.exact) }
        // A target takes whole-label matches when there are any, but find also shows a few that contain the text
        // ("Sign in" is also in "Sign in with Google"), controls first.
        var more: [AX.Match] = []
        if hits.contains(where: \.exact), partials > 0 {
            let rest = (all + away).filter { m in !m.exact && !hits.contains { CFEqual($0.element, m.element) } }
            more = Array((sp.role == nil ? rest.filter { $0.role != "text" } + rest.filter { $0.role == "text" } : rest).prefix(partials))
        }
        // A browser window its app isn't drawing has no page to read, but its tabs and toolbar carry the page's title:
        // what's found only there is listed, marked as not in the page, and why the page doesn't show it is said.
        var frozen = !hits.isEmpty && (hits + more).allSatisfy({ chromeOnly($0, w) }) ? try await frozenNow(t, tree: true) : nil
        if var f = frozen {
            if await revive(w, &f) { throw Redrawn() }  // drawn again: looked for again (`find`)
            frozen = f
            meta[w.id]?.frozen = f
        }
        func line(_ m: AX.Match) -> String {
            describe(m, id: number(m, w.id), t) + (frozen != nil ? " (\(w.app)'s own, not in the page)" : "")
        }
        var lines = hits.map(line)
        if !more.isEmpty {
            lines.append("partial matches (target one by its whole text or number):")
            lines += more.map(line)
        }
        if let frozen { lines.append("(nothing in the page: \(NotDrawn(frozen: frozen, app: w.app, wid: w.id)))") }
        if hits.isEmpty, sp.role == nil {
            let seen = try await screen(q)
            lines = screenLines(Array(seen.prefix(cap))) { toPixels(t, $0) }
        }
        var similar: [String] = []
        if lines.isEmpty, let near { similar = nearest(near, w).map { describe($0.1, id: $0.0, t) } }
        return (lines, similar, complete)
    }

    /// The text of a find of one text (`what`, as `Spec` describes it): its lines; with none, that nothing shows
    /// it, and what's similar on lines of their own.
    nonisolated static func findText(_ what: String, lines: [String], similar: [String], complete: Bool) -> String {
        var text = !lines.isEmpty ? lines.joined(separator: "\n")
            : similar.isEmpty ? "(nothing shows \(what))" : (["(nothing shows \(what)) similar:"] + similar).joined(separator: "\n")
        if !complete { text += "\n(more may be off screen: the search there stopped early)" }
        return text
    }

    /// One text's part of a find of several (`what`, as `Spec` describes it): a header, then its lines; with none,
    /// one line saying so (with what's similar, and whether the search off screen stopped early).
    nonisolated static func findSection(_ what: String, lines: [String], similar: [String], complete: Bool) -> [String] {
        guard !lines.isEmpty else {
            let rest = (similar.isEmpty ? [] : ["similar: " + similar.joined(separator: "; ")])
                + (complete ? [] : ["the search off screen stopped early"])
            return ["(nothing shows \(([what] + rest).joined(separator: "; ")))"]
        }
        return ["\(what):"] + lines + (complete ? [] : ["(more may be off screen: the search there stopped early)"])
    }

    /// find {query | queries, role?, limit?}: the elements showing that text, numbered for `element`, with where
    /// they are. Several texts (`queries`, with `query` or not): a part for each under its own header, from one
    /// picture, in one time budget (`findBudget`), sharing one length (`findCap`). A role and no text: the
    /// elements of that role, capped (`roleLines`).
    static func find(_ p: [String: Any]) async throws -> [String: Any] {
        let t = try resolve(p["window"])
        current = t.key
        guard case .window(let w) = t else { throw HelperError("find needs a window") }
        try Policy.checkLook(w.pid)
        let role = (p["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let queries = findQueries(p)
        guard !queries.isEmpty || role != nil else { throw HelperError("find needs a query (and/or role), or queries") }
        guard queries.count <= findMaxQueries else {
            throw HelperError("find takes at most \(findMaxQueries) queries at once, not \(queries.count)")
        }
        // A picture to give what's found its place in pixels (at (x,y)): never shown, so an act's first look
        // still shows the window (`startLook`).
        if meta[t.key] == nil, case let o = Opts(p), let shot = try? await plan(t, region: nil, o).run() {
            remember(t, shot, Signature(shot.image), shown: false, sizing: o.sizing)
        }
        let cap = findCap(count: max(queries.count, 1), limit: p["limit"])
        // Nothing found in a window its app isn't drawing (asked before its picture is read, `ocrShot`, or here for a
        // role, which isn't read off it): the find fails saying so, as looking again won't change it. Unless its app
        // was brought forward to draw it again (`Redrawn`): then it's looked for again, once.
        func lines(_ sp: Spec, partials: Int, deadline: TimeInterval, screen: (String) async throws -> [OCR.Hit]) async throws
            -> (lines: [String], similar: [String], complete: Bool) {
            func look() async throws -> (lines: [String], similar: [String], complete: Bool) {
                let found = try await findLines(sp, w, t, cap: cap, partials: partials, deadline: deadline, screen: screen)
                if found.lines.isEmpty, sp.role != nil { try await checkDrawn(t) }
                return found
            }
            do {
                do { return try await look() } catch is Redrawn { return try await look() }
            } catch let e as NotDrawn { throw e.missing(sp.description) }
        }
        let text: String
        if queries.isEmpty, let role {
            func lookRole() async throws -> [String] {
                let got = roleLines(role, w, t, cap: cap)
                if got.count == 1, got[0].hasPrefix("(no ") { try await checkDrawn(t) }
                return got
            }
            do {
                let got: [String]
                do { got = try await lookRole() } catch is Redrawn { got = try await lookRole() }
                text = got.joined(separator: "\n")
            } catch let e as NotDrawn {
                throw e.missing("role \"\(role)\"")
            }
        } else if queries.count == 1 {
            let sp = Spec(text: queries[0], role: role)
            let found = try await lines(sp, partials: 5, deadline: .infinity) { try await ocrFind($0, t) }
            text = findText(sp.description, lines: found.lines, similar: found.similar, complete: found.complete)
        } else {
            var picture: Shot?  // for text read off the screen: one, for all of them
            func screen(_ q: String) async throws -> [OCR.Hit] {
                if picture == nil { picture = try await ocrShot(t) }
                return try await OCR.find(q, in: picture!)
            }
            let promptBase = Connection.current?.promptWait ?? 0
            let baseDeadline = AX.uptime() + findBudget
            func deadline() -> TimeInterval { baseDeadline + ((Connection.current?.promptWait ?? 0) - promptBase) }
            var parts: [String] = []
            for q in queries {
                let sp = Spec(text: q, role: role)
                guard AX.uptime() < deadline() else {
                    parts.append("(\(sp.description) wasn't looked for: the others took the time; find it on its own)")
                    continue
                }
                let found = try await lines(sp, partials: min(2, cap), deadline: deadline(), screen: screen)
                parts += findSection(sp.description, lines: found.lines, similar: found.similar, complete: found.complete)
            }
            text = parts.joined(separator: "\n")
        }
        var out: [String: Any] = ["window": describe(t), "text": text]
        AppCards.enabled = p["app_cards"] as? Bool != false
        if let card = AppCards.card(pid: w.pid) { out["card"] = card }
        return out
    }
}

/// The target lookups of one action (act gives one to an optional step): whether one has found what the action
/// names. A miss after that (a menu item looked for once a click has opened its menu) isn't the step's own, so the
/// step isn't skipped for it.
final class TargetLookup: @unchecked Sendable {  // only touched on the main thread
    var found = false
    @TaskLocal static var current: TargetLookup?
}
