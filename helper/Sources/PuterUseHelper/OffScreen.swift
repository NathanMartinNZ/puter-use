import AppKit
import ApplicationServices

/// Elements scrolled out of view (below the fold, further down a list). `target` finds one when nothing on
/// screen matches, `find` lists them after what's shown, and anything acting on one scrolls it into view
/// first and checks it got there: an action never lands on what the agent can't see.
extension AX {
    /// Where an element is: its frame, and the part of the screen it can be seen in (its window, clipped to
    /// every scroll area and web page it's in; nil if none was found).
    struct Sight: Equatable {
        let frame: CGRect
        let view: CGRect?
    }

    static let sightAttrs = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute] as CFArray

    /// Where `el` is, one read per level up to its window. Nil with no frame, or in a menu or popover (drawn in a
    /// window of its own, over the one it belongs to).
    static func sight(_ el: AXUIElement) -> Sight? {
        guard let f = frame(el) else { return nil }
        var view: CGRect?
        var cur = parent(el)
        for _ in 0..<120 {
            guard let c = cur else { break }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(c, sightAttrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let vals = raw as? [AnyObject], vals.count == 4 else { break }
            let role = vals[0] as? String ?? ""
            if role == "AXMenu" || role == "AXPopover" { return nil }
            if role == "AXScrollArea" || role == "AXWebArea" || role == "AXWindow", let r = rect(vals[1], vals[2]),
               r.width > 0, r.height > 0 {
                view = view.map { $0.intersection(r) } ?? r
            }
            if role == "AXWindow" || role == "AXApplication" { break }
            cur = CFGetTypeID(vals[3]) == AXUIElementGetTypeID() ? (vals[3] as! AXUIElement) : nil
        }
        return Sight(frame: f, view: view)
    }

    static func rect(_ position: AnyObject, _ size: AnyObject) -> CGRect? {
        var pt = CGPoint.zero, sz = CGSize.zero
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &pt), AXValueGetValue(size as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// The scroll areas `el` is in that can be asked to show part of what they hold (AppKit's take
    /// AXMakeScreenRectVisible), innermost first.
    static func scrollAreas(of el: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var cur = parent(el)
        for _ in 0..<120 {
            guard let c = cur, let role = value(c, kAXRoleAttribute) as? String, role != "AXWindow", role != "AXApplication" else { break }
            var settable: DarwinBoolean = false
            if role == "AXScrollArea", AXUIElementIsAttributeSettable(c, "AXMakeScreenRectVisible" as CFString, &settable) == .success,
               settable.boolValue {
                out.append(c)
            }
            cur = parent(c)
        }
        return out
    }
}

extension Handlers {
    /// The part of it that's on screen (at least a point each way), or nil.
    nonisolated static func shownPart(_ s: AX.Sight) -> CGRect? {
        let v = s.view.map { s.frame.intersection($0) } ?? s.frame
        return v.isNull || v.width < 1 || v.height < 1 ? nil : v
    }

    /// Shown well enough to see and act on: 4 points of it each way (all of it, if it's smaller).
    nonisolated static func inView(_ s: AX.Sight) -> Bool {
        guard let p = shownPart(s) else { return false }
        return p.width >= min(4, s.frame.width) - 0.01 && p.height >= min(4, s.frame.height) - 0.01
    }

    /// Scrolled out of view (or kept off screen): none of it is shown, or only a sliver. Can't tell (nothing
    /// found around it, or no size): no.
    nonisolated static func offScreen(_ s: AX.Sight) -> Bool {
        s.view != nil && s.frame.width >= 1 && s.frame.height >= 1 && !inView(s)
    }

    /// Where it is can't be told: no sight (no frame, or in a menu or popover), nothing found around it, or under a
    /// point either way.
    nonisolated static func unknown(_ s: AX.Sight?) -> Bool {
        guard let s else { return true }
        return s.view == nil || s.frame.width < 1 || s.frame.height < 1
    }

    /// Where it was, for the note: "below", "above", … the visible part.
    nonisolated static func side(_ s: AX.Sight) -> String {
        guard let v = s.view else { return "outside" }
        let f = s.frame
        if f.midY >= v.maxY { return "below" }
        if f.midY <= v.minY { return "above" }
        if f.midX >= v.maxX { return "to the right of" }
        if f.midX <= v.minX { return "to the left of" }
        return "at the edge of"
    }

    /// Before acting on element `n` (`name` in notes and errors): if it's scrolled out of view, scroll to it and
    /// check it's in view now, with a note. Where it's shown then, or nil if it was in view already (or where
    /// it is can't be told). Fails rather than act on something that can't be brought into view.
    static func reveal(_ n: AX.Node, _ name: String) async throws -> CGRect? {
        let start = ProcessInfo.processInfo.systemUptime
        let seen = AX.sight(n.element)
        if Trace.on { Trace.log(["k": "sight", "ms": ((ProcessInfo.processInfo.systemUptime - start) * 10000).rounded() / 10]) }
        // Found off screen (a target's pick, a number from an off-screen list): used only once where it is is known.
        if n.away, unknown(seen) {
            throw HelperError("\(name) was found off screen, but where it is can't be told (it has no size there, or it's in "
                + "a menu), so nothing was done")
        }
        guard let before = seen, offScreen(before) else { return nil }
        func look() -> AX.Sight { AX.sight(n.element) ?? before }
        var now = before
        var how = "none"
        // The app's own way (web pages, Chromium, WebKit): every list and page it's in is scrolled to it. Then
        // until it's in view and has stopped moving (a smooth scroll), or plainly isn't going to move.
        if AX.act(n.element, "AXScrollToVisible") == .success {
            how = "action"
            var last = before.frame
            now = try await Run.poll(floor: 0.05, every: 0.05, cap: 0.6, look) { s in
                defer { last = s.frame }
                if inView(s) { return s.frame == last }
                return s.frame == before.frame && ProcessInfo.processInfo.systemUptime - start >= 0.15
            }
        }
        // AppKit's controls don't take that: each scroll area it's in is asked to show it, innermost first, with
        // a little room around it.
        if !inView(now) {
            for area in AX.scrollAreas(of: n.element) {
                guard let f = AX.frame(n.element), let af = AX.frame(area) else { break }
                var r = f.insetBy(dx: -max(0, min(40, (af.width - f.width) / 2)), dy: -max(0, min(40, (af.height - f.height) / 2)))
                guard let v = AXValueCreate(.cgRect, &r), AX.write(area, "AXMakeScreenRectVisible", v) == .success else { continue }
                how = "area"
            }
            if how == "area" { now = try await Run.poll(floor: 0.02, every: 0.04, cap: 0.3, look) { inView($0) } }
        }
        Trace.log(["k": "reveal", "how": how, "ok": inView(now), "ms": ((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded()])
        guard inView(now), let part = shownPart(now) else {
            throw HelperError("\(name) is off screen and couldn't be scrolled into view (it may be hidden until something "
                + "opens it), so nothing was done")
        }
        notes.append("scrolled to \(name) (it was \(side(before)) the visible part)")
        return part
    }

    /// Where to aim at element `n` (`name` in notes and errors): its centre, or the middle of what's shown of it
    /// once it's been scrolled into view. `vet` (the policy's checks) runs first: a stop scrolls nothing.
    static func aimAt(_ n: AX.Node, _ name: String, vet: ((AX.Node) throws -> Void)? = nil) async throws -> (CGPoint, AX.Node) {
        try vet?(n)
        if let part = try await reveal(n, name) { return (CGPoint(x: part.midX, y: part.midY), n) }
        guard let c = AX.center(n) else { throw HelperError("\(name) has no position") }
        return (c, n)
    }

    /// The policy's say on a click at element `n`, before it's scrolled to (the click checks again at its point):
    /// a left click's press, and the menu item it chooses (as asked, and as a pop-up's option is titled).
    static func clickChecks(_ a: [String: Any], _ n: AX.Node, button: String) throws {
        if button == "left" { try Policy.checkPress(a, node: n, at: nil, pid: AX.pidOf(n.element) ?? 0) }
        guard let item = a["item"] else { return }
        let path = AX.menuPath(item)
        if path.contains(where: { AX.menuKey($0) == "services" }) {
            throw HelperError("Services hand what's selected to other apps; puter-use doesn't use them")
        }
        guard let last = path.last else { return }
        try Policy.checkItem(a, last)
        if let pid = AX.pidOf(n.element) { try Policy.checkPointerItem(pid, last) }
        if path.count == 1, button == "left", let popup = popUpButton(n.element), let match = AX.optionTitle(popup, last) {
            try Policy.checkItem(a, match)
        }
    }

    /// Elements of `w` (or of what's open over it) showing `sp`'s text outside the window: scrolled out of view,
    /// or kept off screen. A search of its own (1.5 s at most), and whether it looked everywhere. `near` collects
    /// what's near the text on the way, shown or not (for a miss: see `nearHint`).
    static func offScreenCandidates(_ sp: Spec, _ w: WinInfo, limit: Int, budget: TimeInterval = 1.5,
                                    near: AX.Near? = nil) -> (matches: [AX.Match], complete: Bool) {
        let start = Date()
        let got = AX.searchAll(pid: w.pid, windows: Set([w.id] + openOver(w)), query: sp.text, role: sp.role, limit: limit,
                               budget: budget, offScreen: true, near: near)
        Trace.log(["k": "search", "off": true, "ms": (Date().timeIntervalSince(start) * 10000).rounded() / 10,
                   "hits": got.matches.count, "complete": got.complete])
        return got
    }

    /// The off-screen match a target takes: the only whole-label one (a control before a bare label saying the
    /// same), found by a search that looked everywhere, and known to be off screen (`sight`: where it is can be
    /// told, so it can be scrolled to and checked). Otherwise nil, and the agent picks by number.
    static func offScreenPick(_ open: [AX.Match], _ sp: Spec, complete: Bool,
                              sight: (AXUIElement) -> AX.Sight? = AX.sight) -> AX.Match? {
        guard complete, sp.nth == nil || sp.nth == 1 else { return nil }
        let whole = narrowed(open.filter(\.exact), sp)
        guard whole.count == 1, sight(whole[0].element).map(offScreen) == true else { return nil }
        return whole[0]
    }

    /// How long a target that only part of a label on screen shows looks off screen for a whole label.
    static let conflictBudget: TimeInterval = 0.3

    /// Only part of a label on screen shows a target's text, while a whole label off screen does ("Submit
    /// feedback" shown, "Submit" below the fold).
    static func conflicts(_ shown: [AX.Match], _ away: [AX.Match]) -> Bool {
        !shown.isEmpty && !shown.contains(where: \.exact) && away.contains(where: \.exact)
    }

    /// For `conflicts`: the error, listing both kinds, numbered (neither is used). Nil if they don't conflict.
    static func partialConflict(_ shown: [AX.Match], _ away: [AX.Match], _ sp: Spec, _ w: WinInfo, _ t: Target) -> String? {
        guard conflicts(shown, away) else { return nil }
        let list = (Array(shown.prefix(3)) + Array(away.filter(\.exact).prefix(3))).map { describe($0, id: number($0, w.id), t) }
        return "\(sp.description) is only part of a label on screen, but a whole label off screen: \(list.joined(separator: "; "))"
            + ". Nothing was done: name the one you mean by its number (one off screen is scrolled into view first)"
    }

    /// Whether a macro step can name element `el` by `sp` alone: a target picks it and nothing else, on screen or off
    /// (`shown`, narrowed as a target's are; `away`, the off-screen ones), and both searches looked everywhere.
    static func alone(_ el: AXUIElement, shown: [AX.Match], away: [AX.Match], complete: Bool, _ sp: Spec) -> Bool {
        guard complete else { return false }
        let all = narrowed(shown, sp).filter(\.exact) + away.filter(\.exact)
        return all.count == 1 && CFEqual(all[0].element, el)
    }

    /// `alone`, searching window `w`.
    static func namesAlone(_ el: AXUIElement, _ sp: Spec, _ w: WinInfo) -> Bool {
        let shown = AX.searchAll(pid: w.pid, windows: Set([w.id] + openOver(w)), query: sp.text, role: sp.role, limit: 30)
        let away = offScreenCandidates(sp, w, limit: 30)
        return alone(el, shown: shown.matches, away: away.matches, complete: shown.complete && away.complete, sp)
    }

    /// For a target nothing on screen shows: the one element off screen that does, to be scrolled to before it's
    /// used. Anything else is a miss as before (`NotFound`), which says what's off screen, numbered.
    static func findOffScreen(_ sp: Spec, _ w: WinInfo) throws -> (Int, AX.Node) {
        let none = "nothing shows \(sp.description) in the window"
        let near = AX.Near(sp.text)
        let (all, complete) = offScreenCandidates(sp, w, limit: 30, near: near)
        if all.isEmpty { throw NotFound(description: none, near: nearHint(near, w)) }
        let open = all.filter { AX.blockedBy($0.element) == nil }
        if open.isEmpty, let why = AX.blockedBy(all[0].element) {
            throw Behind(description: "\(sp.description) is behind \(why) that's open over the window: deal with that first")
        }
        if let one = offScreenPick(open, sp, complete: complete) {
            let id = number(one, w.id)
            return (id, try AX.node(w.id, id))
        }
        let hits = narrowed(open, sp)
        let list = hits.prefix(6).map { "[\(number($0, w.id))] \($0.role) \"\(AX.clip($0.label, 50))\"" }.joined(separator: "; ")
        let more = (hits.count > 6 ? "; and \(hits.count - 6) more" : "") + (complete ? "" : " (the search there stopped early)")
        let whole = hits.contains(where: \.exact)
        var how = (whole ? "Name one by its number" : "Give the whole text, or name one by its number")
            + " (it's scrolled into view first)"
        // The one whole label, but where it is can't be told (no size there, in a menu): not used, by number either.
        let lone = hits.filter(\.exact)
        if complete, lone.count == 1, unknown(AX.sight(lone[0].element)) {
            how = "Where \(lone[0].role) \"\(AX.clip(lone[0].label, 50))\" is can't be told (it has no size there, or it's in a "
                + "menu), so it isn't used"
        }
        throw NotFound(description: none, offScreen: "; off screen: \(list)\(more). \(how)",
                       near: whole ? "" : nearHint(near, w))
    }
}
