import AppKit
import QuartzCore

/// One human-like pointer movement: a gently curved cubic Bézier travelled with a minimum-jerk
/// (bell-shaped) velocity profile, with a small overshoot and corrective sub-movement on long moves.
struct CursorMotion {
    let a: CGPoint, c1: CGPoint, c2: CGPoint, b: CGPoint
    let overshoot: Double  // how far past the end (in path parameter) the primary movement goes
    let primary: Double  // seconds
    let correction: Double  // seconds
    var lane = false  // kept to a lane (a menu row): straight or nearly

    var duration: Double { primary + correction }

    static func minJerk(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (10 - 15 * t + 6 * t * t)
    }

    /// Path parameter `elapsed` seconds in: 0 → 1+overshoot, then back to 1.
    func progress(_ elapsed: Double) -> Double {
        if elapsed < primary { return (1 + overshoot) * Self.minJerk(elapsed / primary) }
        return 1 + overshoot - overshoot * Self.minJerk((elapsed - primary) / max(correction, 0.001))
    }

    func point(_ s: Double) -> CGPoint {
        if s > 1 {  // past the end: continue along the arrival direction
            return CGPoint(x: b.x + 3 * (b.x - c2.x) * (s - 1), y: b.y + 3 * (b.y - c2.y) * (s - 1))
        }
        let u = 1 - s
        let w0 = u * u * u, w1 = 3 * u * u * s, w2 = 3 * u * s * s, w3 = s * s * s
        return CGPoint(x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
                       y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y)
    }

    /// Plan a move. Candidate arcs bend either way by different amounts; the winner keeps the pointer over
    /// the target window (it's drawn just above that window) and prefers gentle curves. A `lane` is
    /// somewhere the path must stay (a menu row, so the move doesn't stray onto the next item): flatter
    /// arcs are tried, down to a straight line.
    static func plan(from a: CGPoint, to b: CGPoint, within frame: CGRect?, speed: Double, lane: Bool = false) -> CursorMotion {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        let dir = d > 0 ? CGPoint(x: dx / d, y: dy / d) : .zero
        let normal = CGPoint(x: -dir.y, y: dir.x)
        func at(_ along: Double, _ side: Double) -> CGPoint {
            CGPoint(x: a.x + dir.x * along + normal.x * side, y: a.y + dir.y * along + normal.y * side)
        }
        var best = (at(d / 3, 0), at(2 * d / 3, 0))
        var bestScore = -Double.infinity
        for sign in [1.0, -1.0] {
            for k in lane ? [0, 0.015, 0.03, 0.05] : [0.07, 0.11, 0.16] {  // → arcs bulging roughly 4-10% of the distance
                let bend = sign * min(k * d * Double.random(in: 0.8...1.2), 140)
                // Arcs bulge early and straighten for the approach, like a wrist movement.
                let c1 = at(0.28 * d, bend), c2 = at(0.74 * d, bend * 0.45)
                var inside = 1.0
                if let f = frame?.insetBy(dx: lane ? 0 : -6, dy: lane ? 0 : -6), f.width > 0 {
                    let probe = CursorMotion(a: a, c1: c1, c2: c2, b: b, overshoot: 0, primary: 1, correction: 0)
                    let samples = stride(from: 0.05, through: 0.95, by: 0.05).map { probe.point($0) }
                    inside = Double(samples.filter { f.contains($0) }.count) / Double(samples.count)
                }
                // Staying over the window dominates; among those, pick a natural-looking arc at random.
                let score = (lane ? 10 : 2) * inside - 0.3 * k + Double.random(in: 0...0.12)
                if score > bestScore { bestScore = score; best = (c1, c2) }
            }
        }
        // Fitts's law: time grows with log(distance / target size).
        let t = fitts(d) / max(speed, 0.05)
        let arrivalSpeed = 3 * hypot(b.x - best.1.x, b.y - best.1.y)  // path units → points
        var over = d > 160 && !lane ? Double.random(in: 0.015...0.035) : 0
        if arrivalSpeed > 0 { over = min(over, 12 / arrivalSpeed) }
        return CursorMotion(a: a, c1: best.0, c2: best.1, b: b, overshoot: over,
                            primary: over > 0 ? t * 0.84 : t, correction: over > 0 ? t * 0.16 + 0.04 : 0, lane: lane)
    }

    /// Seconds to reach a target `d` points away at human pace.
    static func fitts(_ d: Double) -> Double { min(0.85, max(0.14, 0.11 + 0.09 * log2(1 + d / 14))) }
}

/// A drag along the agent's own path: straight between its points (they matter, e.g. when drawing).
/// Gentle bends are taken in one bell-shaped sweep; at a sharp corner (over 55°) the hand slows to a
/// stop, pauses a beat and sets off again, so each leg has its own bell.
struct StrokeMotion {
    struct Leg {
        let pts: [CGPoint]
        let lengths: [Double]  // cumulative length at each point
        let start: Double
        let duration: Double
    }

    let pts: [CGPoint]
    let legs: [Leg]
    let duration: Double

    init(_ pts: [CGPoint], speed: Double) {
        self.pts = pts
        var groups: [[CGPoint]] = [[pts[0]]]
        for i in 1..<max(1, pts.count) {
            groups[groups.count - 1].append(pts[i])
            guard i < pts.count - 1 else { continue }
            let (a, b, c) = (pts[i - 1], pts[i], pts[i + 1])
            let v1 = (b.x - a.x, b.y - a.y), v2 = (c.x - b.x, c.y - b.y)
            let n1 = hypot(v1.0, v1.1), n2 = hypot(v2.0, v2.1)
            if n1 > 0.5, n2 > 0.5, (v1.0 * v2.0 + v1.1 * v2.1) / (n1 * n2) < cos(55 * Double.pi / 180) { groups.append([b]) }
        }
        var legs: [Leg] = []
        var t = 0.0
        for (k, g) in groups.enumerated() {
            var acc = 0.0, lengths = [0.0]
            for (p, q) in zip(g, g.dropFirst()) {
                acc += hypot(q.x - p.x, q.y - p.y)
                lengths.append(acc)
            }
            // Dragging is slower than pointing: the button is held and the end usually has to be precise.
            let d = min(1.6, max(0.18, 0.14 + 0.12 * log2(1 + acc / 14))) / max(speed, 0.05)
            legs.append(Leg(pts: g, lengths: lengths, start: t, duration: d))
            t += d
            if k < groups.count - 1 { t += Double.random(in: 0.03...0.08) / max(speed, 0.05) }  // a beat at the corner
        }
        self.legs = legs
        duration = t
    }

    func point(_ elapsed: Double) -> CGPoint {
        guard let leg = legs.last(where: { $0.start <= elapsed }) ?? legs.first, let total = leg.lengths.last, total > 0 else {
            return pts[0]
        }
        let s = CursorMotion.minJerk(min(1, max(0, (elapsed - leg.start) / leg.duration))) * total
        let p = leg.pts
        guard let i = leg.lengths.firstIndex(where: { $0 >= s }), i > 0 else { return p[0] }
        let f = (s - leg.lengths[i - 1]) / max(leg.lengths[i] - leg.lengths[i - 1], 1e-9)
        return CGPoint(x: p[i - 1].x + (p[i].x - p[i - 1].x) * f, y: p[i - 1].y + (p[i].y - p[i - 1].y) * f)
    }
}

/// A hand holding still with a button down: never perfectly still. A faint tremor (~10 Hz, a fraction of
/// a point) that starts and ends exactly on the spot. Apps that track a press (text selection, sliders)
/// stop waiting for movement after a moment and treat the press as a click unless drags keep coming.
struct HoldMotion {
    let p: CGPoint
    let duration: Double
    private let fx = Double.random(in: 8.5...11.5), fy = Double.random(in: 8.5...11.5)
    private let phx = Double.random(in: 0..<(2 * .pi)), phy = Double.random(in: 0..<(2 * .pi))
    private let amp = Double.random(in: 0.25...0.45)

    init(at p: CGPoint, duration: Double) {
        self.p = p
        self.duration = duration
    }

    func point(_ elapsed: Double) -> CGPoint {
        let e = sin(.pi * min(1, max(0, elapsed / max(duration, 1e-6))))  // 0 at both ends
        return CGPoint(x: p.x + amp * e * sin(2 * .pi * fx * elapsed + phx),
                       y: p.y + amp * e * sin(2 * .pi * fy * elapsed + phy))
    }
}

/// The agent's own pointer. One motion drives both the cursor you see (a click-through purple arrow,
/// ordered just above the target window so it never covers whatever you're working in) and the mouse
/// events the target app receives: every frame the next point of the human-like path is drawn and sent
/// to the app as a mouse-moved (or dragged) event, so the app gets exactly the path you see, and a click
/// lands when the pointer arrives. With the cursor hidden the path is still followed, just not drawn.
@MainActor
final class Pointer {
    let tint: NSColor
    private static var motionCount = 0  // trace ids, unique across pointers

    init(tint: NSColor = Session.tints[0]) {
        self.tint = tint
    }
    static let size: CGFloat = 96  // window side; the pointer tip sits at the centre

    var enabled = true {  // draw the cursor
        didSet { if !enabled { window?.orderOut(nil) } }
    }
    var speed = 1.0  // 1 = human pace, 2 = twice as fast, 0 = jump
    var idleHide: TimeInterval = 20

    private enum Path {
        case reach(CursorMotion)
        case stroke(StrokeMotion)
        case hold(HoldMotion)

        var duration: Double {
            switch self {
            case .reach(let m): return m.duration
            case .stroke(let s): return s.duration
            case .hold(let h): return h.duration
            }
        }

        func point(_ elapsed: Double) -> CGPoint {
            switch self {
            case .reach(let m): return m.point(m.progress(elapsed))
            case .stroke(let s): return s.point(elapsed)
            case .hold(let h): return h.point(elapsed)
            }
        }

        var end: CGPoint {
            switch self {
            case .reach(let m): return m.b
            case .stroke(let s): return s.pts.last!
            case .hold(let h): return h.p
            }
        }

        /// For the trace: the planned path's defining points.
        var trace: [String: Any] {
            switch self {
            case .reach(let m):
                return ["kind": "reach", "c1": [m.c1.x, m.c1.y], "c2": [m.c2.x, m.c2.y], "overshoot": m.overshoot,
                        "primary": m.primary, "lane": m.lane]
            case .stroke(let s):
                return ["kind": "stroke", "points": s.pts.map { [$0.x, $0.y] },
                        "legs": s.legs.map { [$0.start, $0.duration] }]
            case .hold(let h):
                return ["kind": "hold", "point": [h.p.x, h.p.y]]
            }
        }
    }

    /// A movement under way: where its events go and as what.
    private struct Motion {
        let path: Path
        let start: CFTimeInterval
        let route: Route?
        let follow: ((CGPoint) -> Route?)?  // the window under each point, when the path crosses windows
        let type: CGEventType  // .mouseMoved, or a *MouseDragged while a button is held
        let button: CGMouseButton
        let flags: CGEventFlags  // including keys the session holds down
        let group: Int64  // the session's click group, for drags
        let id: Int
        var sent: CGPoint?
    }

    private var window: NSWindow?
    private let arrow = CAShapeLayer()
    private(set) var tip: CGPoint?  // global, top-left origin: where the app last saw the pointer
    private var motion: Motion?
    private var motions = 0
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastDraw: CFTimeInterval = 0
    private var tilt = 0.0
    private var idle = 0.0
    private var hideWork: DispatchWorkItem?
    private var lastWid: CGWindowID = 0  // the window it was last shown over
    private var parked: (wid: CGWindowID, offset: CGPoint)?  // where it was left there, window-relative
    private var hiding = false

    func setup() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Pointer.size, height: Pointer.size),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.sharingType = .none
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.title = "puter-use cursor"
        let view = NSView(frame: w.contentLayoutRect)
        view.wantsLayer = true
        view.layer = CALayer()
        w.contentView = view

        // Classic arrow with its tip at the layer origin (the rotation pivot), y-up.
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 23), (6, 17.5), (10.5, 27), (14.5, 25.3), (10.2, 16), (17.5, 16)]
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: $0.0, y: -$0.1) })
        path.closeSubpath()
        let purple = tint.cgColor
        arrow.path = path
        arrow.fillColor = purple
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.6
        arrow.lineJoin = .round
        arrow.shadowColor = purple
        arrow.shadowOpacity = 0.55
        arrow.shadowRadius = 5
        arrow.shadowOffset = .zero
        arrow.position = CGPoint(x: Pointer.size / 2, y: Pointer.size / 2)
        view.layer?.addSublayer(arrow)
        window = w
    }

    /// Move to `p` (global, top-left origin) the way a hand would, sending the path to `route` as it's
    /// drawn; returns on arrival. `button` (held down) turns the moves into drags.
    /// `follow` gives the window under each point, for a path that crosses from one window to another
    /// (into a submenu): a real mouse's events go to whichever window it's over.
    func move(to p: CGPoint, _ route: Route?, button: String? = nil, flags: CGEventFlags = [], lane: CGRect? = nil,
              follow: ((CGPoint) -> Route?)? = nil) async {
        let start = tip ?? resume(route) ?? entry(near: p, route?.frame)
        show(above: route?.wid ?? 0, at: start)
        let path: Path? = speed <= 0 || hypot(p.x - start.x, p.y - start.y) < 1 ? nil
            : .reach(CursorMotion.plan(from: start, to: p, within: lane ?? route?.frame, speed: speed, lane: lane != nil))
        await run(path, from: start, to: p, route, button: button, flags: flags, follow: follow)
    }

    /// Drag along `pts` (the button is already down at `pts[0]`), sending each frame as a dragged event.
    func stroke(_ pts: [CGPoint], _ route: Route, button: String, flags: CGEventFlags = []) async {
        guard let last = pts.last else { return }
        show(above: route.wid, at: tip ?? pts[0])
        await run(speed <= 0 || pts.count < 2 ? nil : .stroke(StrokeMotion(pts, speed: speed)), from: pts[0], to: last,
                  route, button: button, flags: flags)
    }

    /// Keep the button down for `seconds` where the pointer is, with a hand's faint tremor sent as drags.
    func hold(_ seconds: Double, _ route: Route, button: String, flags: CGEventFlags = []) async {
        guard !Task.isCancelled else { return }
        guard let p = tip, speed > 0, seconds > 0 else { return await Input.sleep(seconds) }
        show(above: route.wid, at: p)
        await run(.hold(HoldMotion(at: p, duration: seconds)), from: p, to: p, route, button: button, flags: flags)
    }

    private func run(_ path: Path?, from start: CGPoint, to p: CGPoint, _ route: Route?, button: String?,
                     flags: CGEventFlags, follow: ((CGPoint) -> Route?)? = nil) async {
        if motion != nil { land() }  // never two at once
        let (_, _, dragged, btn) = Input.buttonTypes(button ?? "left")
        Pointer.motionCount += 1
        // Captured now (in the request): frames are sent from a timer, outside it.
        let s = Session.current
        var m = Motion(path: path ?? .stroke(StrokeMotion([p], speed: 1)), start: CACurrentMediaTime(), route: route, follow: follow,
                       type: button == nil ? .mouseMoved : dragged, button: btn, flags: flags.union(s.held),
                       group: s.clickGroup, id: Pointer.motionCount)
        guard let path else {  // jump
            emit(p, &m)
            return
        }
        Trace.plan(m.id, path: path.trace, from: start, to: p, duration: path.duration, speed: speed)
        motion = m
        startTicking()
        await withCheckedContinuation { arrivals.append($0) }
    }

    /// Back on a window after the pointer was hidden: where it was left (the app last saw it there).
    private func resume(_ route: Route?) -> CGPoint? {
        guard let r = route, let pk = parked, pk.wid == r.wid else { return nil }
        return CGPoint(x: r.frame.minX + pk.offset.x, y: r.frame.minY + pk.offset.y)
    }

    /// Where the pointer comes from when it first appears: a short way off, as if the hand was on its way.
    private func entry(near p: CGPoint, _ frame: CGRect?) -> CGPoint {
        let angle = Double.random(in: 0..<(2 * .pi))
        var start = CGPoint(x: p.x + cos(angle) * 120, y: p.y + sin(angle) * 120)
        if let f = frame?.insetBy(dx: 12, dy: 12), f.width > 0, f.height > 0 {
            start = CGPoint(x: min(max(start.x, f.minX), f.maxX), y: min(max(start.y, f.minY), f.maxY))
        }
        return start
    }

    private func show(above wid: CGWindowID, at start: CGPoint) {
        scheduleHide()
        lastWid = wid
        guard enabled, let w = window else { return }
        if !w.isVisible || hiding {
            hiding = false
            place(start)
            if !w.isVisible { w.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; w.animator().alphaValue = 1 }, completionHandler: nil)
        }
        if wid != 0 { w.order(.above, relativeTo: Int(wid)) } else { w.orderFrontRegardless() }
    }

    /// The pointer is now at `p`: tell the app, then draw it there (moving a window can take a few ms).
    /// Plain moves skip frames that barely moved; with a button down every frame is sent, since apps
    /// tracking the press give up when drags stop coming.
    private func emit(_ p: CGPoint, _ m: inout Motion) {
        tip = p
        let route = m.follow?(p) ?? m.route
        Trace.pointer(m.id, p)
        if let r = route, m.type != .mouseMoved || m.sent.map({ hypot(p.x - $0.x, p.y - $0.y) >= 0.25 }) ?? true
            || p == m.path.end {
            Input.mouse(m.type, p, r, button: m.button, flags: m.flags, group: m.group, withHeld: false)
            m.sent = p
        }
        place(p)
    }

    private func place(_ p: CGPoint) {
        guard enabled, let w = window else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        w.setFrameOrigin(NSPoint(x: p.x - Pointer.size / 2, y: primaryHeight - p.y - Pointer.size / 2))
    }

    /// Finish the current motion at its end point at once.
    /// Cut a hold short: what it kept company (keys pressed with the button down) is done.
    func endHold() {
        if case .hold = motion?.path { land() }
    }

    private func land() {
        guard var m = motion else { return }
        motion = nil
        emit(m.path.end, &m)
        finishArrivals()
    }

    /// Press feedback, as the button goes down: the pointer dips and a ring ripples out from the tip.
    func click() {
        guard enabled, let layer = window?.contentView?.layer else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, 0.8, 1]
        pulse.keyTimes = [0, 0.4, 1]
        pulse.duration = 0.18
        arrow.add(pulse, forKey: "pulse")

        let ring = CAShapeLayer()
        let r: CGFloat = 16
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = CGPoint(x: Pointer.size / 2, y: Pointer.size / 2)
        ring.fillColor = tint.withAlphaComponent(0.25).cgColor
        ring.strokeColor = tint.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer.insertSublayer(ring, below: arrow)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
    }

    private func startTicking() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let frame = min(0.05, now - lastTick)
        lastTick = now
        var vx = 0.0
        if var m = motion {
            // Sample by wall-clock time, so a busy frame doesn't stretch the movement.
            let elapsed = now - m.start
            let before = tip ?? m.path.point(0)
            if elapsed >= m.path.duration {
                land()
            } else {
                let p = m.path.point(elapsed)
                vx = (p.x - before.x) / max(frame, 0.001)
                emit(p, &m)
                motion = m
            }
            idle = 0
        } else {
            idle += frame
            if window?.isVisible != true {  // nothing to move or draw
                timer?.invalidate()
                timer = nil
                return
            }
        }
        // Idle sway needs only 30 frames a second.
        guard enabled, motion != nil || now - lastDraw >= 1.0 / 30 else { return }
        let dt = min(0.05, now - lastDraw)
        lastDraw = now
        // Lean into horizontal motion; once settled, a slow sway so the pointer looks alive.
        let lean = max(-0.16, min(0.16, -vx * 0.00022))
        let sway = motion == nil ? 0.05 * sin(idle * 1.6) * min(1, idle) : 0
        tilt += (lean + sway - tilt) * min(1, dt * 12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        CATransaction.commit()
    }

    private func finishArrivals() {
        let waiting = arrivals
        arrivals = []
        for c in waiting { c.resume() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleHide, execute: work)
    }

    /// Fade the cursor out and forget where it was (the next move enters afresh).
    func hide() {
        land()
        if let t = tip, lastWid != 0, let f = Windows.info(lastWid)?.frame {
            parked = (lastWid, CGPoint(x: t.x - f.minX, y: t.y - f.minY))
        }
        tip = nil
        guard let w = window, w.isVisible else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let o = self, o.hiding, o.motion == nil else { return }  // a move started meanwhile
                o.hiding = false
                o.window?.orderOut(nil)
                o.timer?.invalidate()
                o.timer = nil
            }
        })
    }
}
