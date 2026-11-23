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
    let began = Date()
    var visibleBefore = Set<CGWindowID>(), existedBefore = Set<CGWindowID>()  // the app's windows at the start
    var moved = false  // the batch switched to another window: old coordinates don't apply to it
    var heldKeys: [(name: String, code: CGKeyCode, flag: CGEventFlags)] = []
    var heldButton: (button: String, route: Route, at: CGPoint)?  // `at`: where it went down
    var buttonKeys: [String] = []  // keys pressed with mouse_down's own keys, let go with mouse_up
    var clipboard: String?  // read by a clipboard action, for the result
    var ranMenu: String?  // the full path the last menu action ran, if it was given by name alone (its macro step)
    var pidAtStart: pid_t = 0
    var locked = Set<pid_t>()  // apps this batch has the lock of (`AppLocks`)
    var changeBase: (wid: CGWindowID, sig: Signature)?  // the window before anything ran, for wait_for {change}
    /// The web page the action under way may take the window away from (a link it follows, a form it sends), set
    /// as it presses: the batch waits for the new page before going on (`Handlers.awaitPage(after:)`).
    var pageMark: Handlers.PageMark?
    /// The target window's Reload button, once looked for (`Handlers.reloadButton`): nil inside, none found.
    var reload: (wid: CGWindowID, button: Handlers.ReloadButton?)?

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

    /// Quitting: batches under way stop at their next step and let go of what they hold, as when their
    /// client hangs up. What's still held after `seconds` is let go of here (`abandonAll`). `quit`, a signal
    /// and an AppKit quit can each ask; the stop runs once, and a later ask waits for it.
    @MainActor static func stopAll(within seconds: Double) async {
        if stopping == nil {
            stopping = Task { @MainActor in
                Connection.quitting = true
                let end = ProcessInfo.processInfo.systemUptime + seconds
                while !active.isEmpty, ProcessInfo.processInfo.systemUptime < end { await Input.ms(10) }
                await Connection.ungated { await abandonAll() }  // not held back as the quit's own request would be
                stopped = true
            }
        }
        await stopping?.value
    }

    static var stopping: Task<Void, Never>?
    static var stopped = false  // `stopAll` has finished: nothing is left to stop

    /// Once quitting has begun the helper drops every request, so it must go: if AppKit's terminate hasn't
    /// ended it within `seconds` (it was cancelled), this does.
    static func exitLater(_ seconds: Double = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                Clipboard.putBack()
                Hold.releaseAll()
            }
            exit(0)
        }
    }

    /// What the agent last saw of each window's surroundings (set when it's shown a screenshot).
    static var seen: Store<CGWindowID, WindowSet> { Session.current.seen }

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

    /// Whether all that opened over the target since the agent last saw it are pop-ups (menus, suggestions or
    /// saved-data lists: `popupLayer`), which Escape closes, and nothing else changed. For the stop's words.
    func onlyPopupsOpened() -> Bool {
        guard case .window(let w) = target, let old = Run.seen[w.id] else { return false }
        let now = WindowSet.of(w)
        let opened = now.over.subtracting(old.over)
        guard !opened.isEmpty, old.over.isSubset(of: now.over), now.size == old.size else { return false }
        return Run.onlyPopups(opened.map { Windows.info($0)?.layer })
    }

    /// Whether windows on these layers (nil: gone, or not known) are all pop-ups that Escape closes.
    nonisolated static func onlyPopups(_ layers: [Int?]) -> Bool {
        !layers.isEmpty && layers.allSatisfy { $0.map(popupLayer) == true }
    }

    /// The layers of menus and of pop-ups that behave like them (a page's suggestions or saved-data list): above
    /// windows, panels and the menu bar, below the system's overlays. A sheet or dialog isn't one.
    nonisolated static func popupLayer(_ layer: Int) -> Bool { layer >= 100 && layer < 1000 }

    /// The window set over the target just before an action that may open something, for `settle`.
    func baseline() -> (wid: CGWindowID, set: WindowSet)? {
        guard case .window(let w) = target else { return nil }
        return (w.id, WindowSet.of(w))
    }

    /// After an action that may open something (a click, Return, a shortcut, a menu item): give a sheet,
    /// dialog or menu a moment to appear, and if one does, let it finish animating in before the next
    /// action. Costs ~0.15 s when nothing opens. `before` (`baseline`): with a window that opened during the
    /// action itself (an accessibility press or a menu command can make a sheet at once), only the wait for
    /// it to finish animating in is left.
    func settle(since before: (wid: CGWindowID, set: WindowSet)? = nil) async throws {
        guard case .window(let w) = target else { return }
        let t0 = ProcessInfo.processInfo.systemUptime
        let seen = try await Run.settle(start: WindowSet.of(w), since: before?.wid == w.id ? before?.set : nil,
                                        read: { WindowSet.of(w) }, frames: { $0.compactMap { Windows.info($0)?.frame } },
                                        pause: { try await Run.pause($0) })
        if Trace.on {
            Trace.log(["k": "between", "change": seen.rawValue, "ms": Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)])
        }
    }

    /// Where `settle` saw a window open or close, or the target resize: none, during the action (against
    /// `baseline`), or while it looked afterwards.
    enum Settled: String { case nothing = "none", action, after }

    /// `settle`'s steps, with the window set (`read`), the frames of windows over the target (`frames`) and
    /// the clock (`pause`) passed in. `start`: the set as the action ended; `before`: just before it.
    static func settle(start: WindowSet, since before: WindowSet?, read: () -> WindowSet,
                       frames: (Set<CGWindowID>) -> [CGRect], pause: (Double) async throws -> Void) async throws -> Settled {
        var now = start
        let seen: Settled
        if openedDuring(before, start) {
            seen = .action
        } else {
            for _ in 0..<6 {
                try await pause(0.025)
                now = read()
                if now != start { break }
            }
            guard now != start, now.size != nil else { return .nothing }
            seen = .after
        }
        var last = frames(now.over)
        for _ in 0..<15 {  // until nothing over the window moves or grows (sheets slide in)
            try await pause(0.04)
            let next = frames(now.over)
            if next == last { break }
            last = next
        }
        try await pause(0.08)  // and draws its contents
        return seen
    }

    /// Whether a window opened over the target during the action: in `now` (as it ended), not in `before`.
    /// One closing, or a resize, isn't: something may still be about to open, so `settle` looks as before.
    nonisolated static func openedDuring(_ before: WindowSet?, _ now: WindowSet) -> Bool {
        guard let before, now.size != nil else { return false }
        return !now.over.subtracting(before.over).isEmpty
    }

    /// Wait `seconds`, in short slices: stops (Cancelled) as soon as the client hangs up.
    static func pause(_ seconds: Double) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            try Connection.check()
            let left = end - ProcessInfo.processInfo.systemUptime
            if left <= 0 { return }
            await Input.sleep(min(0.05, left))
        }
    }

    /// Switch the rest of the batch to `w` (a window the batch opened), keeping it ready for keys. With a
    /// `box`, a window that wasn't there when the batch started is shrunk to it first, as `Handlers.follow`
    /// does (smaller, it may also fit on screen), unless its app is just launching or the user may have
    /// opened it (`arrange`).
    func moveTo(_ w: WinInfo, note: String? = nil) async throws {
        let may = arrange(w.pid)
        let fitTo = may.fit ? fitBox(for: w.id) : nil
        let leftAlone = may.users ? Run.leftAloneNote(w.frame.size, box: fitBox(for: w.id)) : ""
        target = .window(w)
        Handlers.current = w.id
        moved = true
        visibleBefore.insert(w.id)
        existedBefore.insert(w.id)
        let noted = Handlers.notes.count
        Handlers.notes.append((note ?? "now on new window #\(w.id)") + leftAlone)
        Connection.current?.work.opened.append(w.id)
        if !locked.contains(w.pid) {  // another app: wait for any other session driving it
            try await AppLocks.acquire(w.pid)
            locked.insert(w.pid)
        }
        try Connection.check()
        if let fitTo {
            let was = (Windows.info(w.id) ?? w).frame.size
            if AX.fit(pid: w.pid, wid: w.id, box: fitTo),
               let f = try await Run.resized(to: CGSize(width: min(was.width, fitTo.width), height: min(was.height, fitTo.height)),
                                             frame: { Windows.info(w.id)?.frame }) {
                if noted < Handlers.notes.count { Handlers.notes[noted] += ", sized to \(Int(f.width))x\(Int(f.height)) pt" }
                target = .window(Windows.info(w.id) ?? w)
            }
        }
        if !foreground, may.place, let to = Run.placeOnScreen(w) {
            try await Run.placed(w.id, at: to)
            target = .window(Windows.info(w.id) ?? w)
        }
        if !foreground, !Hold.isFront(w.pid) {
            _ = Hold.activate(pid: w.pid, wid: w.id)
            SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
            await Input.ms(40)
        }
    }

    /// What to shrink window `id` to as the batch moves to it: the box, only for a window that wasn't there
    /// when the batch started (one it opened). The user's windows are never resized.
    func fitBox(for id: CGWindowID) -> CGSize? { existedBefore.contains(id) ? nil : box }

    /// Whether app `pid` started during this batch or less than `launchGrace` s before it. Its new windows
    /// may then be ones it opened or restored as it launched (the user's last session), so they keep their
    /// size: the box is only for windows the agent opens.
    func launching(_ pid: pid_t) -> Bool { Run.launching(started: Run.startTime(pid), batchBegan: began) }

    nonisolated static let launchGrace: TimeInterval = 10

    /// What may be done with a new window of app `pid` as the batch meets it, read now: see the static one.
    func arrange(_ pid: pid_t) -> (fit: Bool, place: Bool, follow: Bool, users: Bool) {
        let span = Date().timeIntervalSince(began) + Run.userLead
        return Run.arrange(launching: launching(pid), front: Hold.isFront(pid),
                           userPressed: Run.sinceUser(Run.opening) < span, userTyped: Run.sinceUser([.keyDown]) < span,
                           foreground: foreground)
    }

    /// Shrink a new window to the box (`fit`), move it wholly on screen (`place`), and make it the batch's
    /// target (`follow`, for `Handlers.follow`; navigate's and open's own window is always moved to)? None of
    /// them when the user may have opened it (`users`): the app is their front app and they've pressed a
    /// modifier key or a mouse button since just before the batch began (their Cmd+N, Cmd+click, a click on
    /// a link that opens a window). A plain key can open one too (Return on a default button, Space on a
    /// focused one), so the user's typing also stops the follow, but not the shrinking and moving: the
    /// agent's own navigate windows keep the box while the user types. In foreground mode the agent's own
    /// input looks like theirs, so a new window is followed there as before. No shrinking while the app is
    /// launching either (`launching`).
    nonisolated static func arrange(launching: Bool, front: Bool, userPressed: Bool, userTyped: Bool = false,
                                    foreground: Bool = false) -> (fit: Bool, place: Bool, follow: Bool, users: Bool) {
        let users = front && userPressed
        let maybeTheirs = front && (userPressed || userTyped)
        return (fit: !launching && !users, place: !users, follow: !maybeTheirs || foreground, users: users)
    }

    /// A window the user asks for just before the batch begins may only appear during it.
    nonisolated static let userLead: TimeInterval = 2

    /// The user's real input that stops a new window being shrunk or moved: a modifier key going down or up
    /// (Cmd+N, Shift+Return, Cmd+click) and a mouse button going down. Moving the pointer or scrolling opens
    /// no window; plain keys (`.keyDown`) only stop the follow (`arrange`).
    nonisolated static var opening: [CGEventType] { [.flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] }

    /// Seconds since the user last did one of `types`, through the HID system (what puter-use posts to an
    /// app doesn't count). `since` gives the seconds since the last event of a type (injected by tests).
    nonisolated static func sinceUser(
        _ types: [CGEventType],
        _ since: (CGEventType) -> Double = { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
    ) -> Double {
        types.map(since).min() ?? .infinity
    }

    /// The note for a new window `Handlers.follow` didn't switch to, as the user may have opened it.
    nonisolated static func notFollowedNote(id: CGWindowID, title: String, app: String) -> String {
        let t = title.isEmpty ? "" : " \"\(AX.clip(title, 40))\""
        return "a new window #\(id)\(t) opened in \(app) while the user was using it: not switched to, as it may be "
            + "theirs. If your action was meant to open one (cmd+n, a link to a new window), pass window=\(id)"
    }

    /// Added to a new window's note when it was left as it is because the user may have opened it, and the
    /// box would have shrunk it.
    nonisolated static func leftAloneNote(_ size: CGSize, box: CGSize?) -> String {
        guard let box, size.width > box.width + 1 || size.height > box.height + 1 else { return "" }
        return ", not resized: the user may have opened it"
    }

    nonisolated static func launching(started: Date?, batchBegan: Date) -> Bool {
        guard let started else { return false }
        return started > batchBegan.addingTimeInterval(-launchGrace)
    }

    /// When process `pid` started, or nil if it's gone.
    nonisolated static func startTime(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// After asking for a window to be resized to `size`: its frame once it's that size (give or take a
    /// point, so then exactly `size`: a frame read on the way, 1441x901 for 1440x900, isn't where it ends),
    /// or after `timeout` s whatever it is then (an app may keep a minimum size). nil if it's gone.
    static func resized(to size: CGSize, timeout: Double = 0.3, floor: Double = 0, frame: () -> CGRect?) async throws -> CGRect? {
        func there(_ f: CGRect) -> Bool { abs(f.width - size.width) <= 1 && abs(f.height - size.height) <= 1 }
        guard var f = try await framed(timeout: timeout, floor: floor, frame: frame, there: there) else { return nil }
        if there(f) { f.size = size }
        return f
    }

    /// After asking for a window to be moved or resized: its frame, looked at every 20 ms, once `there`
    /// holds for it but not before `floor` s (it lays out and draws there a moment after), or after
    /// `timeout` s whatever it is then. nil if it's gone.
    static func framed(timeout: Double, floor: Double = 0, frame: () -> CGRect?,
                       there: (CGRect) -> Bool) async throws -> CGRect? {
        try await poll(floor: floor, every: 0.02, cap: timeout, frame) { $0.map(there) ?? true }
    }

    /// Look (`look`) after `floor` s, then every `every` s, until `done` takes what it sees (returned) or `cap` s
    /// from the start have passed (what it saw last, at the end). Stops (Cancelled) as soon as the client hangs up.
    static func poll<T>(floor: Double, every: Double, cap: Double, _ look: () -> T,
                        until done: (T) -> Bool) async throws -> T {
        let end = ProcessInfo.processInfo.systemUptime + cap
        try await pause(min(floor, cap))
        while true {
            let seen = look()
            if done(seen) { return seen }
            let left = end - ProcessInfo.processInfo.systemUptime
            if left <= 0 { return seen }
            try await pause(min(every, left))
        }
    }

    /// `poll` for something to come true: whether `ready` did before the cap.
    static func pollUntil(floor: Double, every: Double, cap: Double, _ ready: () -> Bool) async throws -> Bool {
        try await poll(floor: floor, every: every, cap: cap, ready) { $0 }
    }

    /// `f` is `to`, give or take a point at each edge.
    nonisolated static func matches(_ f: CGRect, _ to: CGRect) -> Bool {
        abs(f.minX - to.minX) <= 1 && abs(f.minY - to.minY) <= 1 && abs(f.maxX - to.maxX) <= 1 && abs(f.maxY - to.maxY) <= 1
    }

    /// A window the batch opened, moved wholly on screen if it opened partly off it (`AX.bringOnScreen`),
    /// with a note. Where it was moved to, or nil if it wasn't.
    static func placeOnScreen(_ w: WinInfo) -> CGRect? {
        guard let f = AX.bringOnScreen(pid: w.pid, wid: w.id) else { return nil }
        Handlers.notes.append("window #\(w.id) opened partly off screen, where it can't be captured or clicked: "
            + "moved it onto the screen (\(Int(f.width))x\(Int(f.height)) pt)")
        return f
    }

    /// Where a window of `size` goes on `screen` (its visible area, global points) to cover as little of `avoid` as
    /// it can (the user's windows of its app: their area under it, counted once where they overlap), wholly on that
    /// screen, shrunk to it if it's bigger: of the spots that cover least, the nearest to where it is (`from`).
    /// The spots tried are those with an edge on an edge of the screen or of a window avoided, and where it is
    /// (kept on screen): the area covered changes evenly between them, so the least is at one of them.
    nonisolated static func leastCovering(size: CGSize, from: CGPoint, screen: CGRect, avoid: [CGRect]) -> CGRect {
        let w = min(size.width, screen.width), h = min(size.height, screen.height)
        func spots(_ lo: CGFloat, _ hi: CGFloat, _ len: CGFloat, _ at: CGFloat, _ edges: [CGFloat]) -> [CGFloat] {
            let all = [lo, hi - len, at] + edges.flatMap { [$0, $0 - len] }
            return Array(Set(all.map { min(max($0, lo), hi - len) })).sorted()
        }
        let xs = spots(screen.minX, screen.maxX, w, from.x, avoid.flatMap { [$0.minX, $0.maxX] })
        let ys = spots(screen.minY, screen.maxY, h, from.y, avoid.flatMap { [$0.minY, $0.maxY] })
        var best: (frame: CGRect, covered: CGFloat, away: CGFloat)?
        for x in xs {
            for y in ys {
                let f = CGRect(x: x, y: y, width: w, height: h)
                let covered = Run.covered(f, by: avoid)
                let away = hypot(x - from.x, y - from.y)
                if let b = best, covered > b.covered + 1 || (abs(covered - b.covered) <= 1 && away >= b.away) { continue }
                best = (f, covered, away)
            }
        }
        return best?.frame ?? CGRect(x: from.x, y: from.y, width: w, height: h)
    }

    /// The area of `f` that `rects` cover, overlaps counted once.
    nonisolated static func covered(_ f: CGRect, by rects: [CGRect]) -> CGFloat {
        unionArea(rects.map { $0.intersection(f) }.filter { !$0.isNull && !$0.isEmpty })
    }

    /// The area `rects` cover together, overlaps counted once.
    nonisolated static func unionArea(_ rects: [CGRect]) -> CGFloat {
        let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        var area: CGFloat = 0
        for (a, b) in zip(xs, xs.dropFirst()) {
            let spans = rects.filter { $0.minX <= a && $0.maxX >= b }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered: CGFloat = 0, top = -CGFloat.infinity
            for (lo, hi) in spans where hi > top {
                covered += hi - max(lo, top)
                top = hi
            }
            area += covered * (b - a)
        }
        return area
    }

    /// After `placeOnScreen` moved window `id` to `to`: until the window server has it there, and it's had
    /// a moment to lay out where it is now (0.15 s at most).
    static func placed(_ id: CGWindowID, at to: CGRect) async throws {
        _ = try await framed(timeout: 0.15, floor: 0.05, frame: { Windows.info(id)?.frame }) { matches($0, to) }
    }

    /// A window of `pid` that wasn't there before, once it appears (up to `timeout` seconds).
    func newWindow(pid: pid_t, timeout: Double) async throws -> WinInfo? {
        try await Run.poll(floor: 0, every: 0.04, cap: timeout, {
            Windows.all(onScreenOnly: true).first {
                $0.pid == pid && $0.layer == 0 && !existedBefore.contains($0.id) && $0.frame.width >= 200 && $0.frame.height >= 120
                    && !Handlers.systemWindow($0, AX.window(pid: pid, wid: $0.id))  // the dictation orb, as the address bar takes the focus
            }
        }) { $0 != nil }
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
    /// After a cancel, a button still down ends the drag the way `Handlers.endDrag` does.
    func releaseAll(_ typist: Typist, cancelled: Bool = false) async -> [String] {
        var released: [String] = []
        if let (button, r, at) = heldButton {
            if cancelled {
                await Handlers.endDrag(r, from: at, button: button)
            } else {
                let (_, up, _, btn) = Input.buttonTypes(button)
                let p = Handlers.pointer.tip ?? CGPoint(x: r.frame.midX, y: r.frame.midY)
                Input.mouse(up, p, r, button: btn)
            }
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
