import AppKit

/// The app's windows lying over a target, as the agent last saw them: what coordinates from its last
/// screenshot assume. A sheet, dialog or menu opening over the window (or closing), or the window being
/// resized or closed, means those coordinates may now point at something else.
struct WindowSet: Equatable {
    var over: Set<CGWindowID>  // the app's other windows overlapping the target (sheets, dialogs, menus)
    var size: CGSize?  // the target's own size; nil once it's gone

    static func of(_ w: WinInfo) -> WindowSet {
        let fresh = Windows.info(w.id)
        let frame = fresh?.frame ?? w.frame
        // In front of it, and a menu, popover or panel (a higher layer) or a sheet or dialog within it:
        // the windows clicks at its coordinates would go to instead (`Windows.popup`). Another of the
        // app's ordinary windows overlapping it doesn't change where clicks go or what's captured.
        let mine = Windows.all(onScreenOnly: true).filter { $0.pid == w.pid }  // front to back
        let front = mine.firstIndex { $0.id == w.id }.map { Array(mine[..<$0]) } ?? []
        let layer = fresh?.layer ?? w.layer
        let over = front.filter {
            $0.layer < 200 && $0.alpha > 0.05 && $0.frame.width >= 30 && $0.frame.height >= 20  // not tooltips or invisible
                && $0.frame.intersects(frame) && ($0.layer > layer || frame.insetBy(dx: -2, dy: -2).contains($0.frame))
        }
        return WindowSet(over: Set(over.map(\.id)), size: fresh?.frame.size)
    }

    /// What changed since `old`, in words, or nil.
    func change(since old: WindowSet) -> String? {
        if size == nil { return "the window closed" }
        let opened = over.subtracting(old.over), closed = old.over.subtracting(over)
        func describe(_ ids: Set<CGWindowID>) -> String {
            ids.compactMap { Windows.info($0) }.map { w in
                let kind = w.layer >= 100 ? "menu" : w.layer > 0 ? "panel" : "window"
                return "\(kind) #\(w.id) \(Int(w.frame.width))x\(Int(w.frame.height))"
            }.joined(separator: ", ")
        }
        if !opened.isEmpty { return "something opened over the window (\(describe(opened)))" }
        if !closed.isEmpty { return "a sheet, dialog or menu over the window closed" }
        if let s = size, let o = old.size, abs(s.width - o.width) > 1 || abs(s.height - o.height) > 1 {
            return "the window was resized"
        }
        return nil
    }
}

/// One act call: its target (which can change mid-batch, to a window the batch opened), what it holds
/// down, and the guard that stops pointer actions aimed by an out-of-date screenshot.
@MainActor
final class Run {
    var target: Target
    let foreground: Bool
    let guarded: Bool
    let box: CGSize?
    var visibleBefore = Set<CGWindowID>(), existedBefore = Set<CGWindowID>()  // the app's windows at the start
    var moved = false  // the batch switched to another window: old coordinates don't apply to it
    var heldKeys: [(name: String, code: CGKeyCode, flag: CGEventFlags)] = []
    var heldButton: (button: String, route: Route)?
    var buttonKeys: [String] = []  // keys pressed with mouse_down's own keys, let go with mouse_up
    var clipboard: String?  // read by a clipboard action, for the result
    var pidAtStart: pid_t = 0
    var locked = Set<pid_t>()  // apps this batch has the lock of (`AppLocks`)

    /// Batches under way, with their sessions: let go of if the helper is stopped mid-batch.
    nonisolated(unsafe) static var active: [ObjectIdentifier: (run: Run, session: Session)] = [:]

    /// Stopping (SIGTERM): what batches under way hold down is let go, and a menu one opened is closed.
    @MainActor static func abandonAll() async {
        for (run, session) in active.values {
            await Session.$current.withValue(session) {
                _ = await run.releaseAll(Typist(wpm: 0))
                if case .window(let w) = run.target, let m = AX.openMenu(pid: w.pid) { AX.closeMenu(m) }
            }
        }
        active = [:]
    }

    /// What the agent last saw of each window's surroundings (set when it's shown a screenshot).
    static var seen: [CGWindowID: WindowSet] {
        get { Session.current.seen }
        set { Session.current.seen = newValue }
    }

    init(target: Target, foreground: Bool, guarded: Bool, box: CGSize?) {
        self.target = target
        self.foreground = foreground
        self.guarded = guarded
        self.box = box
        let all = Windows.all()  // every app's: open can bring up a window in another app
        existedBefore = Set(all.map(\.id))
        visibleBefore = Set(all.filter(\.onScreen).map(\.id))
    }

    static func look(_ t: Target) {
        if case .window(let w) = t { seen[w.id] = WindowSet.of(w) }
    }

    /// Why a pointer action aimed with screenshot coordinates shouldn't run now, or nil if it may.
    func staleCoordinates() -> String? {
        guard guarded, !foreground else { return nil }
        if moved { return "the batch moved to another window, which hasn't been looked at yet" }
        guard case .window(let w) = target, let old = Run.seen[w.id] else { return nil }
        return WindowSet.of(w).change(since: old)
    }

    /// After an action that may open something (a click, Return, a shortcut, a menu item): give a sheet,
    /// dialog or menu a moment to appear, and if one does, let it finish animating in before the next
    /// action. Costs ~0.15 s when nothing opens.
    func settle() async {
        guard case .window(let w) = target else { return }
        let start = WindowSet.of(w)
        var now = start
        for _ in 0..<6 {
            await Input.ms(25)
            now = WindowSet.of(w)
            if now != start { break }
        }
        guard now != start, now.size != nil else { return }
        var frames = now.over.compactMap { Windows.info($0)?.frame }
        for _ in 0..<15 {  // until nothing over the window moves or grows (sheets slide in)
            await Input.ms(40)
            let next = now.over.compactMap { Windows.info($0)?.frame }
            if next == frames { break }
            frames = next
        }
        await Input.ms(80)  // and draws its contents
    }

    /// Switch the rest of the batch to `w` (a window the batch opened), keeping it ready for keys.
    func moveTo(_ w: WinInfo, note: String? = nil) async throws {
        target = .window(w)
        Handlers.current = w.id
        moved = true
        visibleBefore.insert(w.id)
        existedBefore.insert(w.id)
        Handlers.notes.append(note ?? "now on new window #\(w.id)")
        if !locked.contains(w.pid) {  // another app: wait for any other session driving it
            try await AppLocks.acquire(w.pid)
            locked.insert(w.pid)
        }
        if !foreground, !Hold.isFront(w.pid) {
            _ = Hold.activate(pid: w.pid, wid: w.id)
            SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
            await Input.ms(40)
        }
    }

    /// A window of `pid` that wasn't there before, once it appears (up to `timeout` seconds).
    func newWindow(pid: pid_t, timeout: Double) async -> WinInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let w = Windows.all(onScreenOnly: true).first(where: {
                $0.pid == pid && $0.layer == 0 && !existedBefore.contains($0.id) && $0.frame.width >= 200 && $0.frame.height >= 120
            }) {
                return w
            }
            await Input.ms(80)
        } while Date() < deadline
        return nil
    }

    // MARK: held keys and buttons

    func keyDown(_ name: String, _ r: Route) throws {
        let n = Keys.normalize(name)
        guard !heldKeys.contains(where: { $0.name == n }) else { return }
        let code: CGKeyCode, flag: CGEventFlags
        if let f = Keys.modifiers[n] {
            flag = f
            code = Keys.modifierOrder.first { $0.flag == f }!.code
        } else {
            (code, _) = try Keys.parseCombo([name])
            flag = []
        }
        Input.held.insert(flag)
        Input.key(code, down: true, flags: [], r)
        heldKeys.append((n, code, flag))
    }

    func keyUp(_ name: String, _ r: Route) throws {
        let n = Keys.normalize(name), flag = Keys.modifiers[n]
        guard let i = heldKeys.lastIndex(where: { $0.name == n || (flag != nil && $0.flag == flag!) }) else {
            throw HelperError("\(name) isn't held" + (heldKeys.isEmpty ? "" : " (held: \(heldKeys.map(\.name).joined(separator: ", ")))"))
        }
        let k = heldKeys.remove(at: i)
        Input.held.remove(k.flag)
        Input.key(k.code, down: false, flags: [], r)
    }

    /// Let go of everything still held at the end of the batch (keys last pressed first).
    func releaseAll(_ typist: Typist) async -> [String] {
        var released: [String] = []
        if let (button, r) = heldButton {
            let (_, up, _, btn) = Input.buttonTypes(button)
            let p = Handlers.pointer.tip ?? CGPoint(x: r.frame.midX, y: r.frame.midY)
            Input.mouse(up, p, r, button: btn)
            heldButton = nil
            released.append("\(button) button")
        }
        if !heldKeys.isEmpty, let r = try? Handlers.route(target, at: nil, foreground: foreground) {
            for k in heldKeys.reversed() {
                await Input.sleep(typist.modifierTrail())
                Input.held.remove(k.flag)
                Input.key(k.code, down: false, flags: [], r)
                released.append(k.name)
            }
        }
        heldKeys = []
        Input.held = []
        return released
    }
}
