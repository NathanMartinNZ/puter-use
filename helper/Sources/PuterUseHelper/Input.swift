import AppKit
import CoreGraphics

/// Where synthesized events go: a specific process + window. In foreground mode events go through the
/// HID tap instead (moves the real cursor; only used as an explicit fallback).
struct Route {
    let pid: pid_t
    let wid: CGWindowID
    let frame: CGRect  // window frame in global points
    var foreground = false
    var primer = true  // false for menus/popovers: a click outside them would dismiss them
}

@MainActor
enum Input {
    static let source = CGEventSource(stateID: .privateState)

    static let fieldWindowUnderPointer = CGEventField(rawValue: 91)!
    static let fieldWindowThatCanHandle = CGEventField(rawValue: 92)!
    static let fieldTargetPID = CGEventField(rawValue: 40)!
    static let fieldWindowNumber = CGEventField(rawValue: 51)!  // what NSEvent(cgEvent:) reads as windowNumber
    static let fieldClickGroup = CGEventField(rawValue: 58)!
    static var primed: [CGWindowID: TimeInterval] = [:]  // when each window last got a primer click
    /// Modifiers held down by key_down (the session's): every event it sends carries them.
    static var held: CGEventFlags {
        get { Session.current.held }
        set { Session.current.held = newValue }
    }
    static var clickGroup: Int64 { Session.current.clickGroup }

    static func newClickGroup() { Session.current.clickGroup = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000) }

    static func buttonTypes(_ name: String) -> (CGEventType, CGEventType, CGEventType, CGMouseButton) {
        switch name {
        case "right": return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case "middle", "wheel": return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        }
    }

    static func mouse(_ type: CGEventType, _ p: CGPoint, _ route: Route, button: CGMouseButton = .left,
                      clickState: Int = 1, flags: CGEventFlags = [], group: Int64? = nil, withHeld: Bool = true)
    {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.flags = withHeld ? flags.union(held) : flags
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        e.setIntegerValueField(.mouseEventSubtype, value: 3)
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            e.setIntegerValueField(fieldClickGroup, value: group ?? clickGroup)
        }
        post(e, at: p, route)
    }

    /// Deliver to the target process only, stamped with its window so AppKit routes it without raising.
    static func post(_ e: CGEvent, at p: CGPoint?, _ route: Route) {
        Trace.event(e, at: p, pid: route.pid, wid: route.wid)
        if route.foreground {
            e.post(tap: .cghidEventTap)
            return
        }
        e.setIntegerValueField(fieldTargetPID, value: Int64(route.pid))
        if route.wid != 0, let p {
            for f in [fieldWindowNumber, fieldWindowUnderPointer, fieldWindowThatCanHandle] {
                e.setIntegerValueField(f, value: Int64(route.wid))
            }
            SkyLight.setWindowLocation?(e, CGPoint(x: p.x - route.frame.minX, y: p.y - route.frame.minY))
        }
        if let post = SkyLight.postToPid { post(route.pid, e) } else { e.postToPid(route.pid) }
    }

    /// A background window treats the first click it gets as an "activation click" and swallows it
    /// (unless the view accepts first mouse). Spend that click just outside the content, at (-1, -1).
    /// Never twice within a double-click interval: that spot is the window's resize corner, and a
    /// double-click there makes macOS expand the window to the screen edge.
    static func primer(_ route: Route) async {
        guard !route.foreground, route.primer, route.wid != 0 else { return }
        // The key window of an app held active takes clicks as they come: there's no activation click to spend.
        if await MainActor.run(body: { Hold.held[route.pid] != nil }), AX.focusedWindow(pid: route.pid) == route.wid { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = primed[route.wid], now - last < NSEvent.doubleClickInterval + 0.15 { return }
        primed[route.wid] = now
        let p = CGPoint(x: route.frame.minX - 1, y: route.frame.minY - 1)
        newClickGroup()
        Trace.label = "primer"
        mouse(.leftMouseDown, p, route)
        await ms(2)
        mouse(.leftMouseUp, p, route)
        Trace.label = nil
        await ms(60)
    }

    static func ms(_ n: UInt64) async { try? await Task.sleep(nanoseconds: n * 1_000_000) }

    static func sleep(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(min(seconds, 600) * 1e9))
    }

    /// Press and release at `p`, where the pointer already is, `count` times (2 = double-click), holding
    /// the button as long as a finger does.
    static func press(_ p: CGPoint, _ route: Route, button: String = "left", count: Int = 1, flags: CGEventFlags = [],
                      typist: Typist) async {
        let (down, up, _, btn) = buttonTypes(button)
        newClickGroup()
        for i in 1...max(1, count) {
            mouse(down, p, route, button: btn, clickState: i, flags: flags)
            await sleep(typist.clickHold())
            mouse(up, p, route, button: btn, clickState: i, flags: flags)
            if i < count { await sleep(typist.clickGap()) }
        }
    }

    /// Scroll by (dx, dy) points at `p` (the pointer is already there); positive dy scrolls content down
    /// (like pressing the down arrow). Sent as a trackpad-style gesture (began/changed/ended), which apps
    /// apply 1:1 without wheel acceleration.
    static func scroll(_ p: CGPoint, dx: Double, dy: Double, _ route: Route) async {
        var steps: [(Double, Double)] = []
        var remX = dx, remY = dy
        while abs(remX) >= 1 || abs(remY) >= 1 {
            // WindowServer accelerates by velocity; ~40pt per 30ms lands within ~10-20% of the request.
            let sx = max(-40, min(40, remX)), sy = max(-40, min(40, remY))
            steps.append((sx, sy))
            remX -= sx
            remY -= sy
        }
        let phaseField = CGEventField(rawValue: 99)!  // kCGScrollWheelEventScrollPhase
        func send(_ sx: Double, _ sy: Double, phase: Int64) {
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(-sy.rounded()), wheel2: Int32(-sx.rounded()), wheel3: 0)
            else { return }
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(phaseField, value: phase)
            post(e, at: p, route)
        }
        send(0, 0, phase: 1)  // began
        for (sx, sy) in steps {
            send(sx, sy, phase: 2)  // changed
            await ms(30)
        }
        send(0, 0, phase: 4)  // ended
        await ms(30)
    }

    /// One key going down or up. Modifier keys are sent as flags-changed events, as the keyboard does.
    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, _ route: Route, text: String? = nil) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if Keys.modifierCodes.values.contains(code) { e.type = .flagsChanged }
        e.flags = flags.union(held)
        if let text {
            let utf16 = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        post(e, at: nil, route)
    }

    /// Press the modifier keys in `flags`, as fingers do before a shift-click or a cmd-drag (apps check
    /// the keys, not just the click's flags). Returns them for `releaseModifiers`.
    static func pressModifiers(_ flags: CGEventFlags, _ route: Route, typist: Typist) async -> [(flag: CGEventFlags, code: CGKeyCode)] {
        let mods = Keys.modifierOrder.filter { flags.contains($0.flag) && !held.contains($0.flag) }
        for m in mods {
            held.insert(m.flag)  // the pointer's moves and presses carry it meanwhile, as with a real keyboard
            key(m.code, down: true, flags: [], route)
            await sleep(typist.modifierLead())
        }
        return mods
    }

    static func releaseModifiers(_ mods: [(flag: CGEventFlags, code: CGKeyCode)], _ route: Route, typist: Typist) async {
        for m in mods.reversed() {
            await sleep(typist.modifierTrail())
            held.remove(m.flag)
            key(m.code, down: false, flags: [], route)
        }
    }

    /// A shortcut the way fingers play it: modifiers go down one after another, then the key, which is
    /// held a moment; then it comes up and the modifiers are let go.
    static func keyCombo(_ keys: [String], _ route: Route, typist: Typist) async throws {
        let (code, flags) = try Keys.parseCombo(keys)
        let mods = Keys.modifierOrder.filter { flags.contains($0.flag) && $0.code != code && !Input.held.contains($0.flag) }
        var held: CGEventFlags = []
        for m in mods {
            held.insert(m.flag)
            key(m.code, down: true, flags: held, route)
            await sleep(typist.modifierLead())
        }
        key(code, down: true, flags: flags, route)
        await sleep(typist.dwell())
        key(code, down: false, flags: Keys.modifierCodes.values.contains(code) ? held.subtracting(flags) : flags, route)
        for m in mods.reversed() {
            await sleep(typist.modifierTrail())
            held.remove(m.flag)
            key(m.code, down: false, flags: held, route)
        }
    }

    /// Type `text` with a typist's rhythm (see `Typist`): every key goes down and comes up after a human
    /// hold, the next one may go down before the last is up, and Shift is pressed around capitals and
    /// symbols. Newlines and tabs are the Return and Tab keys.
    ///
    /// `stillSafe` is asked before every key: false stops right there (letting go of the keys still down)
    /// and is returned. A key goes to the app's key window, which may have become the user's.
    @discardableResult
    static func type(_ text: String, _ route: Route, typist: Typist, stillSafe: (() -> Bool)? = nil) async -> Bool {
        struct Stroke {
            let t: Double
            let order: Int
            let down: CGKeyCode?  // the key it holds down, if any
            let up: CGKeyCode?
            let fire: () -> Void
        }
        var strokes: [Stroke] = []
        func at(_ t: Double, down: CGKeyCode? = nil, up: CGKeyCode? = nil, _ fire: @escaping () -> Void) {
            strokes.append(Stroke(t: t, order: strokes.count, down: down, up: up, fire: fire))
        }
        let shiftCode = Keys.modifierCodes["shift"]!
        var t = 0.0, prev: Character?, prevShift = false, lastDown = -1.0
        var shiftUpAt: Double?  // Shift is down and comes up at this time unless the next key needs it too
        var upAt: [CGKeyCode: Double] = [:]
        for ch in text {
            let s = String(ch)
            var code: CGKeyCode = 0, shift = false, payload: String? = s
            switch s {
            case "\n", "\r", "\r\n": code = 0x24; payload = nil
            case "\t": code = 0x30; payload = nil
            default:
                if let (c, sh) = Keys.layout[s] { (code, shift) = (c, sh) }
                else if let base = Keys.baseKey(s) { code = base }  // é goes out on the e key, with é as its text
            }
            if prev != nil { t += typist.interval(prev, ch, shift: shift, prevShift: prevShift) }
            if let up = upAt[code] { t = max(t, up + 0.012) }  // a key can't go down again before it's up
            // Shift goes down after the previous key and before this one, and comes up after the last
            // capital went down and before the next key; at speed, this key waits for room to do so.
            let gap = 0.001
            if shift, shiftUpAt == nil {
                let pressAt = max(t - typist.modifierLead(), lastDown + gap)
                t = max(t, pressAt + gap)
                at(pressAt, down: shiftCode) { key(shiftCode, down: true, flags: .maskShift, route) }
            } else if !shift, let up = shiftUpAt {
                let liftAt = max(min(up, t - gap), lastDown + gap)
                t = max(t, liftAt + gap)
                at(liftAt, up: shiftCode) { key(shiftCode, down: false, flags: [], route) }
                shiftUpAt = nil
            }
            let flags: CGEventFlags = shift ? .maskShift : []
            let dwell = typist.dwell()
            at(t, down: code) { key(code, down: true, flags: flags, route, text: payload) }
            at(t + dwell, up: code) { key(code, down: false, flags: flags, route, text: payload) }
            upAt[code] = t + dwell
            if shift { shiftUpAt = t + dwell + typist.modifierTrail() }
            lastDown = t
            prev = ch
            prevShift = shift
        }
        if let up = shiftUpAt { at(up, up: shiftCode) { key(shiftCode, down: false, flags: [], route) } }

        let start = ProcessInfo.processInfo.systemUptime
        var pressed = Set<CGKeyCode>()
        for s in strokes.sorted(by: { ($0.t, $0.order) < ($1.t, $1.order) }) {
            await sleep(s.t - (ProcessInfo.processInfo.systemUptime - start))
            if let stillSafe, !stillSafe() {
                for code in pressed { key(code, down: false, flags: [], route) }  // leave nothing held
                return false
            }
            s.fire()
            if let d = s.down { pressed.insert(d) }
            if let u = s.up { pressed.remove(u) }
        }
        return true
    }
}
