import AppKit
import ApplicationServices

/// Bringing an app forward for a moment so it draws one of the agent's windows again. Firefox stops drawing a window
/// that gets fully covered while it isn't its key window, and only that window showing again brings it back; one that
/// was its key window as it got covered draws on. So when one of the agent's own windows is found not drawn
/// (`Frozen`), its app is brought forward with that window raised and key until the window draws, then the app the
/// user was in comes back to the front: usually well under a second. Only while the user leaves the keyboard and
/// mouse alone, never while they're in that app, over a full-screen app or onto another Space, and once a window in
/// `forwardGap` at most; cut short if the user touches the keyboard or mouse meanwhile (`forward`, `flash`).
/// `PUTER_USE_BRING_FORWARD=never` turns it off.
extension Handlers {
    /// Whether to bring a not-drawn window's app forward to redraw it (`go`), or why not.
    enum Forward: Equatable {
        case go
        case off  // PUTER_USE_BRING_FORWARD=never
        case foreground  // the act is in foreground mode: its app is brought to the front anyway
        case notCovered  // minimized, on another Space, its app hidden, or in view: coming forward wouldn't (or needn't) help
        case notOwn  // a window of the user's, or one of the agent's the user has used
        case drawsOn  // its app draws covered windows anyway (`drawsCovered`)
        case otherSpace  // not on this Space: bringing its app forward could switch Spaces
        case otherAgent  // another session's act is driving its app
        case recently  // brought forward less than `forwardGap` ago
        case appInFront  // its app is the user's front app: they're in it
        case fullScreen  // the user's front app is full screen
        case busy  // the user touched the keyboard or mouse in the last `forwardQuiet` seconds
    }

    /// How long the user must have left the keyboard and mouse alone (s).
    nonisolated static let forwardQuiet: Double = 3
    /// The least time between two flashes of one window (s).
    nonisolated static let forwardGap: TimeInterval = 30
    /// The longest a flash waits for the window to draw (s).
    nonisolated static let flashCap: Double = 1.2

    /// Structural prerequisites shared by automatic `forward` and user-approved `FocusPrompt.shouldPromptRevive`:
    /// covered (not minimized, other-Space, hidden or in view), on screen, not foreground mode, app doesn't
    /// draw covered windows on, and no other session holds its lock.
    nonisolated static func structurallyRevivable(cover: Cover, onScreen: Bool, foreground: Bool,
                                                  drawsCovered: Bool, otherAgent: Bool) -> Bool {
        !foreground && cover == .covered && !drawsCovered && onScreen && !otherAgent
    }

    /// Whether to bring the app of a window found not drawn forward for a moment: only for one that's covered
    /// (`cover`: not minimized, on another Space or with its app hidden) and on this Space (`onScreen`), one of the
    /// session's own the user hasn't used (`owner`), with the setting on (`enabled`), not in foreground mode, of an app
    /// that doesn't draw covered windows anyway (`drawsCovered`) and that no other session's act is driving
    /// (`otherAgent`), at most once in `forwardGap` (`sinceLast`: since the window was last brought forward, nil for
    /// never); and never while its app is the user's front app (`appFront`), the user's front app is full screen
    /// (`frontFullScreen`, asked last: it asks that app's accessibility) or the user has touched the keyboard or mouse
    /// in the last `forwardQuiet` seconds (`quiet` false).
    nonisolated static func forward(cover: Cover, owner: Owner, enabled: Bool, foreground: Bool, drawsCovered: Bool,
                                    onScreen: Bool, otherAgent: Bool, sinceLast: TimeInterval?, appFront: Bool,
                                    quiet: Bool, frontFullScreen: @autoclosure () -> Bool) -> Forward {
        guard enabled else { return .off }
        guard !foreground else { return .foreground }
        guard cover == .covered else { return .notCovered }
        guard owner == .agent else { return .notOwn }
        guard !drawsCovered else { return .drawsOn }
        guard onScreen else { return .otherSpace }
        guard !otherAgent else { return .otherAgent }
        if let s = sinceLast, s < forwardGap { return .recently }
        guard !appFront else { return .appInFront }
        guard quiet else { return .busy }
        return frontFullScreen() ? .fullScreen : .go
    }

    /// Why `app` wasn't brought forward (`d`), in a few words, when the agent should hear it: the user busy, in that
    /// app, or in a full-screen one. Nil otherwise.
    nonisolated static func forwardWhy(_ d: Forward, app: String) -> String? {
        switch d {
        case .busy: return "the user is busy"
        case .appInFront: return "the user is in \(app)"
        case .fullScreen: return "the user's front app is full screen"
        default: return nil
        }
    }

    /// Whether a request lets puter-use bring apps forward to redraw the agent's windows (`bring_forward`, from the
    /// setting): anything but "never" (any case), and when it doesn't say.
    nonisolated static func forwardSetting(_ v: Any?) -> Bool {
        (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased() != "never"
    }

    /// Whether a front window is full screen: its accessibility says so (`ax`), or its frame is a whole display's.
    nonisolated static func fullScreen(ax: Bool?, frame: CGRect?, displays: [CGRect]) -> Bool {
        if ax == true { return true }
        guard let frame else { return false }
        return displays.contains { Run.matches(frame, $0) }
    }

    /// Whether a browser page's tree shows the window draws again: it's there, loaded or loading.
    nonisolated static func drawnAgain(tree: PageTree?) -> Bool { tree == .shown || tree == .loading }

    /// How a flash went (`flash`).
    struct Flash: Equatable {
        var key = true  // the window came forward as its app's key window
        var drawn = false  // it drew again
        var userCame = false  // the user touched the keyboard or mouse meanwhile, so it was cut short
        var seconds = 0.0  // how long the app was in front
        var gaveBack = true  // the app the user was in is in front again
        var cameBy = Way.none  // how the app came to the front
        var backBy = Way.none  // how the app the user was in came back
    }

    /// How a flash brought an app to the front, or the user's app back: as apps are asked to come forward
    /// (`activation`), through the app's accessibility once that hadn't taken (`accessibility`), or not at all.
    enum Way: String, Equatable { case activation, accessibility, none }

    /// The way (`Way`) from whether the app was in front after it was asked as apps are (`asked`), and, if not, after
    /// its accessibility was told (`fallback`).
    nonisolated static func way(asked: Bool, fallback: Bool) -> Way {
        asked ? .activation : fallback ? .accessibility : .none
    }

    /// The helper's trace line (`Trace`) for a flash of app `pid`'s window `wid` (`r`): which way it came forward and
    /// which way the user's app came back, beside how it went. Not for the agent: its note says only how it went.
    nonisolated static func flashTrace(_ r: Flash, pid: pid_t, wid: CGWindowID) -> [String: Any] {
        ["k": "flash", "pid": Int(pid), "wid": Int(wid), "came": r.cameBy.rawValue, "back": r.backBy.rawValue, "key": r.key,
         "drawn": r.drawn, "user": r.userCame, "ms": Int((r.seconds * 1000).rounded())]
    }

    /// The note telling the agent about a flash of `app` for its window `wid` (`r`), the app the user was in being
    /// `back`.
    nonisolated static func flashNote(_ r: Flash, app: String, wid: CGWindowID, back: String) -> String {
        let what = "\(app) forward for \(String(format: "%.1f", r.seconds)) s to redraw your window #\(wid) (it had stopped "
            + "drawing while covered)"
        let then = r.gaveBack ? "gave focus back to \(back)"
            : "couldn't give focus back to \(back): \(app) may still be in front, so tell the user"
        if !r.key { return "tried to bring \(what), but #\(wid) didn't come forward; \(then)" }
        if r.userCame {
            return "brought \(what), but the user started using the keyboard or mouse, so it stopped at once"
                + (r.drawn ? " (it had drawn again)" : "") + "; \(then)"
        }
        return r.drawn ? "brought \(what), then \(then)" : "brought \(what), but it didn't draw again; \(then)"
    }

    // MARK: - doing it

    /// Whether the act under way for the request's session is in foreground mode.
    static var inForeground: Bool {
        Run.active.values.contains { $0.session === Session.current && $0.run.foreground }
    }

    /// Whether app `pid`'s front window is full screen (`fullScreen`), as its accessibility and the window server say.
    static func frontFullScreen(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, caretTimeout)
        var ax: Bool?
        if let w = AX.value(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            ax = AX.value(w as! AXUIElement, "AXFullScreen") as? Bool
        }
        let frame = Windows.all(onScreenOnly: true).first { $0.pid == pid && $0.layer == 0 }?.frame
        return fullScreen(ax: ax, frame: frame, displays: displayBounds())
    }

    /// What `forward` says for window `w`, found not drawn (`f`), as things are now (`back`: the user's front app).
    static func forwardCheck(_ w: WinInfo, _ f: Frozen, back: NSRunningApplication?) -> Forward {
        let since = Session.current.forwarded[w.id].map { ProcessInfo.processInfo.systemUptime - $0 }
        let driver = AppLocks.holder(w.pid)
        return forward(cover: f.cover, owner: owner(w.id), enabled: Connection.current?.bringForward ?? false,
                       foreground: inForeground, drawsCovered: drawsCovered(w.pid),
                       onScreen: Windows.info(w.id)?.onScreen == true,
                       otherAgent: driver != nil && driver != Session.current.id, sinceLast: since,
                       appFront: Hold.isFront(w.pid) || back?.processIdentifier == w.pid,
                       quiet: Input.userQuiet(for: forwardQuiet),
                       frontFullScreen: back.map { frontFullScreen($0.processIdentifier) } ?? false)
    }

    /// When window `w` is found not drawn (`f`): its app brought forward for a moment so it draws `w` again, when
    /// `forward` allows it (`flash`), with a note for the agent on how that went. When automatic flashing can't run
    /// (e.g. the user is in that app, busy, full-screen, or the window isn't exclusively the agent's), asks the user
    /// via `FocusPrompt` when eligible. Whether `w` is drawn now; if not, `f` says why it wasn't brought forward.
    static func revive(_ w: WinInfo, _ f: inout Frozen) async -> Bool {
        f.notForward = nil
        f.declined = false
        let back = NSWorkspace.shared.frontmostApplication
        let d = forwardCheck(w, f, back: back)
        if d == .go, let back, back.processIdentifier != Windows.ownPID {
            Session.current.forwarded[w.id] = ProcessInfo.processInfo.systemUptime
            let alreadyMine = AppLocks.holder(w.pid) == Session.current.id
            if !alreadyMine {
                do { try await AppLocks.acquire(w.pid) } catch { return false }
            }
            defer { if !alreadyMine { AppLocks.release(w.pid) } }
            guard !Connection.hungUp, Windows.info(w.id)?.onScreen == true else { return false }
            let r = await flash(w, f, back: back)
            Connection.current?.ownerNotes.append(flashNote(r, app: w.app, wid: w.id,
                                                            back: back.localizedName ?? "the app the user was in"))
            return r.drawn
        }
        // Automatic flash couldn't run: check if we can ask the user with a non-activating FocusPrompt.
        if let prompted = await promptRevive(w, &f, autoDecision: d) {
            return prompted
        }
        if f.notForward == nil { f.notForward = forwardWhy(d, app: w.app) }
        return false
    }

    /// Ask the user to approve bringing covered frozen window `w` forward when automatic flash didn't run.
    /// Returns nil when prompting wasn't eligible (caller uses `forwardWhy`), else whether `w` drew again.
    private static func promptRevive(_ w: WinInfo, _ f: inout Frozen, autoDecision d: Forward) async -> Bool? {
        func eligible() -> (ok: Bool, cooldown: FocusPrompt.CooldownReason?) {
            let since = Session.current.forwarded[w.id].map { ProcessInfo.processInfo.systemUptime - $0 }
            let driver = AppLocks.holder(w.pid)
            let revivable = structurallyRevivable(cover: f.cover,
                                                  onScreen: Windows.info(w.id)?.onScreen == true,
                                                  foreground: inForeground,
                                                  drawsCovered: drawsCovered(w.pid),
                                                  otherAgent: driver != nil && driver != Session.current.id)
            let cooldown = FocusPrompt.activeCooldown(pid: w.pid)
            let ok = FocusPrompt.shouldPromptRevive(enabled: Connection.current?.focusPrompt ?? false,
                                                    quitting: Connection.quitting,
                                                    structurallyRevivable: revivable,
                                                    recently: since.map { $0 < forwardGap } ?? false,
                                                    screenLocked: Windows.screenLocked,
                                                    inCooldown: cooldown != nil)
            return (ok, cooldown)
        }
        let initial = eligible()
        if !initial.ok {
            if let reason = initial.cooldown,
               structurallyRevivable(cover: f.cover, onScreen: Windows.info(w.id)?.onScreen == true,
                                     foreground: inForeground, drawsCovered: drawsCovered(w.pid),
                                     otherAgent: AppLocks.holder(w.pid).map { $0 != Session.current.id } ?? false) {
                f.declined = reason == .declined
                f.notForward = reason == .declined
                    ? "the user recently declined switching \(w.app)"
                    : "no response to recent switch prompt"
                return false
            }
            return nil
        }
        do { try await FocusPrompt.acquireGate() } catch {
            Connection.current?.work.promptCancelled = true
            return false
        }
        defer { FocusPrompt.releaseGate() }
        // Re-check after acquiring the FIFO gate: another session may have triggered a cooldown or window moved.
        let again = eligible()
        if !again.ok {
            if let reason = again.cooldown {
                f.declined = reason == .declined
                f.notForward = reason == .declined
                    ? "the user recently declined switching \(w.app)"
                    : "no response to recent switch prompt"
                return false
            }
            return nil
        }
        if coverOf(w).cover == .inView { return await drawnNow(w, f) }
        let liveInfo = Windows.info(w.id) ?? w
        let front = Hold.isFront(w.pid)
        let key = front ? keyWindow(w.pid, timeout: 0.05) : nil
        let keyInfo = key.flatMap { Windows.info($0) }
        let req = FocusPrompt.Request(
            pid: w.pid, wid: w.id, app: AgentBrowser.label(liveInfo), title: liveInfo.title,
            targetOwner: owner(w.id), keyWid: key, keyTitle: keyInfo?.title ?? "",
            keyOwner: key.map { owner($0) } ?? .user, trigger: .frozen, action: "redraw",
            front: front, sessionOrdinal: Session.current.ordinal,
            anchorFrame: keyInfo?.frame ?? activeWindowFrame()
        )
        let outcome = await FocusPrompt.ask(req) {
            guard Windows.info(w.id)?.onScreen == true,
                  NSRunningApplication(processIdentifier: w.pid)?.isTerminated == false else { return .windowGone }
            if coverOf(w).cover == .inView { return .clearedInView }
            return nil
        }
        switch outcome {
        case .approved(let presses, let at):
            FocusPrompt.clearCooldown(pid: w.pid)
            let alreadyMine = AppLocks.holder(w.pid) == Session.current.id
            if !alreadyMine {
                do { try await AppLocks.acquire(w.pid) } catch { return false }
            }
            defer { if !alreadyMine { AppLocks.release(w.pid) } }
            guard !Connection.hungUp, let fresh = Windows.info(w.id), fresh.onScreen else { return false }
            Session.current.forwarded[w.id] = ProcessInfo.processInfo.systemUptime
            let liveFront = Hold.isFront(w.pid)
            let back = NSWorkspace.shared.frontmostApplication
            if liveFront || back == nil || back?.processIdentifier == Windows.ownPID {
                let raised = await activateApprovedFront(fresh, presses: presses, at: at, allowBaselineFlip: false)
                guard raised == nil else {
                    f.notForward = "\(w.app) didn't bring #\(w.id) forward"
                    return false
                }
                let start = ProcessInfo.processInfo.systemUptime
                var drawn = false
                while ProcessInfo.processInfo.systemUptime - start < flashCap {
                    if Connection.hungUp { return false }
                    if Input.userPresses() != presses || keyWindow(w.pid, timeout: 0.05).map({ $0 != w.id }) == true { break }
                    if await drawnNow(fresh, f) { drawn = true; break }
                    await Input.sleep(0.05)
                }
                if !drawn { drawn = await drawnNow(fresh, f) }
                Connection.current?.ownerNotes.append(
                    "the user approved switching \(AgentBrowser.label(fresh)) to #\(w.id) to redraw it"
                        + (drawn ? "" : ", but it didn't draw again")
                )
                return drawn
            }
            let r = await flash(fresh, f, back: back!, approvedPresses: presses)
            let backName = back?.localizedName ?? "the app the user was in"
            Connection.current?.ownerNotes.append(
                "the user approved bringing \(AgentBrowser.label(fresh)) #\(w.id) forward to redraw it"
                    + (r.drawn ? "" : " (it didn't draw again)")
                    + (r.gaveBack ? ", then gave focus back to \(backName)" : "; \(fresh.app) may still be in front")
            )
            return r.drawn
        case .declined:
            FocusPrompt.recordDecline(pid: w.pid)
            f.declined = true
            f.notForward = "the user declined switching to #\(w.id)"
            return false
        case .timedOut:
            FocusPrompt.recordTimeout(pid: w.pid)
            f.notForward = "no response to switch prompt after \(Int(FocusPrompt.timeout)) s"
            return false
        case .clearedInView:
            return await drawnNow(w, f)
        case .cancelled:
            Connection.current?.work.promptCancelled = true
            return false
        case .windowGone, .unavailable, .clearedBackground, .clearedFocused:
            return nil
        }
    }

    /// Brings window `w`'s app forward with `w` raised and key (`raiseToKey`, as activate does), until `w` draws again
    /// (`drawnNow`, looked at every 50 ms for up to `flashCap` s), then the app the user was in (`back`) forward again;
    /// at once if the user touches the keyboard or mouse meanwhile (when `approvedPresses` is given, only new real keys
    /// or clicks cut it short, not mouse drift after clicking Approve). Not cut short when the client hangs up: the
    /// user's app always comes back. A hold on the app (`Hold`) is sent again afterwards: the app was really told it's
    /// inactive as `back` came back. Which way each came to the front goes in the helper's trace (`flashTrace`).
    static func flash(_ w: WinInfo, _ f: Frozen, back: NSRunningApplication,
                      approvedPresses: Fronts.Presses? = nil) async -> Flash {
        let start = ProcessInfo.processInfo.systemUptime
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        let presses = approvedPresses ?? Input.userPresses()
        func userCame() -> Bool {
            if approvedPresses != nil { return Input.userPresses() != presses }
            return Input.userPresses() != presses || !Input.userQuiet(for: now() - start)
        }
        Hold.flashing[w.pid] = .infinity  // its coming forward is puter-use's own, not the user's
        var r = Flash()
        // Its window made key and main first, so the app comes forward with that one (on this Space), not another.
        SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
        if let win = AX.window(pid: w.pid, wid: w.id) { AX.write(win, kAXMainAttribute, kCFBooleanTrue) }
        // (Its waits don't throw: nil is `w` having the keyboard.)
        let other = try? await raiseToKey(w, pause: 0.08) { await Input.sleep($0) }
        let asked = Hold.isFront(w.pid)
        if !asked {  // asked as apps are, it may not have come: through its accessibility then
            AX.write(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute, kCFBooleanTrue)
            _ = await cameForward(w.pid, within: 0.2)
        }
        r.cameBy = way(asked: asked, fallback: Hold.isFront(w.pid))
        if other != nil || !Hold.isFront(w.pid) { r.key = false }
        while r.key {
            if userCame() {
                r.userCame = true
                break
            }
            if await drawnNow(w, f) {
                r.drawn = true
                break
            }
            if now() - start >= flashCap { break }
            await Input.sleep(0.05)
        }
        r.backBy = await giveBack(back)
        r.gaveBack = r.backBy != .none
        r.seconds = now() - start
        if r.userCame, !r.drawn { r.drawn = await drawnNow(w, f) }
        Hold.flashing[w.pid] = now() + 0.35  // its notice of coming forward may come a moment late
        if !Hold.isFront(w.pid) { Hold.restore(w.pid) }
        if Trace.on { Trace.log(flashTrace(r, pid: w.pid, wid: w.id)) }
        return r
    }

    /// Whether window `w`, found not drawn (`f`), draws again now: its page has a tree again (when that was missing),
    /// else a capture isn't the agent's last picture pixel for pixel.
    static func drawnNow(_ w: WinInfo, _ f: Frozen) async -> Bool {
        if f.unread, let page = browserPage(w) { return drawnAgain(tree: page.tree) }
        return await pictureHolds(.window(w)) == false
    }

    /// Brings `app` to the front again: as apps are asked to, then through its accessibility if that hasn't taken
    /// within 0.3 s. Which way it's the front app then (`none`: it isn't).
    static func giveBack(_ app: NSRunningApplication) async -> Way {
        guard !app.isTerminated else { return .none }
        let pid = app.processIdentifier
        app.activate()
        if await cameForward(pid, within: 0.3) { return .activation }
        AX.cleanup(AXUIElementCreateApplication(pid), set: kAXFrontmostAttribute, kCFBooleanTrue)  // (after a hang-up too)
        return way(asked: false, fallback: await cameForward(pid, within: 0.3))
    }

    /// Whether app `pid` is the front app within `s` seconds (looked at every 20 ms).
    static func cameForward(_ pid: pid_t, within s: Double) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + s
        while !Hold.isFront(pid) {
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            await Input.sleep(0.02)
        }
        return true
    }

    /// Brings window `w` forward as its app's key window, as the activate action does: raised with its app brought to
    /// the front, then, while another of its app's windows has the keyboard, made key and raised again, twice at most,
    /// with `pause` s given each time (`wait`). The window that still has the keyboard then, nil when `w` has it (or the
    /// app doesn't say).
    static func raiseToKey(_ w: WinInfo, pause: Double, wait: (Double) async throws -> Void) async throws -> CGWindowID? {
        AX.raise(pid: w.pid, wid: w.id)
        try await wait(pause)
        for _ in 0..<2 {
            guard let key = AX.focusedWindow(pid: w.pid), key != w.id else { break }
            SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
            AX.raise(pid: w.pid, wid: w.id)
            try await wait(pause)
        }
        if let key = AX.focusedWindow(pid: w.pid), key != w.id { return key }
        return nil
    }
}

/// A look cut short because its window was just brought forward and drawn again (`Handlers.revive`): what it went
/// by was read while the window wasn't drawn, so it's looked at again.
struct Redrawn: Error, CustomStringConvertible {
    var description: String { "the window was just drawn again: look again" }
}
