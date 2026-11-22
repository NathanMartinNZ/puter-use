import AppKit
import ApplicationServices

/// Clicking web content in Firefox (Gecko). Its accessibility press fires mousedown, mouseup and click
/// but no pointer events, so controls that listen for `pointerdown` (Radix/shadcn triggers, many
/// filter bars) ignore it. A real (posted) click fires them; it's aimed at a point that's really on the
/// element, found by asking the app what's under each candidate point.
extension Handlers {
    enum WebAim {
        case post(CGPoint)  // click here
        case press(String?)  // keep the accessibility press; what's over the element, if that's why
    }

    /// Where to click `n` in web content of a Gecko app, or why to press it through accessibility
    /// instead. Nil when it isn't web content of a Gecko app (the caller does what it always did).
    static func webAim(_ n: AX.Node, _ wid: CGWindowID, pid: pid_t) async throws -> WebAim? {
        guard Windows.isGecko(pid), AX.webArea(of: n.element) != nil else { return nil }
        guard let f = AX.frame(n.element) ?? n.frame else { return .press(nil) }
        // Visually hidden (an input behind a styled checkbox, a 1x1 sr-only box): only a press reaches it.
        if f.width < 4 || f.height < 4 { return .press(nil) }
        // Not on the shown part of the pages it's in (scrolled out of a frame, or of the page): scrolled to.
        guard let seen = visiblePart(n, wid) else {
            AX.act(n.element, "AXScrollToVisible")
            try await Run.pause(0.2)
            guard let seen = visiblePart(n, wid) else { return .press(nil) }  // still not: clipped away
            return aim(n, seen, wid: wid, pid: pid)
        }
        let first = aim(n, seen, wid: wid, pid: pid)
        // Covered at every point: it may be scrolled out of a scrolling pane (not a page): scrolled to, aimed again.
        if case .press(let why) = first, why != nil {
            AX.act(n.element, "AXScrollToVisible")
            try await Run.pause(0.2)
            if let seen = visiblePart(n, wid) { return aim(n, seen, wid: wid, pid: pid) }
        }
        return first
    }

    /// A click on web page pop-up `el` in window `t`, posted as a click action posts one where the page really
    /// shows it (`webAim`): Firefox opens a page's `<select>` list in a window that hasn't had a click yet only for
    /// a click (`AX.clicksOpen`). False when there's no spot of it to click (covered, clipped away, another of the
    /// app's windows over it): nothing was clicked.
    static func clickToOpen(_ el: AXUIElement, _ t: Target) async throws -> Bool {
        guard case .window(let w) = t,
              case .post(let p)? = try await webAim(AX.Node(element: el, frame: AX.frame(el)), w.id, pid: w.pid) else { return false }
        let r = try route(t, at: p, foreground: false)
        guard r.wid == w.id else { return false }  // a pop-up or window of the app there would take it
        await Input.primer(r)
        await pointer.move(to: p, r)
        await Input.sleep(clickTiming.aim())
        pointer.click()
        await Input.press(p, r, typist: clickTiming)
        return true
    }

    /// The part of `n` that's on screen: inside its window and every page it's nested in (a frame shows
    /// only part of its page, the page only part of the frame). Nil if less than 4x4 points of it are.
    static func visiblePart(_ n: AX.Node, _ wid: CGWindowID) -> CGRect? {
        guard var v = AX.frame(n.element) ?? n.frame else { return nil }
        if let w = Windows.info(wid) { v = v.intersection(w.frame) }
        for area in AX.webAreas(of: n.element) {
            if let af = AX.frame(area), af.width > 0, af.height > 0 { v = v.intersection(af) }
        }
        return v.isNull || v.width < 4 || v.height < 4 ? nil : v
    }

    /// Try candidate points in `f` (the shown part of `n`): the first text child's centre (a wrapped
    /// link's box centre can fall between its lines), the centre, the quarter points.
    static func aim(_ n: AX.Node, _ f: CGRect, wid: CGWindowID, pid: pid_t) -> WebAim {
        var points: [CGPoint] = []
        if let t = AX.firstText(in: n.element), let tf = AX.frame(t), tf.width >= 4, tf.height >= 4,
           f.insetBy(dx: -1, dy: -1).contains(tf) {  // an sr-only label can sit outside the button
            points.append(CGPoint(x: tf.midX, y: tf.midY))
        }
        points.append(CGPoint(x: f.midX, y: f.midY))
        for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            points.append(CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy))
        }
        var cover: AXUIElement?
        var elsewhere: CGPoint?  // the first point in another of the app's windows
        var inner = false  // a point hit a control of its own
        for p in points {
            switch reach(n, at: p, wid: wid, pid: pid) {
            case .yes: return .post(p)
            case .otherWindow: if elsewhere == nil { elsewhere = p }
            case .nothing: break
            case .inner: inner = true
            case .covered(let el): if cover == nil { cover = el }
            }
        }
        if let cover { return .press("looks covered by \(coverName(cover)) (if that's a banner or dialog, deal with it first)") }
        // Points in another of the app's windows (the user's, over this one) say nothing about the page,
        // but posted clicks go to this window by number (the caller checks no other window takes it).
        if let elsewhere, !inner { return .post(elsewhere) }  // unchecked: not where its own controls are
        return .press(nil)  // nothing answered, or only controls inside it did: the press is surer
    }

    enum Reach { case yes, otherWindow, nothing, inner(AXUIElement), covered(AXUIElement) }

    /// Whether a point that was aimed at no longer reaches the element (something covers it now).
    static func blocked(_ r: Reach) -> AXUIElement? {
        switch r {
        case .covered(let el), .inner(let el): return el
        default: return nil
        }
    }

    /// What a click at `p` would land on, as the app reports it: `n` (or something in it, or the frame
    /// of the nested page it's in), a control of its own inside it, something of another window, or
    /// something else covering it.
    /// Gecko's hit test skips what has no accessible (an `aria-hidden` backdrop): it reports what's under
    /// that, so the click lands on the backdrop, as a person's would.
    static func reach(_ n: AX.Node, at p: CGPoint, wid: CGWindowID, pid: pid_t) -> Reach {
        let got = reach0(n, at: p, wid: wid, pid: pid)
        if Trace.on {
            let hit = AX.element(pid: pid, at: p)
            Trace.log(["k": "webaim", "x": p.x, "y": p.y, "hit": hit.map(AX.describe) ?? "nothing",
                       "hitRole": hit.flatMap { AX.value($0, kAXRoleAttribute) as? String } ?? "", "reach": "\(got)"])
        }
        return got
    }

    private static func reach0(_ n: AX.Node, at p: CGPoint, wid: CGWindowID, pid: pid_t) -> Reach {
        guard let hit = AX.element(pid: pid, at: p) else { return .nothing }
        if AX.isInside(hit, n.element) {
            // A control inside it (a card link's Delete button) would take the click, unchecked by policy.
            if let c = innerControl(hit, n.element) { return .inner(c) }
            return .yes
        }
        // Another of the app's windows is over this point. Asking this window alone (the hit test from its
        // element) gets nothing in Firefox, so the point can't be checked.
        if let w = AX.windowID(hit), w != wid { return .otherWindow }
        // A hit test over a cross-origin frame stops at the frame: that counts only where its page shows.
        if let inner = AX.webArea(of: n.element), let shown = AX.frame(inner), shown.contains(p),
           AX.framesOf(n.element).contains(where: { CFEqual($0, hit) }) { return .yes }
        return .covered(hit)
    }

    static let controls: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXComboBox", "AXSlider",
    ]

    /// The first control from `hit` up to (not including) `node`, if any.
    static func innerControl(_ hit: AXUIElement, _ node: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = hit
        for _ in 0..<40 {
            guard let c = cur, !CFEqual(c, node) else { return nil }
            if let r = AX.value(c, kAXRoleAttribute) as? String, controls.contains(r) { return c }
            cur = AX.parent(c)
        }
        return nil
    }

    /// What covers a point, named so it can be found: its own label, else its text, then the nearest
    /// labelled container on the page (a dialog, a banner).
    static func coverName(_ el: AXUIElement) -> String {
        let own = AX.describe(el)
        if own.contains("\"") { return own }
        var name = own.isEmpty ? "something" : own
        if AX.value(el, kAXRoleAttribute) as? String == "AXStaticText",
           let v = AX.value(el, kAXValueAttribute) as? String, !v.isEmpty {
            name = "text \"\(AX.clip(v, 40))\""
        }
        var cur = AX.parent(el)
        for _ in 0..<8 {
            guard let c = cur, AX.value(c, kAXRoleAttribute) as? String != "AXWebArea" else { break }
            let d = AX.describe(c)
            if d.contains("\"") { return "\(name) in \(d)" }
            cur = AX.parent(c)
        }
        return name
    }

    /// How the note names what an action aims at.
    static func aimName(_ a: [String: Any]) -> String {
        if let e = num(a["element"]) { return "element \(Int(e))" }
        if let t = a["target"], let sp = try? spec(t) { return sp.description }
        return "the element"
    }
}

extension AX {
    static func parent(_ el: AXUIElement) -> AXUIElement? {
        value(el, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// The web page (AXWebArea) `el` is in, if any: the nearest one.
    static func webArea(of el: AXUIElement) -> AXUIElement? {
        webAreas(of: el).first
    }

    /// The web pages `el` is in, nearest first: a frame's page, then the page holding the frame, …
    static func webAreas(of el: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var cur: AXUIElement? = el
        for _ in 0..<120 {
            guard let c = cur else { break }
            let role = value(c, kAXRoleAttribute) as? String
            if role == "AXWebArea" { out.append(c) }
            if role == "AXWindow" { break }
            cur = parent(c)
        }
        return out
    }

    /// When `el` is in a nested page (an iframe), the elements from that page up to (not including) the
    /// page holding it: a hit test over a cross-origin frame stops at one of them. Empty otherwise.
    static func framesOf(_ el: AXUIElement) -> [AXUIElement] {
        guard let inner = webArea(of: el) else { return [] }
        var chain: [AXUIElement] = [inner]
        var cur = parent(inner)
        for _ in 0..<40 {
            guard let c = cur else { return [] }
            if value(c, kAXRoleAttribute) as? String == "AXWebArea" { return chain }  // the outer page
            chain.append(c)
            cur = parent(c)
        }
        return []  // no outer page: the top-level one
    }

    /// The first static text inside `el`, breadth first, a few levels down.
    static func firstText(in el: AXUIElement) -> AXUIElement? {
        var level = [el]
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for e in level {
                for c in children(e) {
                    if value(c, kAXRoleAttribute) as? String == "AXStaticText" { return c }
                    next.append(c)
                }
            }
            if next.isEmpty || next.count > 200 { return nil }
            level = next
        }
        return nil
    }
}
