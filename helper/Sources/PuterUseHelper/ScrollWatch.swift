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
        guard let p = points.first, var cur = AX.element(pid: pid, at: p) else { return false }
        for _ in 0..<40 {
            if AX.value(cur, kAXRoleAttribute) as? String == "AXScrollArea" {
                let attr = vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
                guard let bar = AX.value(cur, attr).flatMap({ CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }),
                      let v = (AX.value(bar, kAXValueAttribute) as? NSNumber)?.doubleValue else { return false }
                return forward ? v >= 0.999 : v <= 0.001
            }
            guard let up = AX.parent(cur) else { return false }
            cur = up
        }
        return false
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
}
