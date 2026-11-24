import AppKit
import ApplicationServices

/// Whose a window is, for what's said about it and where an app's keyboard may be moved: the agent's (its session
/// opened it), the agent's but the user has used it since (`shared`: still the agent's to work in, but the keyboard
/// isn't taken off it while the user may be in its app, nor moved to it from theirs), or the user's (any other).
enum Owner: Equatable {
    case agent, shared, user
}

/// What one of the agent's windows showed when its session last used it, to tell later whether the user has taken it
/// over (`Handlers.takeover`): its title (from the window list, so it costs nothing), its tab count (a browser's) and
/// its page's host when they could be read without switching an app's accessibility tree on (nil: not known, which is
/// never a change), since when the user's visits to its app count (`since`, system uptime: the end of the last act
/// that touched it, or the last look at whether it changed; `input`, the user's key presses and clicks counted then),
/// when the session last used it at all (`lastUsed`: after `Handlers.ownershipLasts` it's let go), whether the user
/// has used it since (`userUsed`, `Owner.shared`), and the titles a change was told with lately (`told`: a title that
/// comes back, as an unread count or a player's does, isn't told again).
struct Owned {
    var title: String
    var tabs: Int?
    var host: String?
    var since: TimeInterval
    var input = Fronts.Presses()
    var lastUsed: Date
    var userUsed = false
    var told: [String] = []
}

/// The act under way moved, or tried to move (`took` false), its app's keyboard to the agent's own window `wid` from
/// the user's window `from`, the app being in the background (`Handlers.keyPrimer`).
struct KeyMove {
    let pid: pid_t
    let wid: CGWindowID
    let from: CGWindowID
    var took = false
}

/// When each app was the user's front app, and, as it stopped being that, the app's key window and the user's key
/// presses and clicks meanwhile: what says the user may have used one of the agent's windows since its session last
/// used it (`Handlers.takeover`). From the system's app-activation notices (no accessibility observer), kept as long
/// as ownership lasts.
@MainActor
enum Fronts {
    /// The user's key presses and clicks so far, as the HID system counts them (`Input.userPresses`): what puter-use
    /// posts to an app goes straight to it, so it isn't in them.
    struct Presses: Equatable {
        var keys: UInt32 = 0
        var clicks: UInt32 = 0
    }

    struct Span: Equatable {
        let pid: pid_t
        let from: TimeInterval  // system uptime
        var to: TimeInterval?  // nil: still the front app
        var start = Presses()  // the counts as it came to the front
        var end: Presses?  // and as it stopped being the front app
        var key: CGWindowID?  // the app's key window then: the window the user was in
    }

    static var spans: [Span] = []
    private static var observer: NSObjectProtocol?

    /// Starts keeping track, once: from the app in front now.
    static func watch() {
        guard observer == nil else { return }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            spans = [Span(pid: pid, from: ProcessInfo.processInfo.systemUptime, start: Input.userPresses())]
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                // Ignore puter-use's own temporary flashes (`Hold.flashing`), so they neither record fake user
                // visits nor prematurely clear an approved focus grant.
                if Hold.ownActivation(pid) { return }
                // Leaving the granted app invalidates any active focus grant immediately (trackpad Space swipes too).
                for s in Session.all.values where s.focusGrant?.pid != pid {
                    s.focusGrant = nil
                }
                // The window the user leaves the app it took over from in (asked without switching on its tree).
                let leaving = spans.last.flatMap { $0.to == nil && $0.pid != pid ? Handlers.keyWindow($0.pid) : nil }
                spans = after(spans, front: pid, at: ProcessInfo.processInfo.systemUptime,
                              input: Input.userPresses(), key: leaving)
            }
        }
    }

    /// Whether the user used window `wid` of app `pid` since `since` (system uptime; `input`, the counts then), as far
    /// as is known (`keyNow`: the app's key window now, when it's the user's front app).
    static func userUsed(_ pid: pid_t, window wid: CGWindowID, since: TimeInterval, input: Presses, keyNow: CGWindowID?) -> Bool {
        userUsed(spans, pid: pid, window: wid, since: since, input: input, now: Input.userPresses(), keyNow: keyNow)
    }

    /// `spans` once app `pid` has come to the front `at`, with the user's key presses and clicks counted so far
    /// (`input`): the span of the app it took over from closes with them and that app's key window (`key`). What can
    /// never show the user used a window is let go then: a span with no key window known, or with too little input
    /// in it (`worked`); and of the spans in one window, only the newest is kept (a later one ends later, and only the
    /// newest can be after a given time without being cut by it). So frequent switching never pushes out what does
    /// show it. Spans that ended over `keep` seconds ago are let go too.
    nonisolated static func after(_ spans: [Span], front pid: pid_t, at: TimeInterval, input: Presses, key: CGWindowID? = nil,
                                  keep: TimeInterval = Handlers.ownershipLasts) -> [Span] {
        var out = spans
        if let i = out.indices.last, out[i].to == nil {
            if out[i].pid == pid { return out }
            var s = out.removeLast()
            s.to = at
            s.end = input
            s.key = key
            if let k = key, worked(count(s.start, input), left: true) {
                out.removeAll { $0.pid == s.pid && $0.key == k }
                out.append(s)
            }
        }
        out.append(Span(pid: pid, from: at, start: input))
        return out.filter { ($0.to ?? at) >= at - keep }
    }

    /// Key presses and clicks between two counts (none for counts out of order).
    nonisolated static func count(_ from: Presses, _ to: Presses) -> Presses {
        Presses(keys: to.keys > from.keys ? to.keys - from.keys : 0, clicks: to.clicks > from.clicks ? to.clicks - from.clicks : 0)
    }

    /// Whether the user's key presses and clicks while an app was their front app (`c`) show they did something there,
    /// beyond the gesture that left it (`left`; for the app still in front, none has). Leaving is one Tab of a Cmd-Tab
    /// (two to pass an app in the switcher: Cmd itself isn't a key press) or one click elsewhere (another window, the
    /// Dock), and what brought the app forward comes before its span; so a Cmd-Tab in and out again, or a click away,
    /// isn't use. Three key presses or two clicks are, and so are a key press and a click (the leave is one or the
    /// other). For the app still in front: two key presses (one could be a Cmd-Tab under way) or a click.
    nonisolated static func worked(_ c: Presses, left: Bool) -> Bool {
        if left { return c.keys >= 3 || c.clicks >= 2 || (c.keys >= 1 && c.clicks >= 1) }
        return c.keys >= 2 || c.clicks >= 1
    }

    /// Whether the user used window `wid` of app `pid` since `since` (`input`, their key presses and clicks counted
    /// then; `now`, so far): the app was their front app then, `wid` was its key window (as it stopped being front,
    /// or now, `keyNow`, for the app still in front), and they pressed keys or clicked enough meanwhile (`worked`,
    /// counted from `since` for the span it falls in). The user busy in another of the app's windows is no sign they
    /// used this one. Input puter-use posts to an app isn't theirs.
    nonisolated static func userUsed(_ spans: [Span], pid: pid_t, window wid: CGWindowID, since: TimeInterval,
                                     input: Presses, now: Presses, keyNow: CGWindowID?) -> Bool {
        spans.contains { s in
            guard s.pid == pid, (s.to ?? .infinity) > since, (s.to == nil ? keyNow : s.key) == wid else { return false }
            // In front already at `since`: only what came after it.
            let base = s.from >= since ? s.start
                : Presses(keys: max(s.start.keys, input.keys), clicks: max(s.start.clicks, input.clicks))
            return worked(count(base, s.end ?? now), left: s.to != nil)
        }
    }
}

extension Handlers {
    /// How long one of the agent's windows stays its own without its session using it: after that it's the user's
    /// again, so the session every CLI shell and script shares ("default", never swept) doesn't keep them for good.
    nonisolated static let ownershipLasts: TimeInterval = 2 * 3600

    /// Whose window `id` is to the request's session.
    static func owner(_ id: CGWindowID) -> Owner {
        let s = Session.current
        guard s.agentWindows.contains(id) else { return .user }
        return s.owned[id]?.userUsed == true ? .shared : .agent
    }

    /// How a reply names whose a window is: "yours", "yours, used by the user" or "the user's".
    nonisolated static func whose(_ o: Owner) -> String {
        switch o {
        case .agent: return "yours"
        case .shared: return "yours, used by the user"
        case .user: return "the user's"
        }
    }

    /// What becomes of one of the agent's windows that may have changed since its session last used it.
    enum Takeover: Equatable {
        case keep  // nothing to tell
        case changed  // another site or tab count with no sign of the user: still the agent's, and it's told
        case tag  // the user was in it and it changed: still the agent's, marked used by the user (`Owner.shared`)
        case drop  // the user was in it and it shows another site or tab count: theirs now
    }

    /// The takeover rule. Redirects, sign-in hops, an expired session or a page's own route change all change a
    /// page with no one there, so a change alone keeps the window the agent's: told only when it shows another site
    /// (`hostChanged`, when both hosts could be read) or tab count, not for a title alone (a clock, an unread count
    /// keeps changing one). Only with signs the user was in the window since (`userWasThere`, `Fronts.userUsed`) is a
    /// changed title or tab count theirs: another site or another tab count gives it to them; anything else marks it
    /// used by them.
    nonisolated static func takeover(titleChanged: Bool, tabsChanged: Bool, hostChanged: Bool, userWasThere: Bool) -> Takeover {
        guard userWasThere else { return hostChanged || tabsChanged ? .changed : .keep }
        guard titleChanged || tabsChanged else { return .keep }
        return hostChanged || tabsChanged ? .drop : .tag
    }

    /// Two readings differ: only when both are known (one that couldn't be read is no change).
    nonisolated static func differs<T: Equatable>(_ then: T?, _ now: T?) -> Bool {
        guard let then, let now else { return false }
        return then != now
    }

    /// One of the agent's windows its session last used at `lastUsed` is let go at `now`.
    nonisolated static func expired(_ lastUsed: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastUsed) > ownershipLasts
    }

    /// A page address's host, lowercased, without "www."; nil for none (about:blank, a new tab) or no address.
    nonisolated static func host(of url: String?) -> String? {
        guard let url, let h = URLComponents(string: url)?.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// What the agent is told about its window `id` (titled `title` now) as `takeover` decides it; nil for nothing.
    /// `tagged`: marked used by the user before, so a change is only news. `browser`: navigate opens another one.
    /// For `.changed`, what changed (`changedNote`): the site it shows now (`host`), its tab count then and now (`tabs`).
    nonisolated static func ownershipNote(_ v: Takeover, id: CGWindowID, title: String, browser: Bool, tagged: Bool,
                                          host: String? = nil, tabs: (then: Int, now: Int)? = nil) -> String? {
        let shows = title.isEmpty ? "" : " (it now shows \"\(AX.clip(title, 60))\")"
        switch v {
        case .keep:
            return nil
        case .changed:
            return changedNote(id: id, title: title, host: host, tabs: tabs)
        case .tag:
            if tagged { return title.isEmpty ? nil : "#\(id) now shows \"\(AX.clip(title, 60))\" (changed since your last call)" }
            return "#\(id) is still yours, but the user has used it since\(shows)"
        case .drop:
            return "#\(id) was yours, but the user has used it since\(shows): it's treated as theirs now"
                + (browser ? "; navigate opens a new window" : "")
        }
    }

    /// What the agent is told when its window `id` (titled `title` now) shows another site (`host`, the one it shows
    /// now) or tab count (`tabs`, then and now) since its session last used it, with no sign of the user; nil with
    /// neither.
    nonisolated static func changedNote(id: CGWindowID, title: String, host: String?, tabs: (then: Int, now: Int)?) -> String? {
        let quoted = "\"\(AX.clip(title, 60))\""
        var parts: [String] = []
        if let host { parts.append("it now shows \(host)" + (title.isEmpty ? "" : " (\(quoted))")) }
        if let tabs { parts.append((host == nil ? "it now has" : "has") + " \(tabs.now) tabs (it had \(tabs.then))") }
        guard !parts.isEmpty else { return nil }
        if host == nil, !title.isEmpty { parts.append("shows \(quoted)") }
        return "#\(id) changed since your last call: " + parts.joined(separator: " and ")
    }

    /// Whether a change `takeover` found (`v`) was told already: one only to the title of a window marked used by the
    /// user before (`.tag`, `tagged`) to a title told lately (`told`). A title that comes back (an unread count, a
    /// player's) would be told on and on.
    nonisolated static func toldBefore(_ v: Takeover, tagged: Bool, title: String, told: [String]) -> Bool {
        v == .tag && tagged && told.contains(title)
    }

    /// The titles told lately for one of the agent's windows (`told`) once `title` is told too: the newest few.
    nonisolated static func telling(_ told: [String], _ title: String) -> [String] {
        Array((told.filter { $0 != title } + [title]).suffix(8))
    }

    /// At the start of a call that touches app `pid`'s windows (once a request): the session's windows it hasn't
    /// used for `ownershipLasts` are let go (and `current`, if it's one), and each of its windows of that app the user
    /// was in since it last used it that changed is told apart as `takeover` says, with a note (a title told lately
    /// isn't told again: `toldBefore`). A window given to the user leaves the session's own (and `current`, if it's
    /// that one); it's no longer where its keyboard is moved from (`keyPrimer`). A change with no sign of the user is
    /// looked for only in the window the call is about (`reviewChange`).
    static func reviewOwnership(_ pid: pid_t) {
        let s = Session.current
        if let c = Connection.current {
            guard !c.reviewed.contains(pid) else { return }
            c.reviewed.insert(pid)
        }
        Fronts.watch()
        let now = Date(), up = ProcessInfo.processInfo.systemUptime, input = Input.userPresses()
        var fresh = Set<CGWindowID>()
        for id in s.agentWindows {
            guard let o = s.owned[id] else {
                s.owned[id] = Owned(title: Windows.info(id)?.title ?? "", since: up, input: input, lastUsed: now)
                fresh.insert(id)
                continue
            }
            if expired(o.lastUsed, now: now) {
                s.agentWindows.remove(id)
                if s.current == id { s.current = nil }
            }
        }
        // The app's key window now, when the user is in it: asked once, and only if there's a window to look at.
        var keyNow: CGWindowID??
        for id in s.agentWindows.subtracting(fresh) {
            guard var o = s.owned[id], let w = Windows.info(id), w.pid == pid else { continue }
            if keyNow == nil { keyNow = .some(Hold.isFront(pid) ? keyWindow(pid) : nil) }
            let there = Fronts.userUsed(pid, window: id, since: o.since, input: o.input, keyNow: keyNow ?? nil)
            // The tab count and the page are read only when the user may have been in the window: without that,
            // no change is theirs.
            let tabs = there ? tabCount(w) : nil, site = there ? pageHost(w) : nil
            let v = takeover(titleChanged: w.title != o.title, tabsChanged: differs(o.tabs, tabs),
                             hostChanged: differs(o.host, site), userWasThere: there)
            if !toldBefore(v, tagged: o.userUsed, title: w.title, told: o.told),
               let note = ownershipNote(v, id: id, title: w.title, browser: isBrowser(pid), tagged: o.userUsed) {
                Connection.current?.ownerNotes.append(note)
                o.told = telling(o.told, w.title)
            }
            if v == .drop {
                s.agentWindows.remove(id)
                s.given.insert(id)
                if s.current == id { s.current = nil }
                continue
            }
            if v == .tag { o.userUsed = true }
            o.title = w.title
            if there {
                o.tabs = tabs ?? o.tabs
                o.host = site ?? o.host
            }
            o.since = up
            o.input = input
            s.owned[id] = o
        }
    }

    /// Once a request, for one of the agent's windows the call is about (`used`, after `reviewOwnership`): whether it
    /// shows another site or tab count since its session last used it, with no sign of the user, told with a note
    /// (`changedNote`); a title alone isn't. Read for this window only, when its app's accessibility tree is on
    /// already (`tabCount`, `pageHost`), and kept as what a later change is told by. (With signs of the user,
    /// `reviewOwnership` has read both and said what's to say.)
    static func reviewChange(_ w: WinInfo) {
        let s = Session.current
        guard s.agentWindows.contains(w.id), var o = s.owned[w.id] else { return }
        if let c = Connection.current {
            guard !c.changeReviewed.contains(w.id) else { return }
            c.changeReviewed.insert(w.id)
        }
        let tabs = tabCount(w), site = pageHost(w)
        let hostChanged = differs(o.host, site), tabsChanged = differs(o.tabs, tabs)
        let v = takeover(titleChanged: w.title != o.title, tabsChanged: tabsChanged, hostChanged: hostChanged, userWasThere: false)
        if let note = ownershipNote(v, id: w.id, title: w.title, browser: isBrowser(w.pid), tagged: o.userUsed,
                                    host: hostChanged ? site : nil,
                                    tabs: tabsChanged ? o.tabs.flatMap { then in tabs.map { (then: then, now: $0) } } : nil) {
            Connection.current?.ownerNotes.append(note)
        }
        o.tabs = tabs ?? o.tabs
        o.host = site ?? o.host
        s.owned[w.id] = o
    }

    /// At the end of an act: what each of the agent's windows among `ids` (the ones it touched) shows now, as what
    /// a later change is told by (`reviewOwnership`). Not known, the tab count and the host are left unknown.
    static func recordOwned(_ ids: [CGWindowID]) {
        let s = Session.current
        let mine = Set(ids).intersection(s.agentWindows)
        guard !mine.isEmpty else { return }
        Fronts.watch()
        let now = Date(), up = ProcessInfo.processInfo.systemUptime, input = Input.userPresses()
        for id in mine {
            guard let w = Windows.info(id) else { continue }
            var o = s.owned[id] ?? Owned(title: w.title, since: up, lastUsed: now)
            o.title = w.title
            o.tabs = tabCount(w)
            o.host = pageHost(w)
            o.since = up
            o.input = input
            o.lastUsed = now
            s.owned[id] = o
        }
    }

    /// How many tabs browser window `w` has: its tab group's tabs, when its app's accessibility tree is already on
    /// (`treeReady`: never switched on for this). Nil when that can't be read, and for other apps' windows: only a
    /// browser's tabs can hold pages the user opened there, and the walk costs up to a few hundred questions.
    static func tabCount(_ w: WinInfo) -> Int? {
        guard isBrowser(w.pid), treeReady(w.pid), let win = AX.window(pid: w.pid, wid: w.id) else { return nil }
        return tabCount(in: win, role: { AX.value($0, kAXRoleAttribute) as? String }, children: { AX.children($0) })
    }

    /// The tabs in the first tab group under `root`, breadth first through the window's own controls (never into a
    /// web page, which can have tab groups of its own), `visits` elements at most: the tab buttons in it, a few levels
    /// down (a browser may put its tabs in a scroll area inside the group). Nil with no tab group, or none in it.
    nonisolated static func tabCount<T>(in root: T, role: (T) -> String?, children: (T) -> [T], visits: Int = 150) -> Int? {
        var level = [root], seen = 0
        while !level.isEmpty, seen < visits {
            var next: [T] = []
            for el in level {
                seen += 1
                if seen > visits { return nil }
                switch role(el) {
                case "AXTabGroup":
                    var count = 0, inner = children(el)
                    for _ in 0..<3 where !inner.isEmpty {
                        var deeper: [T] = []
                        for c in inner {
                            switch role(c) {
                            case "AXRadioButton", "AXTab": count += 1
                            case "AXTabGroup", "AXWebArea": break
                            default: deeper += children(c)
                            }
                        }
                        inner = deeper
                    }
                    return count > 0 ? count : nil
                case "AXWebArea":
                    continue
                default:
                    next += children(el)
                }
            }
            level = next
        }
        return nil
    }

    /// The host of the page browser window `w` shows, when its accessibility tree is already on (`treeReady`).
    static func pageHost(_ w: WinInfo) -> String? {
        guard isBrowser(w.pid), treeReady(w.pid) else { return nil }
        return host(of: AX.pageURL(pid: w.pid, wid: w.id))
    }

    /// Why close_window leaves window `wid` open, or nil to close it: it's one of the agent's with more tabs than
    /// when it last acted there (`tabsThen`, `tabsNow`: a link the user opened elsewhere can land in it as a tab),
    /// or one the user took over from it (`given`). Either may hold the user's pages, so the user is asked first.
    nonisolated static func closeRefusal(wid: CGWindowID, given: Bool, tabsThen: Int?, tabsNow: Int?) -> String? {
        let ask = "nothing was closed. Ask the user; if they agree, close it with \"confirm\": true"
        if given { return "#\(wid) is the user's now (they've used it since you opened it): \(ask)" }
        guard let then = tabsThen, let now = tabsNow, now > then else { return nil }
        return "#\(wid) has \(now) tabs, \(then) when you last acted there, and the others may be the user's: \(ask)"
    }
}
