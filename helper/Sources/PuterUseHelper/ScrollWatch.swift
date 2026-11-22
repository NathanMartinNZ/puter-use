import AppKit
import ApplicationServices

/// Watches a scroll's effect, so a scroll that runs into the end stops there: a long one at the bottom of
/// a page would otherwise go on for seconds past it. It looks at what's under a few points around the
/// pointer. The rest isn't sent once the scroll bar says it's at the end, or once the content has hardly
/// moved for about half a second (at the end it only creeps, as the overscroll rubber-bands) after it was
/// seen moving or while it shows its end (more of it past the other edge, none past this one). Content it
/// can't see move or measure (a canvas, an app with no accessibility tree) is scrolled in full, as before.
final class ScrollWatch {
    struct Spot {
        let element: AXUIElement
        let frame: CGRect
    }

    let pid: pid_t
    let points: [CGPoint]
    let vertical: Bool
    let forward: Bool  // down or right
    private var last: [Spot?]?
    private var moved = false
    private var still = 0  // looks in a row with nothing moved
    private var ended = 0  // looks in a row with the scroll bar at the end
    private var off = false  // the app answers too slowly to ask while scrolling
    private(set) var stopped = false

    /// A look every 5 steps (~150 ms). The scroll bar at the end on this many looks in a row ends it (a
    /// short rubber band, then no more); with no scroll bar, the content hardly moving on this many.
    static let endLooks = 2
    static let stillLooks = 3

    init(pid: pid_t, at p: CGPoint, within frame: CGRect, dx: Double, dy: Double) {
        self.pid = pid
        let vertical = abs(dy) >= abs(dx)
        self.vertical = vertical
        forward = vertical ? dy > 0 : dx > 0
        let along: [CGFloat] = [0, -90, 90]
        points = along.map { o in vertical ? CGPoint(x: p.x, y: p.y + o) : CGPoint(x: p.x + o, y: p.y) }
            .filter { frame.isEmpty || frame.contains($0) }
    }

    /// Asked every few steps (the first time before any), with the points sent since it was last asked:
    /// whether to stop now.
    func stop(sent: Double) -> Bool {
        guard !off, !stopped else { return stopped }
        let start = Date()
        let now = points.map(spot)
        // Don't hold the scroll up: watched no more. (Not the first look, before any scrolling: an app's
        // first accessibility answers can be slow, Firefox's especially.)
        if last != nil, Date().timeIntervalSince(start) > 0.15 {
            off = true
            return false
        }
        defer { last = now }
        // The scroll bar, where there is one, says outright: at the end on a few looks in a row is the end.
        ended = atEnd() ? ended + 1 : 0
        if Trace.on {
            let hit = points.first.flatMap { AX.element(pid: pid, at: $0) }
            Trace.log(["k": "scrollwatch", "ms": Int(Date().timeIntervalSince(start) * 1000), "moved": moved, "still": still,
                       "ended": ended, "hit": hit.map(AX.describe) ?? "nothing",
                       "spots": now.map { $0.map { "\(AX.describe($0.element)) y=\(Int($0.frame.minY))" } ?? "-" }])
        }
        if ended >= Self.endLooks {
            stopped = true
            return true
        }
        guard let last else { return false }
        // Moving: by a fair part of what was sent (a quarter: the window server's acceleration varies it).
        if let shift = Self.compare(last, now) {
            if shift >= max(8, sent / 4) {
                moved = true
                still = 0
            } else {
                still += 1
            }
        }  // nothing to tell by this time: neither
        // No scroll bar to ask (a web page): still for a while, after moving or at its end.
        guard still >= Self.stillLooks, moved || contentEnd() else { return false }
        stopped = true
        return true
    }

    /// How far the content under the points moved between two looks, in points: the most at any point,
    /// unbounded where another element is there now (nil: nothing there to tell by).
    static func compare(_ a: [Spot?], _ b: [Spot?]) -> Double? {
        var most: Double?
        for (x, y) in zip(a, b) {
            guard let x, let y else { continue }
            let shift = CFEqual(x.element, y.element)
                ? max(abs(x.frame.minX - y.frame.minX), abs(x.frame.minY - y.frame.minY)) : .infinity
            most = max(most ?? 0, shift)
        }
        return most
    }

    /// The content at `p` and where it is: something inside a scroll area or a web page (not the area
    /// itself, which stays put).
    private func spot(_ p: CGPoint) -> Spot? {
        guard let el = AX.element(pid: pid, at: p), Self.inScroller(el), let f = AX.frame(el) else { return nil }
        return Spot(element: el, frame: f)
    }

    static let scrollers: Set<String> = ["AXScrollArea", "AXWebArea"]

    static func inScroller(_ el: AXUIElement) -> Bool {
        guard let role = AX.value(el, kAXRoleAttribute) as? String, !scrollers.contains(role), role != "AXWindow" else { return false }
        var cur = AX.parent(el)
        for _ in 0..<40 {
            guard let c = cur, let r = AX.value(c, kAXRoleAttribute) as? String else { return false }
            if scrollers.contains(r) { return true }
            if r == "AXWindow" || r == "AXApplication" { return false }
            cur = AX.parent(c)
        }
        return false
    }

    /// For a scroller with no scroll bar to ask (a web page, a scrolling part of one): whether its content
    /// shows its end, going by where its first and last few children are. The scroller is the page, or the
    /// nearest element on the way up whose content runs past its edges.
    func contentEnd() -> Bool {
        guard let p = points.first, let hit = AX.element(pid: pid, at: p) else { return false }
        var cur: AXUIElement? = hit
        for _ in 0..<40 {
            guard let c = cur, let role = AX.value(c, kAXRoleAttribute) as? String, role != "AXWindow",
                  role != "AXApplication" else { return false }
            // Its first and last few children: a fixed header or footer (always in view) is usually one of them.
            let kids = AX.children(c)
            let ends = kids.count <= 8 ? kids : Array(kids.prefix(4) + kids.suffix(4))
            if let f = AX.frame(c), let extent = ends.compactMap(AX.frame).reduce(nil, { (u: CGRect?, r) in u.map { $0.union(r) } ?? r }) {
                let (lo, hi, flo, fhi) = vertical ? (extent.minY, extent.maxY, f.minY, f.maxY) : (extent.minX, extent.maxX, f.minX, f.maxX)
                let before = lo < flo - 2, after = hi > fhi + 2  // content hidden past each edge
                if before || after || role == "AXWebArea" {  // the scroller under the pointer
                    return forward ? before && !after : after && !before
                }
            }
            cur = AX.parent(c)
        }
        return false
    }

    /// Whether the scroll bar of the scroll area at the pointer is at the end it's scrolling towards.
    private func atEnd() -> Bool {
        guard let v = bar() else { return false }
        return forward ? v >= 0.999 : v <= 0.001
    }

    /// Where the scroll bar of the scroll area at the pointer is along the scroll's direction: 0 at the top
    /// (or left), 1 at the bottom (or right). Nil when that scroll area has no such bar (a web page has none
    /// to ask), or there's no scroll area there.
    func bar() -> Double? {
        guard let p = points.first, var cur = AX.element(pid: pid, at: p) else { return nil }
        for _ in 0..<40 {
            if AX.value(cur, kAXRoleAttribute) as? String == "AXScrollArea" {
                let attr = vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
                guard let bar = AX.value(cur, attr).flatMap({ CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }),
                      let v = (AX.value(bar, kAXValueAttribute) as? NSNumber)?.doubleValue else { return nil }
                return min(max(v, 0), 1)
            }
            guard let up = AX.parent(cur) else { return nil }
            cur = up
        }
        return nil
    }

    /// Where the scroll left the scroll bar, for the act's reply (`ScrollWatch.place(_:vertical:)`): nil where
    /// there's no scroll bar to ask, or the app answered too slowly while scrolling (it isn't asked again).
    func place() -> String? {
        guard !off, let v = bar() else { return nil }
        return Self.place(v, vertical: vertical)
    }

    /// A scroll bar's place (`v`, 0-1) in a few words: its ends by name ("top", "bottom"; "left end", "right
    /// end" across), else how far along it is (1-99%: "45% down", "45% across").
    static func place(_ v: Double, vertical: Bool) -> String {
        if v >= 0.999 { return vertical ? "bottom" : "right end" }
        if v <= 0.001 { return vertical ? "top" : "left end" }
        let percent = min(99, max(1, Int((v * 100).rounded())))
        return "\(percent)% " + (vertical ? "down" : "across")
    }

    /// The end a scroll runs into (`vertical`, `forward`: down or right), for the note saying it stopped there.
    static func end(vertical: Bool, forward: Bool) -> String {
        vertical ? (forward ? "the bottom" : "the top") : (forward ? "the right end" : "the left end")
    }

    /// What's under one of the points, where it is and what it says: compared before and after a step of a scroll
    /// until (`changed`).
    struct Glance {
        let spot: Spot
        let text: String?
    }

    /// What's under the points now (nil at one with nothing in a scroll area or web page there).
    func glance() -> [Glance?] {
        points.map { p in
            spot(p).map { s in
                // A text's words (a row's), else what a control is called; never a text view's whole text.
                let words = AX.value(s.element, kAXRoleAttribute) as? String == "AXStaticText"
                    ? AX.value(s.element, kAXValueAttribute) as? String : AX.label(s.element)
                return Glance(spot: s, text: words)
            }
        }
    }

    /// Whether anything moved between two glances: the content under a point moved (`compare`), something is
    /// there on one look only, or what's there says something else now (a list that reuses its rows as it
    /// scrolls). Nil: nothing under any point either time, so nothing to tell by.
    static func changed(_ a: [Glance?], _ b: [Glance?]) -> Bool? {
        var told: Bool?
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (nil, nil):
                continue
            case let (x?, y?):
                if let shift = compare([x.spot], [y.spot]), shift >= 1 { return true }
                if x.text != y.text { return true }
                told = false
            default:
                return true
            }
        }
        return told
    }

    /// The part of the scroll area or web page at `p` that's shown (clipped to those it's in and to `window`):
    /// what one step of a scroll until goes by. Nil with none there (a canvas, an app with no accessibility tree).
    static func shownScroller(pid: pid_t, at p: CGPoint, window: CGRect?) -> CGRect? {
        guard var cur = AX.element(pid: pid, at: p) else { return nil }
        for _ in 0..<40 {
            guard let role = AX.value(cur, kAXRoleAttribute) as? String, role != "AXWindow", role != "AXApplication" else { return nil }
            if scrollers.contains(role) { return AX.shownPart(cur, in: window) }
            guard let up = AX.parent(cur) else { return nil }
            cur = up
        }
        return nil
    }
}

/// scroll {until}: viewport by viewport until an element in view shows a text, so a long or lazily drawn list
/// (rows that exist only once they're scrolled to) takes one action. Its bookkeeping, apart from the screen
/// (unit-tested): the steps taken, when it stops (`observe`), how far a step goes (`step`), and what it says
/// then (`note`). It only scrolls and looks: it never clicks or types.
struct ScrollUntil {
    enum Stop: Equatable {
        case found  // an element in view shows the text
        case end  // a step moved nothing, or left the scroll bar at its end
        case limit  // max_scrolls steps taken
        case time  // `timeCap` is up
    }

    /// Steps at most (max_scrolls: 1-15, 10 when not given).
    static let defaultScrolls = 10
    static let mostScrolls = 15
    /// The whole of it, at most (s): checked after each step.
    static let timeCap: TimeInterval = 15
    /// A step without an amount goes this much less than the shown part of what's scrolled, so what was at its
    /// far edge is still in view after it.
    static let overlap = 0.1
    /// After a step, before looking: long enough for a list to draw the rows scrolled to.
    static let settle = 0.15

    let limit: Int
    private(set) var steps = 0  // sent
    private(set) var scrolls = 0  // of them, those that moved something
    private(set) var stop: Stop?

    init(maxScrolls: Any?) { limit = Self.maxScrolls(maxScrolls) }

    /// max_scrolls as given (a saved macro's step isn't checked as it runs): 1-15, 10 when not given.
    static func maxScrolls(_ v: Any?) -> Int { max(1, min(Handlers.int(v, defaultScrolls), mostScrolls)) }

    /// The look before any step: shown already, it stops there, with nothing scrolled.
    mutating func start(found: Bool) -> Stop? {
        if stop == nil, steps == 0, found { stop = .found }
        return stop
    }

    /// After a step: whether an element in view shows the text now (`found`), whether the step moved what's
    /// scrolled (`moved`), whether it left the scroll bar at the end it's going to (`atEnd`, known only where
    /// there's one), and whether the time is up (`late`). Found wins; then the end; then the step count; then
    /// the time. Nil: on to the next step.
    mutating func observe(found: Bool, moved: Bool, atEnd: Bool = false, late: Bool = false) -> Stop? {
        guard stop == nil else { return stop }
        steps += 1
        if moved { scrolls += 1 }
        if found { stop = .found }
        else if !moved || atEnd { stop = .end }
        else if steps >= limit { stop = .limit }
        else if late { stop = .time }
        return stop
    }

    /// One step, in points. Given an amount (`scroll_x`/`scroll_y`, or `direction` with `amount`, as a scroll
    /// takes them, in screenshot pixels: `ptPerPx` makes them points), that; else the shown part of what's
    /// scrolled (`viewport`) less `overlap`, along `direction` (down when not given).
    static func step(_ a: [String: Any], viewport: CGSize, ptPerPx: Double) -> (dx: Double, dy: Double) {
        let amounts = ["scroll_x", "scroll_y", "dx", "dy", "amount", "scroll_amount"]
        if amounts.contains(where: { k in a[k].map { !($0 is NSNull) } ?? false }) {
            let d = Handlers.scrollDelta(a)
            if d.dx != 0 || d.dy != 0 { return (d.dx * ptPerPx, d.dy * ptPerPx) }
        }
        let dir = a["direction"] as? String ?? a["scroll_direction"] as? String ?? "down"
        func along(_ side: CGFloat) -> Double { max(20, Double(side) * (1 - overlap)) }
        switch dir {  // (as `scrollDelta` reads it: anything else is right)
        case "up": return (0, -along(viewport.height))
        case "down": return (0, along(viewport.height))
        case "left": return (-along(viewport.width), 0)
        default: return (along(viewport.width), 0)
        }
    }

    /// Whether a step moved what's scrolled: the scroll bar went along (`bar`: before and after; where there's
    /// one), or what's under the pointer moved (`glances`: `ScrollWatch.changed`). With neither to tell by (a
    /// canvas), it's taken to have moved: the step count and the time end it.
    static func moved(bar: (Double?, Double?), glances: Bool?) -> Bool {
        let barMoved: Bool? = bar.0.flatMap { b in bar.1.map { abs($0 - b) > 1e-9 } }
        if barMoved == true || glances == true { return true }
        return barMoved == nil && glances == nil
    }

    /// Whether a step left the scroll bar at the end it's going to (`forward`: down or right), having moved it
    /// (a bar that didn't move may be another scroll area's, around the one scrolled).
    static func atEnd(bar: (Double?, Double?), forward: Bool) -> Bool {
        guard let b = bar.0, let v = bar.1, abs(v - b) > 1e-9 else { return false }
        return forward ? v >= 0.999 : v <= 0.001
    }

    /// What it says once stopped: what it looked for (`want`, as `Spec` describes it), the end it was going to
    /// (`end`: "the bottom", …), and what showed it (`found`, numbered as find lists them).
    func note(_ want: String, end: String, found: String?) -> String {
        func times(_ n: Int) -> String { n == 1 ? "once" : "\(n) times" }
        func count(_ n: Int) -> String { n == 1 ? "1 scroll" : "\(n) scrolls" }
        switch stop {
        case .found?:
            let what = found ?? want
            return steps == 0 ? "found \(what) (in view already: nothing was scrolled)" : "scrolled \(times(steps)); found \(what)"
        case .end?:
            return scrolls == 0 ? "the scroll moved nothing (at \(end) already, or nothing scrolls there); \(want) not found"
                : "reached \(end) after \(count(scrolls)); \(want) not found"
        case .limit?:
            return "stopped after \(count(steps)); \(want) not found"
        case .time?:
            return "stopped after \(count(steps)) (\(Int(Self.timeCap)) s); \(want) not found"
        case nil:
            return ""
        }
    }
}

extension Handlers {
    /// A scroll until that stopped without finding its text (`ScrollUntil.note` says how). The batch stops at it,
    /// as at a target nothing shows, unless it's the last action: then it's a note, and the end shows where it
    /// stopped.
    struct NotReached: Error, CustomStringConvertible { let description: String }

    /// scroll {until, max_scrolls}: looks for `until` (`{text, role}` or a text) first, then steps (`ScrollUntil`)
    /// and looks after each, until an element in view shows it. Found, a note names it, numbered for `element`;
    /// not found, `NotReached`. `p`: where it scrolls (routed: `r`); `ptPerPx`: a given amount's pixels to points.
    static func scrollUntil(_ a: [String: Any], _ until: Any, at p: CGPoint, _ r: Route, ptPerPx: Double, _ t: Target) async throws {
        guard case .window(let w) = t else { throw HelperError("scroll with until needs a window") }
        guard let given = try? spec(until), !given.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelperError("until is the text to scroll to: \"Load more\" or {\"text\": \"Load more\", \"role\": \"button\"}")
        }
        let sp = Spec(text: given.text, role: given.role)
        let deadline = AX.uptime() + ScrollUntil.timeCap
        func budget() -> TimeInterval { max(0.2, min(1.5, deadline - AX.uptime())) }
        var state = ScrollUntil(maxScrolls: a["max_scrolls"])
        let win = Windows.info(w.id)?.frame ?? w.frame
        let step = ScrollUntil.step(a, viewport: (ScrollWatch.shownScroller(pid: r.pid, at: p, window: win) ?? win).size,
                                    ptPerPx: ptPerPx)
        // Looks between steps at what's under the pointer and at the scroll bar (it never stops a scroll itself).
        let eye = ScrollWatch(pid: r.pid, at: p, within: r.frame, dx: step.dx, dy: step.dy)
        var glance = eye.glance()
        var found = try await untilSeen(sp, w, t, blind: glance.allSatisfy { $0 == nil }, budget: budget())
        if state.start(found: found != nil) == nil {
            await pointer.move(to: p, r)
            var bar = eye.bar()
            while state.stop == nil {
                // Each step stops where it runs into the end, as a scroll does (see ScrollWatch).
                let watch = ScrollWatch(pid: r.pid, at: p, within: r.frame, dx: step.dx, dy: step.dy)
                await Input.scroll(p, dx: step.dx, dy: step.dy, r, watch: watch)
                try Connection.check()
                try await Run.pause(ScrollUntil.settle)
                let now = try await settledGlance(eye), barNow = eye.bar()
                let moved = ScrollUntil.moved(bar: (bar, barNow), glances: ScrollWatch.changed(glance, now))
                let atEnd = ScrollUntil.atEnd(bar: (bar, barNow), forward: eye.forward)
                (glance, bar) = (now, barNow)
                found = try await untilSeen(sp, w, t, blind: now.allSatisfy { $0 == nil }, budget: budget())
                _ = state.observe(found: found != nil, moved: moved, atEnd: atEnd, late: AX.uptime() >= deadline)
            }
        }
        // Where it left the scroll bar (the reply's scroll), unless the note names the end it reached.
        Session.current.scrolled = state.stop == .end || state.steps == 0 ? nil : eye.place()
        let note = state.note(sp.description, end: ScrollWatch.end(vertical: eye.vertical, forward: eye.forward), found: found)
        if state.stop == .found { notes.append(note) } else { throw NotReached(description: note) }
    }

    /// What's under `eye`'s points once it's still: the same on two looks in a row (content pushed past the end
    /// springs back for a moment), half a second at most.
    static func settledGlance(_ eye: ScrollWatch) async throws -> [ScrollWatch.Glance?] {
        var last = eye.glance()
        return try await Run.poll(floor: 0.08, every: 0.08, cap: 0.5, eye.glance) { g in
            defer { last = g }
            return ScrollWatch.changed(last, g) != true
        }
    }

    /// Where a scroll until given no x, y, element or target scrolls (global points), when the middle of the window
    /// may be the wrong place: the middle of what's shown of the scroll area holding an element out of view that
    /// shows its text (a long list's rows are there before they're scrolled to); else of the window's largest scroll
    /// area or web page. Nil for neither (then the window's middle, as for any scroll), or when an element in view
    /// shows the text already (nothing is scrolled then).
    static func untilAim(_ until: Any, _ w: WinInfo) -> CGPoint? {
        guard let given = try? spec(until), !given.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sp = Spec(text: given.text, role: given.role)
        let win = Windows.info(w.id)?.frame ?? w.frame
        let found = candidates(sp, w, limit: 30, budget: 0.5)
        if found.contains(where: { !$0.offScreen }) { return nil }
        let away = narrowed(found + offScreenCandidates(sp, w, limit: 10, budget: 1).matches, sp)
        let holders = away.prefix(5).compactMap { m in AX.scroller(of: m.element).flatMap { AX.shownPart($0, in: win) } }
        if !holders.isEmpty { return untilAim(holders: holders, areas: []) }
        return untilAim(holders: [], areas: AX.window(pid: w.pid, wid: w.id).map { AX.scrollers(in: $0, window: win) } ?? [])
    }

    /// `untilAim`'s choice (global points): the middle of the first scroll area holding the text out of view
    /// (`holders`, what's shown of each), else of the largest of the window's scroll areas and web pages (`areas`),
    /// else nil.
    nonisolated static func untilAim(holders: [CGRect], areas: [CGRect]) -> CGPoint? {
        guard let r = holders.first ?? areas.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// What a scroll until sees of `sp` in `w` now: an element in view showing it (a whole label before one that
    /// only contains it, a control before a bare label, as a target takes them), numbered, as find lists it.
    /// Else, where accessibility sees nothing of what's scrolled (`blind`: a canvas, an app with no tree), the
    /// text read off the screen. Nil for neither. `budget`: the search's time (s).
    static func untilSeen(_ sp: Spec, _ w: WinInfo, _ t: Target, blind: Bool, budget: TimeInterval) async throws -> String? {
        let all = candidates(sp, w, limit: 30, budget: budget)
        // In view: not scrolled out of it (the search keeps what's in the window, which may be past a list's edge).
        func shown(_ m: AX.Match) -> Bool { AX.sight(m.element).map { !offScreen($0) } ?? true }
        if let m = narrowed(all, sp).first(where: shown) ?? all.first(where: shown) {
            return describe(m, id: number(m, w.id), t)
        }
        guard blind, sp.role == nil else { return nil }
        let hits = try await ocrFind(sp.text, t)
        guard let h = hits.first(where: \.exact) ?? hits.first else { return nil }
        let px = toPixels(t, CGPoint(x: h.rect.midX, y: h.rect.midY)).map { " at (\($0[0]),\($0[1]))" } ?? ""
        return "text \"\(AX.clip(h.line, 60))\"\(px) (read off the screen: click it by x,y)"
    }
}

extension AX {
    /// The part of `el` that's shown: its frame clipped to every scroll area and web page it's in and to
    /// its window. A text view's frame is its whole text, which can run far past what's visible.
    static func shownPart(_ el: AXUIElement, in window: CGRect?) -> CGRect? {
        guard var v = frame(el) else { return nil }
        var cur = parent(el)
        for _ in 0..<60 {
            guard let c = cur, let role = value(c, kAXRoleAttribute) as? String, role != "AXWindow" else { break }
            if role == "AXScrollArea" || role == "AXWebArea", let f = frame(c), f.width > 0, f.height > 0 { v = v.intersection(f) }
            cur = parent(c)
        }
        if let window { v = v.intersection(window) }
        return v.isNull || v.width < 1 || v.height < 1 ? nil : v
    }

    /// The scroll area or web page `el` is in, the nearest on the way up to its window (nil for none). `parent` and
    /// `role` are there for tests.
    static func scroller(of el: AXUIElement, parent: (AXUIElement) -> AXUIElement? = AX.parent,
                         role: (AXUIElement) -> String? = { AX.value($0, kAXRoleAttribute) as? String }) -> AXUIElement? {
        var cur = parent(el)
        for _ in 0..<60 {
            guard let c = cur, let r = role(c), r != "AXWindow", r != "AXApplication" else { return nil }
            if ScrollWatch.scrollers.contains(r) { return c }
            cur = parent(c)
        }
        return nil
    }

    /// What's shown of each scroll area and web page in window element `win` (its frame `window`), clipped to those
    /// it's in and to the window, at least 20 points each way; in about `budget` seconds. `now` and `read` are there
    /// for tests.
    static func scrollers(in win: AXUIElement, window: CGRect, budget: TimeInterval = 0.5, now: () -> TimeInterval = uptime,
                          read: (AXUIElement) -> [AnyObject]? = readAttrs) -> [CGRect] {
        var out: [CGRect] = []
        let end = now() + budget
        func walk(_ el: AXUIElement, depth: Int, clip: CGRect) {
            guard depth < 40, out.count < 50, now() < end, let vals = read(el) else { return }
            let role = vals[0] as? String ?? ""
            var inner = clip
            if let r = rect(vals[6], vals[7]), r.width > 0, r.height > 0, role != "AXWindow" {
                guard r.intersects(clip) else { return }  // out of view, and all in it
                if ScrollWatch.scrollers.contains(role) {
                    inner = clip.intersection(r)
                    if inner.width >= 20, inner.height >= 20 { out.append(inner) }
                }
            }
            for k in vals[5] as? [AXUIElement] ?? [] { walk(k, depth: depth + 1, clip: inner) }
        }
        walk(win, depth: 0, clip: window)
        return out
    }
}
