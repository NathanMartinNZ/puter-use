import AppKit
import ApplicationServices

enum Permissions {
    static func status() -> [String: Any] {
        ["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()]
    }

    static func request() -> [String: Any] {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        return status()
    }
}

/// What the agent's coordinates mean for a target: the last full screenshot it was shown, or one taken to
/// place what `find` lists (`shown` false: the agent has its pixels, not the picture).
struct Meta {
    var offset: CGPoint  // capture origin relative to the window origin (points)
    var size: CGSize  // captured area (points)
    var width: Int  // screenshot pixels
    var height: Int
    var sig: Signature
    var caret: Caret? = nil  // the text cursor then: a later frame that differs only by its blinking hasn't changed
    // The picture went to the agent as an image. Kept with the rest, so a reply that never reached the agent
    // takes it back too (`Store`): only a picture it was sent counts as seen.
    var shown = false
    // The blank margins left out of the picture sent (`Trim`): its pixels map back through it. `width` and
    // `height` stay the whole capture's, as does `sig`.
    var trim: Trim? = nil
    // What kept moving by itself in the frames just before the picture (signature cells, `Ambient`).
    var ambient: [CGRect] = []
    // Keys, typing or a click went to the window since the picture, with no new picture after them: a change
    // shaped like a text cursor may be a character typed (`CaretShape`).
    var typedSince = false
    // The part of the capture the picture sent shows, when it showed only what changed (`ChangeCrop`; capture
    // pixels): its pixels map back through its origin. `width`, `height` and `sig` stay the whole capture's.
    var crop: CGRect? = nil
    // How many pictures of the window in a row, this one included, were crops (`ChangeCrop.keyframe`).
    var crops = 0
    // Where the capture was (global points): a window moved or resized since gets a whole picture (`ChangeCrop`).
    var captured: CGRect? = nil
    // How it was sized: a capture made the same way gives the same pixels while the window doesn't change.
    var sizing: Sizing? = nil
    // The window's title as the picture shows it: its title then, or, for a capture that was the last one pixel for
    // pixel, the title kept with that one (a window its app isn't drawing shows the title it last drew).
    var title: String? = nil
    // What showed, at the picture or since, that the window's app isn't drawing it (`Handlers.Frozen`): the picture
    // may be old, so coordinates read off it stop.
    var frozen: Handlers.Frozen? = nil

    /// A box in the whole capture (pixels) as the picture sent shows it: in a crop, from its origin and within
    /// it; through the margins left out of it (`Trim.box`). Nil if none of it is in the picture.
    func pictureBox(_ r: CGRect) -> CGRect? {
        if let crop {
            let b = r.intersection(crop)
            guard !b.isNull, !b.isEmpty else { return nil }
            return b.offsetBy(dx: -crop.minX, dy: -crop.minY)
        }
        if let trim { return trim.box(r) }
        return r
    }

    /// What a crop shows, in window points (from the window's top-left corner), whole points round it.
    var cropInWindow: CGRect? {
        guard let crop, width > 0, height > 0 else { return nil }
        let sx = size.width / Double(width), sy = size.height / Double(height)
        let x0 = (offset.x + crop.minX * sx).rounded(.down), y0 = (offset.y + crop.minY * sy).rounded(.down)
        let x1 = (offset.x + crop.maxX * sx).rounded(.up), y1 = (offset.y + crop.maxY * sy).rounded(.up)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// The text cursor in a window when an image was taken (`Handlers.caret`): the focused text field it's in
/// and where accessibility puts the cursor (relative to the window, points: the edge of the character
/// after or before it, or for an empty field the empty range's place, which AppKit reports a line high),
/// its place in the text and how long the text is.
struct Caret {
    var field: CGRect
    var point: CGRect?
    var at: Int
    var count: Int? = nil  // characters in the field: a forward delete leaves the cursor where it was

    /// The cursor hasn't moved and the text is as long as it was: same field, same place in the text, same
    /// reported position, same number of characters.
    func same(as o: Caret) -> Bool {
        guard at == o.at, count == o.count, Self.near(field, o.field) else { return false }
        guard let p = point, let q = o.point else { return point == nil && o.point == nil }
        return Self.near(p, q)
    }

    /// The cursor went elsewhere in the same field (`o` being where it was).
    func moved(from o: Caret) -> Bool { at != o.at && Self.near(field, o.field) }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

enum Target {
    case window(WinInfo)
    case screen

    var key: CGWindowID {
        if case .window(let w) = self { return w.id }
        return 0
    }
}

@MainActor
enum Handlers {
    // The request's session holds these (see `Session`).
    static var current: CGWindowID? {  // 0 = whole screen
        get { Session.current.current }
        set { Session.current.current = newValue }
    }
    static var notes: [String] {  // per-request remarks surfaced to the agent
        get { Session.current.notes }
        set { Session.current.notes = newValue }
    }
    static var typist: Typist {  // how keys are typed
        get { Session.current.typist }
        set { Session.current.typist = newValue }
    }
    static var pasteOver: Int {  // text longer than this (per line) is pasted rather than typed; 0 = never
        get { Session.current.pasteOver }
        set { Session.current.pasteOver = newValue }
    }
    static var meta: Store<CGWindowID, Meta> { Session.current.meta }
    static var pointer: Pointer { Session.current.pointer }

    /// Commands that never wait their turn or take part in delivery reports: the handshake (status), quit
    /// and permissions work whatever else the session is doing, for any client.
    nonisolated static let exempt: Set<String> = ["status", "quit", "permissions"]
    /// Bumped when a client and helper of different versions can't work together (see client.py).
    nonisolated static let protocolVersion = 2

    /// One request. A session's requests run one at a time, in order; the client's reports on its earlier
    /// requests are applied first. A request whose client hangs up is cancelled and gets no reply.
    static func dispatch(_ line: Data, fd: Int32 = -1) async -> Reply? {
        guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return Reply(data: encode(["id": NSNull(), "ok": false, "error": "request must be a JSON object"]))
        }
        let p = req["params"] as? [String: Any] ?? [:]
        let cmd = req["cmd"] as? String ?? ""
        let session = Session.named((req["session"] ?? p["session"]) as? String ?? "default")
        let client = (req["client"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let key = exempt.contains(cmd) ? nil : client.flatMap { c in (req["id"] as? Int).map { RequestKey(client: c, id: $0) } }
        let conn = Connection(fd: fd, key: key, reports: req["reports"] as? Bool != false)
        if exempt.contains(cmd) {
            let reply = await Connection.$current.withValue(conn) {
                await Session.$current.withValue(session) { await handle(req, p) }
            }
            var out = reply.map { Reply(data: encode($0)) }
            if cmd == "quit" { out?.written = { NSApp.terminate(nil) } }
            return out
        }
        return await Connection.$current.withValue(conn) {
            await Session.$current.withValue(session) { await take(turn: session, req, p, conn) }
        }
    }

    /// A request that waits its turn, settles the client's reports, and takes part in them.
    private static func take(turn session: Session, _ req: [String: Any], _ p: [String: Any], _ conn: Connection) async -> Reply? {
        do { try await session.turns.take() } catch { return nil }  // gave up while waiting: never ran
        defer { session.turns.done() }
        session.lastUse = Date()
        let key = conn.key
        if let client = key?.client ?? (req["client"] as? String) {
            session.account(client: client, done: ints(req["done"]), lost: ints(req["lost"]))
        }
        if let key { session.enter(key) }
        let reply = await handle(req, p)
        if let key { session.record(key, conn.work) }
        // Cancelled, or the client hung up as it finished: the result won't reach the agent.
        guard var reply, !conn.hungUp() else {
            if let key { session.lost(key) }
            return nil
        }
        // Notes about earlier calls whose results were lost go with every reply until one that carried
        // them is known to have arrived.
        var carried: [Int] = []
        if reply["ok"] as? Bool == true, var result = reply["result"] as? [String: Any] {
            let (ids, notes) = session.carry(key)
            if !notes.isEmpty {
                result["notes"] = notes + (result["notes"] as? [String] ?? [])
                reply["result"] = result
                carried = ids
            }
        }
        var out = Reply(data: encode(reply))
        if !conn.reports || key == nil {  // no reports will come: written counts as delivered
            out.written = { session.written(key, notes: carried) }
        }
        return out
    }

    /// When the running binary was built (its modification time at launch, seconds since 1970).
    nonisolated static let builtAt: Double = {
        guard let path = Bundle.main.executablePath,
              let d = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else { return 0 }
        return d.timeIntervalSince1970
    }()

    nonisolated static func ints(_ v: Any?) -> [Int] { (v as? [Any] ?? []).compactMap { $0 as? Int } }

    /// Run the command: the reply, or nil if it was cancelled.
    static func handle(_ req: [String: Any], _ p: [String: Any]) async -> [String: Any]? {
        let id: Any = req["id"] ?? NSNull()
        do {
            Hold.touch()
            Connection.current?.bringForward = forwardSetting(p["bring_forward"])
            Connection.current?.focusPrompt = FocusPrompt.setting(p["focus_prompt"])
            var result: [String: Any]
            switch req["cmd"] as? String ?? "" {
            case "status":
                result = ["version": version, "protocol": protocolVersion, "pid": Int(Windows.ownPID),
                          "built": builtAt, "permissions": Permissions.status()]
            case "permissions": result = Permissions.request()
            case "windows": result = try await windows(p)
            case "screenshot": result = try await screenshot(p)
            case "act": result = try await act(p)
            case "menus": result = try menus(p)
            case "find": result = try await find(p)
            case "macros": result = try Macros.command(p)
            case "release":
                Session.current.end()
                result = [:]
            case "quit":
                await Run.stopAll(within: 1)  // other sessions' batches too: nothing left held down or open
                Hold.releaseAll()
                await Clipboard.finish()
                // It stops as soon as the reply is written (dispatch); this is for a reply that can't be.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
                Run.exitLater()
                result = ["pid": Int(Windows.ownPID)]  // the client waits until it's gone
            case let other: throw HelperError("unknown command \(other)")
            }
            if let n = Connection.current?.windowNote {  // said once per pair of windows
                result["notes"] = [n.text] + (result["notes"] as? [String] ?? [])
                Session.current.pickNoted.insert(n.pair)
            }
            if let owned = Connection.current?.ownerNotes, !owned.isEmpty {  // its windows that changed hands or look
                result["notes"] = owned + (result["notes"] as? [String] ?? [])
            }
            return ["id": id, "ok": true, "result": result]
        } catch {
            if error is Cancelled || Connection.hungUp { return nil }
            // Its windows that changed hands or look are told once, as they're found: here too.
            return ["id": id, "ok": false, "error": withNotes("\(error)", Connection.current?.ownerNotes ?? [])]
        }
    }

    /// An error's text with notes after it (each a sentence of its own), for a reply that has nowhere else for them.
    nonisolated static func withNotes(_ error: String, _ notes: [String]) -> String {
        guard !notes.isEmpty else { return error }
        let end = error.last.map { ".!?".contains($0) } == true ? " " : ". "
        return error + end + notes.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ". ")
    }

    static func encode(_ obj: [String: Any]) -> Data {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: []) { return d }
        let id = (obj["id"] as? Int).map(String.init) ?? "null"
        return Data("{\"id\":\(id),\"ok\":false,\"error\":\"the reply couldn't be encoded\"}".utf8)
    }

    // MARK: - params

    /// A number, or one as text ("12"). An element's number as an outline writes it ("#12": `#` then only digits,
    /// spaces round it aside) is that number too; nothing else with a `#` is.
    nonisolated static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") {
            let digits = t.dropFirst()
            return !digits.isEmpty && digits.allSatisfy({ ("0"..."9").contains($0) }) ? Double(String(digits)) : nil
        }
        return Double(s)
    }

    nonisolated static func int(_ v: Any?, _ d: Int) -> Int { num(v).map { Int($0) } ?? d }

    /// "1280x860" or [1280, 860]; anything else (e.g. "off") is nil.
    nonisolated static func size(_ v: Any?) -> CGSize? {
        var wh: [Double] = []
        if let s = v as? String { wh = s.lowercased().split(separator: "x").compactMap { Double($0) } }
        if let a = v as? [Any] { wh = a.compactMap { num($0) } }
        guard wh.count == 2, wh[0] > 0, wh[1] > 0 else { return nil }
        return CGSize(width: wh[0], height: wh[1])
    }

    nonisolated static func point(_ v: Any?) -> CGPoint? {
        if let a = v as? [Any], a.count >= 2, let x = num(a[0]), let y = num(a[1]) { return CGPoint(x: x, y: y) }
        if let d = v as? [String: Any], let x = num(d["x"]), let y = num(d["y"]) { return CGPoint(x: x, y: y) }
        return nil
    }

    // MARK: - targets

    static func resolve(_ v: Any?) throws -> Target {
        if v == nil || v is NSNull {
            guard let cur = current else {
                throw HelperError("no window selected: pass window (an id from windows, an app name, or \"screen\")")
            }
            if cur == 0 { return .screen }
            guard let w = Windows.info(cur) else {
                throw HelperError(unseenWindow(cur) ?? "window \(cur) no longer exists" + appWindows(cur))
            }
            return used(w)
        }
        if let n = num(v), !(v is String && Int(v as! String) == nil) {
            // An id no window can have (negative, fractional, past UInt32) is not found either.
            guard let id = CGWindowID(exactly: n), let w = Windows.info(id) else {
                throw HelperError(CGWindowID(exactly: n).flatMap(unseenWindow)
                    ?? "window \(Int(exactly: n).map(String.init) ?? "\(n)") not found" + (CGWindowID(exactly: n).map(appWindows) ?? ""))
            }
            return used(w)
        }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else {
            throw HelperError("bad window value")
        }
        if s.lowercased() == "screen" { return .screen }
        // "Firefox (agent)", as listings name the agent's own Firefox: its windows alone.
        let agents = AgentBrowser.aim(s) == .agent
        let wins = agents ? AgentBrowser.windows() : Windows.targetable(app: s)
        for pid in Set(wins.map(\.pid)) { reviewOwnership(pid) }  // a window the user took over isn't the session's to pick
        let system = { (w: WinInfo) in systemWindow(w, AX.window(pid: w.pid, wid: w.id)) }  // the dictation orb
        if let hit = appWindow(wins, query: s, current: current, own: Session.current.ownRecent,
                               noted: Session.current.pickNoted, agent: agentWindows,
                               browser: wins.first.map { isBrowser($0.pid) } ?? false, system: system) {
            if let note = hit.note { Connection.current?.windowNote = note }
            return used(hit.window)
        }
        if agents {
            throw HelperError("no window for \"\(s)\": \(AgentBrowser.absent)")
        }
        if Windows.runningApp(s) != nil { throw HelperError("\(s) is running but has no windows (use windows with launch=true)") }
        throw HelperError("no window for \"\(s)\" (not running? use windows with launch=true)")
    }

    /// Whether action `a` sent keys into a text field (so a menu now open is that field's suggestions).
    static func typedIntoField(_ a: [String: Any]?, _ pid: pid_t) -> Bool {
        guard let a, keyboardActions.contains(kind(a)) else { return false }
        return AX.focusedElement(pid: pid).map(AX.isTextInput) ?? false
    }

    enum Pick { case current, own, front }

    /// The window app name `query` means (`pick`), with a note when that isn't the app's front window
    /// (the one an app name used to mean) and the session hasn't been told about that pair yet (`noted`).
    /// In a browser (`browser`), a name that falls back to the front window of the user's (none of `agent`'s)
    /// says so too, once a window: the agent may have taken it for its own.
    static func appWindow(_ wins: [WinInfo], query: String, current: CGWindowID?, own: [CGWindowID],
                          noted: Set<[CGWindowID]>, agent: Set<CGWindowID> = [], browser: Bool = false,
                          system: (WinInfo) -> Bool = { _ in false })
        -> (window: WinInfo, note: (text: String, pair: [CGWindowID])?)? {
        guard case let (w, why)? = pick(wins, current: current, own: own, system: system) else { return nil }
        if why == .front {
            guard browser, !agent.contains(w.id), !noted.contains([w.id]) else { return (w, nil) }
            let title = w.title.isEmpty ? "" : " \"\(AX.clip(w.title, 40))\""
            return (w, ("\"\(query)\" means the user's front window #\(w.id)\(title); navigate opens one of your own", [w.id]))
        }
        guard let front = pick(wins, current: nil, own: [], system: system)?.0, front.id != w.id,
              !noted.contains([w.id, front.id]) else { return (w, nil) }
        let mine = why == .current ? "the window you're on, #\(w.id)" : "your own window #\(w.id)"
        let title = front.title.isEmpty ? "" : " \"\(AX.clip(front.title, 40))\""
        return (w, ("\"\(query)\" is \(mine); \(front.app)'s front window is #\(front.id)\(title)", [w.id, front.id]))
    }

    /// The window an app name means, of `wins` (the app's, front to back): the one the session is on, else
    /// the one of its own it used last (`own`, oldest first), else the front one. Windows on screen come
    /// before minimized or hidden ones. With no current and no own, the front one, as an app name always meant,
    /// but never one of macOS's own bits shown in the app's name (`system`: the dictation orb) while
    /// there's another.
    nonisolated static func pick(_ wins: [WinInfo], current: CGWindowID?, own: [CGWindowID],
                                 system: (WinInfo) -> Bool = { _ in false }) -> (WinInfo, Pick)? {
        for tier in [wins.filter(\.onScreen), wins] {
            if let c = current, let w = tier.first(where: { $0.id == c }) { return (w, .current) }
            if let w = own.reversed().lazy.compactMap({ id in tier.first { $0.id == id } }).first { return (w, .own) }
            if let w = tier.first(where: { !system($0) }) { return (w, .front) }
        }
        return (wins.first(where: \.onScreen) ?? wins.first).map { ($0, .front) }
    }

    /// A window the session works on: its app is remembered, for when it's gone. Its own windows of that app
    /// are looked at first, in case the user has taken one over (`reviewOwnership`), and this one, if it's its
    /// own, for another site or tab count since (`reviewChange`).
    static func used(_ w: WinInfo) -> Target {
        reviewOwnership(w.pid)
        reviewChange(w)
        if AgentBrowser.isInstance(w.pid) { AgentBrowser.touch() }  // in use: not quit as idle
        Session.current.windowApps[w.id] = (w.app, w.pid)
        if Session.current.agentWindows.contains(w.id) {  // its own: the one an app name means next
            Session.current.ownRecent.removeAll { $0 == w.id }
            Session.current.ownRecent.append(w.id)
            Session.current.owned[w.id]?.lastUsed = Date()
        }
        return .window(w)
    }

    /// Why window `id`, which the window server lists but not on screen (so `Windows.info` doesn't find it, while
    /// `windows` lists it), can't be used (`unseen`), or nil when it isn't such a window.
    static func unseenWindow(_ id: CGWindowID) -> String? {
        // (Not an app the policy keeps agents out of: those windows aren't listed.)
        guard let w = Windows.all().first(where: { $0.id == id && !$0.onScreen }), Policy.level(w.pid) != .deny else { return nil }
        return unseen(coverOf(w).cover, app: w.app.isEmpty ? Policy.appName(w.pid) : w.app, wid: id)
    }

    /// Why window `wid` of `app` can't be seen or used while it's minimized, on another Space or its app is hidden
    /// (`cover`), and that it's the user's to change: bringing it back would put it in front of them. Nil otherwise.
    nonisolated static func unseen(_ cover: Cover, app: String, wid: CGWindowID) -> String? {
        switch cover {
        case .minimized:
            return "window #\(wid) is minimized, so it can't be seen or used: un-minimizing it would bring it to the front, "
                + "so ask the user to bring it back, or work in another window"
        case .otherSpace:
            return "window #\(wid) is on another Space, so it can't be seen or used from here: ask the user to bring it to "
                + "this one"
        case .hidden:
            return "window #\(wid) can't be seen or used while \(app) is hidden: showing \(app) would bring it to the front, "
                + "so ask the user to show \(app), or work in another window"
        case .inView, .covered:
            return nil
        }
    }

    /// For a window that's gone: whose it was and that app's windows now (" (it was Firefox's; …)"), the
    /// same process's only (another copy of the app is someone else's), the agent's own marked.
    static func appWindows(_ id: CGWindowID) -> String {
        guard let (app, pid) = Session.current.windowApps[id] else { return "" }
        let now = Windows.targetable().filter { $0.pid == pid && !systemWindow($0, AX.window(pid: pid, wid: $0.id)) }.prefix(8).map { w in
            "#\(w.id)" + (w.title.isEmpty ? "" : " \"\(AX.clip(w.title, 40))\"") + (agentWindows.contains(w.id) ? " (yours)" : "")
        }
        return now.isEmpty ? " (it was \(app)'s, which has no windows now)"
            : " (it was \(app)'s; its windows now: \(now.joined(separator: ", ")))"
    }

    // MARK: - commands

    static func windows(_ p: [String: Any]) async throws -> [String: Any] {
        let app = (p["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let launched = app != nil && p["launch"] as? Bool == true
        let wins: [WinInfo]
        if let app, AgentBrowser.aim(app) == .agent {  // "Firefox (agent)": the agent's own Firefox, never started here
            wins = AgentBrowser.windows()
            if launched, wins.isEmpty { throw HelperError(AgentBrowser.absent) }
        } else if let app, launched {
            // Not shrunk to the window box: an app may restore the user's last session as it launches.
            wins = try await Windows.launch(app)
        } else {
            wins = Windows.targetable(app: app)
        }
        // Windows drawn fully transparent (an app's preloaded or helper windows) aren't listed: nothing of them
        // shows. Only here: an app name still resolves, and launch still waits, as before. A window just
        // launched may still be fading in, so with nothing else to list it's looked at again for a moment.
        var shown = wins.filter { listable(alpha: $0.alpha) }
        if launched, shown.isEmpty, !wins.isEmpty {
            for _ in 0..<3 where shown.isEmpty {
                try await Run.pause(0.15)
                shown = wins.compactMap { Windows.info($0.id) }.filter { listable(alpha: $0.alpha) }
            }
        }
        // Apps the policy keeps agents out of aren't listed (their window titles are theirs too).
        var kept: [String] = []
        let allowed = shown.compactMap { w -> (WinInfo, Policy.Level)? in
            let l = Policy.level(w.pid)
            if l == .deny {
                if !kept.contains(w.app) { kept.append(w.app) }
                return nil
            }
            if systemWindow(w, AX.window(pid: w.pid, wid: w.id)) { return nil }  // macOS's dictation orb, not the app's
            return (w, l)
        }
        // Which are the agent's (once it's known the user hasn't taken one over), the one it's on, the one in front,
        // the one with its app's keyboard.
        let ws = allowed.map { $0.0 }
        for pid in Set(ws.filter { agentWindows.contains($0.id) }.map(\.pid)) { reviewOwnership(pid) }
        var keys: [pid_t: CGWindowID] = [:]
        for pid in keyboardApps(ws, agent: agentWindows, current: current) { keys[pid] = keyWindow(pid) }
        let front = Set(ws.map { $0.pid }).first { Hold.isFront($0) }
        let tags = windowTags(ws, agent: agentWindows, used: Set(ws.map(\.id).filter { owner($0) == .shared }),
                              current: current, front: front, keys: keys)
        let listed = allowed.map { pair -> [String: Any] in
            let (w, l) = pair
            var j = w.json
            j["app"] = AgentBrowser.label(w)  // the agent's own Firefox apart from the user's
            if l != .full { j["policy"] = l.rawValue }
            for tag in tags[w.id] ?? [] { j[tag] = true }
            return j
        }
        var out: [String: Any] = ["windows": listed, "permissions": Permissions.status()]
        var notes: [String] = []
        if let app, shown.isEmpty, !wins.isEmpty {
            notes.append("\(wins[0].app.isEmpty ? app : wins[0].app)'s windows are all invisible (fully transparent), "
                + "so none is listed")
        }
        if !kept.isEmpty { notes.append("not listed: \(kept.joined(separator: ", ")) (puter-use's policy keeps agents out)") }
        if let problem = Policy.config.problem { notes.append("policy: \(problem)") }
        if !notes.isEmpty { out["notes"] = notes }
        return out
    }

    /// Whether a window drawn at `alpha` is listed by `windows`: not when it's fully transparent (≤ 0.05, as
    /// what's over a window is counted), like an app's preloaded or helper windows.
    nonisolated static func listable(alpha: Double) -> Bool { alpha > 0.05 }

    /// The apps whose key window `windows` asks for (`windowTags`): those with more than one window listed
    /// (keys sent to the app go to one of them), or with the agent's own window or the one it's on.
    nonisolated static func keyboardApps(_ wins: [WinInfo], agent: Set<CGWindowID>, current: CGWindowID?) -> Set<pid_t> {
        var count: [pid_t: Int] = [:]
        for w in wins { count[w.pid, default: 0] += 1 }
        return Set(wins.filter { count[$0.pid, default: 0] > 1 || agent.contains($0.id) || $0.id == current }.map(\.pid))
    }

    /// The tags of each window `windows` lists (`wins`, front to back for those on screen), in this order:
    /// `yours`, one the agent opened (`agent`); `used`, one of those the user has used since (`used`); `current`,
    /// the one it's on; `front`, the front window of the app really in front (`front`: what the user sees on top);
    /// `keyboard`, the window of its app that has the app's keyboard (`keys`, each asked app's key window: keys
    /// sent to that app go there).
    nonisolated static func windowTags(_ wins: [WinInfo], agent: Set<CGWindowID>, used: Set<CGWindowID> = [],
                                       current: CGWindowID?, front: pid_t?,
                                       keys: [pid_t: CGWindowID]) -> [CGWindowID: [String]] {
        let frontWindow = front.flatMap { pid in wins.first { $0.pid == pid && $0.onScreen } }?.id
        var out: [CGWindowID: [String]] = [:]
        for w in wins {
            var tags: [String] = []
            if agent.contains(w.id) { tags.append("yours") }
            if agent.contains(w.id), used.contains(w.id) { tags.append("used") }
            if w.id == current { tags.append("current") }
            if w.id == frontWindow { tags.append("front") }
            if keys[w.pid] == w.id { tags.append("keyboard") }
            if !tags.isEmpty { out[w.id] = tags }
        }
        return out
    }

    /// The app's key window, as its accessibility says: asked without switching on a browser's accessibility
    /// tree (its windows are the app's own either way), giving up quickly on a busy app as `caret` does.
    static func keyWindow(_ pid: pid_t, timeout: Float = caretTimeout) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let w = AX.value(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w as! AXUIElement, &id) == .success ? id : nil
    }

    struct Opts {
        var sizing = Sizing()
        var format = "jpeg", quality = 0.75, maxBytes = 72_000
        /// If set, windows the agent opens are shrunk to fit this (points), so they stay sharp within the
        /// token cap. 1440x900 by default (full 0.75 px/pt); "off" (nil) keeps the size the app gave them.
        var windowBox: CGSize? = CGSize(width: 1440, height: 900)
        var interactive = false  // outline: only things to act on
        var maxChars = 8000  // outline length cap
        var marks = false  // number the interactive elements on the image
        var trimBlank = true  // leave blank margins out of an act's picture (`Trim`); a screenshot's never
        var cropChanges = false  // an act's picture may show only what changed (`ChangeCrop`); a screenshot's never
        var lowDetail = false  // `detail: "low"`: fewer pixels a point, as far as text stays readable (`DetailLow`)
        var textHeight: Double?  // with `lowDetail`, the window's text height that set the scale (`detailed`)
        init(_ p: [String: Any]) {
            interactive = p["interactive"] as? Bool == true
            maxChars = max(500, min(Handlers.int(p["max_chars"], maxChars), 40_000))
            marks = p["marks"] as? Bool == true
            trimBlank = p["trim_blank"] as? Bool != false
            cropChanges = p["crop_changes"] as? Bool == true
            lowDetail = (p["detail"] as? String)?.lowercased() == "low"
            if p.keys.contains("window_size") { windowBox = Handlers.size(p["window_size"]) }
            maxBytes = Handlers.int(p["max_bytes"], maxBytes)
            sizing.scale = Handlers.num(p["scale"]) ?? sizing.scale
            sizing.zoomScale = Handlers.num(p["zoom_scale"]) ?? sizing.zoomScale
            sizing.maxTokens = Handlers.int(p["max_tokens"], sizing.maxTokens)
            sizing.tile = max(1, Handlers.int(p["tile"], sizing.tile))
            sizing.maxW = Handlers.int(p["max_width"], sizing.maxW)
            sizing.maxH = Handlers.int(p["max_height"], sizing.maxH)
            format = (p["format"] as? String)?.lowercased() ?? format
            quality = Handlers.num(p["quality"]).map { $0 > 1 ? $0 / 100 : $0 } ?? quality
        }
    }

    static func plan(_ t: Target, region: CGRect?, _ o: Opts) async throws -> CapturePlan {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelperError("Screen Recording permission missing for PuterUse (run: puter-use setup)")
        }
        switch t {
        case .window(let w): return try await Capture.planWindow(w.id, region: region, sizing: o.sizing)
        case .screen: return try await Capture.planScreen(region: region, sizing: o.sizing)
        }
    }

    static func origin(_ t: Target) -> CGPoint {
        if case .window(let w) = t { return Windows.info(w.id)?.frame.origin ?? w.frame.origin }
        return .zero
    }

    /// Screenshot pixel (x, y) → global point, via the last full screenshot of this target. An action
    /// with `units: "pt"` (a macro step) gives window points instead, from the window's top-left corner.
    static func toGlobal(_ t: Target, _ x: Double, _ y: Double, _ a: [String: Any]? = nil) throws -> CGPoint {
        if a?["units"] as? String == "pt", case .window(let w) = t {
            let f = Windows.info(w.id)?.frame ?? w.frame
            guard x >= 0, y >= 0, x <= f.width, y <= f.height else {
                throw HelperError("(\(Int(x)),\(Int(y))) pt is outside the \(Int(f.width))x\(Int(f.height)) pt window")
            }
            return CGPoint(x: f.minX + x, y: f.minY + y)
        }
        guard let m = meta[t.key] else { throw HelperError("take a screenshot first so coordinates have meaning") }
        // The capture's pixel: from a crop's origin, or through the margins left out of the picture, if any. Below a
        // picture cut short at the bottom, the window carries on (blank) to the capture's height.
        var c = CGPoint(x: x, y: y)
        if let crop = m.crop {
            // Only the picture's own pixels: ones off it may be from an earlier, whole picture.
            guard x >= 0, y >= 0, x <= crop.width, y <= crop.height else {
                throw HelperError("(\(Int(x)),\(Int(y))) is outside the \(Int(crop.width))x\(Int(crop.height)) screenshot, which "
                    + "showed only what changed: aim by element or target, or take a screenshot for the whole window")
            }
            c = CGPoint(x: crop.minX + x, y: crop.minY + y)
        } else if let trim = m.trim {
            guard x >= 0, y >= 0, y <= Double(m.height), let q = trim.toCapture(c) else {
                throw HelperError("(\(Int(x)),\(Int(y))) is outside the \(trim.width)x\(trim.height) screenshot")
            }
            c = q
        } else {
            guard x >= 0, y >= 0, x <= Double(m.width), y <= Double(m.height) else {
                throw HelperError("(\(Int(x)),\(Int(y))) is outside the \(m.width)x\(m.height) screenshot")
            }
        }
        let o = origin(t)
        return CGPoint(x: o.x + m.offset.x + c.x * m.size.width / Double(m.width),
                       y: o.y + m.offset.y + c.y * m.size.height / Double(m.height))
    }

    /// Global point → the agent's last picture's pixel; nil where blank margins were left out of it (`Trim`), or
    /// outside a picture of only what changed (`Meta.crop`).
    static func toPixels(_ t: Target, _ p: CGPoint) -> [Int]? {
        guard let m = meta[t.key] else { return nil }
        let o = origin(t)
        var c = CGPoint(x: (p.x - o.x - m.offset.x) * Double(m.width) / m.size.width,
                        y: (p.y - o.y - m.offset.y) * Double(m.height) / m.size.height)
        if let crop = m.crop {
            guard c.x >= crop.minX, c.y >= crop.minY, c.x <= crop.maxX, c.y <= crop.maxY else { return nil }
            c = CGPoint(x: c.x - crop.minX, y: c.y - crop.minY)
        } else if let trim = m.trim {
            guard let q = trim.toImage(c) else { return nil }
            c = q
        }
        return [Int(c.x.rounded()), Int(c.y.rounded())]
    }

    /// The middle of what the agent's last picture of `t` captured (global points), margins left out of it or
    /// not: where a scroll given no place goes.
    static func captureCenter(_ t: Target) -> CGPoint? {
        guard let m = meta[t.key] else { return nil }
        let o = origin(t)
        return CGPoint(x: o.x + m.offset.x + m.size.width / 2, y: o.y + m.offset.y + m.size.height / 2)
    }

    /// A `w` x `h` signature's cells per point for `shot`, and where it starts in `t`'s window (points).
    static func cellScale(_ w: Int, _ h: Int, _ shot: Shot, _ t: Target) -> (perPoint: CGSize, offset: CGPoint) {
        let o = origin(t)
        return (CGSize(width: Double(w) / max(shot.rect.width, 1), height: Double(h) / max(shot.rect.height, 1)),
                CGPoint(x: shot.rect.minX - o.x, y: shot.rect.minY - o.y))
    }

    /// Whether what differs (`d`, from a frame of `t` in `shot`) is only the text cursor blinking: as
    /// accessibility tells it (`onlyCaretBlinked`, with the cursor `then` and `now`), or where it can't, by the
    /// shape of what changed (`CaretShape`, in the field the cursor was in when that's known). Not by its shape
    /// when accessibility says the cursor moved or the text changed, nor after keys, typing or a click
    /// (`typed`).
    static func cursorBlinked(_ d: CellDiff, then: Caret?, now: Caret?, _ shot: Shot, _ t: Target, typed: Bool) -> Bool {
        guard let box = d.box, shot.rect.width > 0, shot.rect.height > 0 else { return false }
        let (perPoint, offset) = cellScale(d.w, d.h, shot, t)
        if let then, let now {
            if onlyCaretBlinked(box, now: now, then: then, scale: perPoint, offset: offset) { return true }
            guard now.same(as: then) else { return false }
        }
        let field = (now ?? then).map { Signature.cells($0.field, perPoint: perPoint, offset: offset) }
        return CaretShape.blinked(d, near: field, perPoint: perPoint, typed: typed)
    }

    /// What an act's settled frame (`now`) shows as changed since the agent's last image (`before`) for whether
    /// its picture is sent: nothing (`change` nil) when all that differs is what keeps moving by itself (`mask`,
    /// cells: `leftOut`) or, of what's left, a text cursor blinking (`blink`: `blinked`). Else the change as
    /// `Signature.diff` gives it, all of it (a picture of another size: the whole picture). This decides only
    /// whether the picture is sent: a wait for a change or for text, and the outline's check that the window
    /// changed though its outline didn't, go by the frames as they are.
    nonisolated static func shownChange(_ now: Signature, from before: Signature, outW: Int, outH: Int, mask: [CGRect],
                                        blink: (CellDiff) -> Bool)
        -> (change: (box: CGRect, fraction: Double)?, leftOut: Bool, blinked: Bool) {
        guard let d = CellDiff(now, from: before) else {
            return (change: (box: CGRect(x: 0, y: 0, width: outW, height: outH), fraction: 1), leftOut: false, blinked: false)
        }
        guard !d.isEmpty else { return (change: nil, leftOut: false, blinked: false) }
        let rest = d.clearing(mask)
        guard !rest.isEmpty else { return (change: nil, leftOut: true, blinked: false) }
        if blink(rest) { return (change: nil, leftOut: rest.count < d.count, blinked: true) }
        return (change: d.change(outW: outW, outH: outH), leftOut: false, blinked: false)
    }

    /// Where a batch's pointer went (global points), so what keeps moving stays in its change where the batch
    /// aimed at it (`Ambient.touched`): each scroll's or move's x,y, and the middle of the picture for a scroll
    /// given none. Nil when one was aimed by element or target, or its point can't be told: nothing is left out.
    static func aimedPoints(_ ran: [[String: Any]], _ t: Target) -> [CGPoint]? {
        var out: [CGPoint] = []
        for a in ran where ["scroll", "move", "mouse_move", "hover"].contains(kind(a)) {
            guard a["element"] == nil, a["target"] == nil else { return nil }
            let xy = num(a["x"]).flatMap { x in num(a["y"]).map { CGPoint(x: x, y: $0) } } ?? point(a["coordinate"])
            if let xy {
                guard let p = try? toGlobal(t, xy.x, xy.y, a) else { return nil }
                out.append(p)
            } else if kind(a) == "scroll", let c = captureCenter(t) {
                out.append(c)
            } else {
                return nil
            }
        }
        return out
    }

    /// Keep `shot` as what coordinates in `t` refer to (and what was over the window then, `Run.look`).
    /// `shown`: it goes to the agent as an image (else it only places what the agent is told in pixels). `sizing`:
    /// how it was captured. One that's the last picture pixel for pixel keeps that one's title, and what showed its
    /// app wasn't drawing it (`Meta.frozen`): nothing has been drawn since.
    static func remember(_ t: Target, _ shot: Shot, _ sig: Signature, shown: Bool, sizing: Sizing? = nil) {
        let o = origin(t)
        let start = AX.uptime(), cursor = caret(t)
        if Trace.on, case .window = t {
            Trace.log(["k": "caret", "ms": ((AX.uptime() - start) * 10_000).rounded() / 10, "found": cursor != nil])
        }
        var now: String?
        if case .window(let w) = t { now = Windows.info(w.id)?.title ?? w.title }
        let (title, frozen) = kept(meta[t.key], sig: sig, title: now)
        meta[t.key] = Meta(offset: CGPoint(x: shot.rect.minX - o.x, y: shot.rect.minY - o.y), size: shot.rect.size,
                           width: shot.image.width, height: shot.image.height, sig: sig, caret: cursor, shown: shown,
                           captured: shot.rect, sizing: sizing, title: title, frozen: frozen)
        Run.look(t)
        if shown { VerifyEdit.seen(t.key) }  // the edits whose pictures were withheld are in this one
    }

    /// How an act starts on a window, from what's kept of it (`m`): `firstLook`, with no picture of it at all,
    /// so one is taken to aim from and coordinates stop; `unseen`, with none the agent was shown (none, or
    /// only the one `find` took to place what it lists): then there's no picture to compare with, so the
    /// result shows the window rather than "no change", and a failed first action shows it too. A batch
    /// begun with open (`opening`) has neither: it moves to the window open brings up.
    nonisolated static func startLook(_ m: Meta?, opening: Bool) -> (firstLook: Bool, unseen: Bool) {
        (!opening && m == nil, !opening && m?.shown != true)
    }

    /// How long one question about the cursor waits for the app: it's asked with every picture, and an app
    /// too slow to answer only loses the blink rule (its cursor blinking counts as a change, as it used to).
    nonisolated static let caretTimeout: Float = 0.3

    /// The text cursor in `t`'s window: the focused text field or text area there and the cursor in it,
    /// relative to the window. Nil when no text element there has the focus, or text is selected (that's
    /// no cursor). Not through `AX.appElement`: a picture mustn't switch on an app's accessibility tree
    /// (Chromium's, Firefox's), and the app gets `caretTimeout` per question, giving up after a slow first.
    static func caret(_ t: Target) -> Caret? {
        guard case .window(let w) = t else { return nil }
        let start = AX.uptime(), app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, caretTimeout)
        guard let f = AX.value(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID(),
              AX.uptime() - start < 0.1 else { return nil }  // a busy app: not worth 8 more questions
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, caretTimeout)
        guard AX.isTextInput(el), let win = AX.value(el, kAXWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        AXUIElementSetMessagingTimeout(win as! AXUIElement, caretTimeout)
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(win as! AXUIElement, &id) == .success, id == w.id,
              let r = AX.selectedRange(el), r.length == 0, let frame = AX.frame(el) else { return nil }
        let o = origin(t)
        return Caret(field: frame.offsetBy(dx: -o.x, dy: -o.y),
                     point: AX.insertionPoint(el, at: r.location)?.offsetBy(dx: -o.x, dy: -o.y),
                     at: r.location, count: AX.value(el, kAXNumberOfCharactersAttribute) as? Int)
    }

    /// The widest a text cursor is drawn (points).
    nonisolated static let caretWidth = 3.0

    /// Whether the cells that differ from the agent's last image (`box`, at the signature's own size) are
    /// only the text cursor blinking: it hasn't moved since then and the text is as long, and they're a
    /// sliver as wide as a cursor (`caretWidth`, plus a cell it may straddle) in its field, at its x, on or
    /// next to its line and no taller than that. Typed or deleted text, a selection, a focus ring coming, a
    /// cursor that moved or anything elsewhere in the field still count. `scale`: cells per point;
    /// `offset`: where the capture starts in the window (points).
    nonisolated static func onlyCaretBlinked(_ box: CGRect, now: Caret, then: Caret, scale: CGSize, offset: CGPoint) -> Bool {
        guard now.same(as: then), box.width <= (caretWidth * scale.width).rounded(.up) + 1 else { return false }
        func cells(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - offset.x) * scale.width, y: (r.minY - offset.y) * scale.height,
                   width: r.width * scale.width, height: r.height * scale.height)
        }
        guard cells(now.field).insetBy(dx: -1, dy: -1).contains(box) else { return false }  // a cursor at its very edge, cells rounding out
        guard let p = now.point else { return true }  // the app didn't say where: the field will do
        // Its line, a line either way: an empty field's place is reported a line off.
        let at = cells(p), line = at.insetBy(dx: 0, dy: -at.height - 1)
        return box.minX - 1 <= at.minX && at.minX <= box.maxX + 1 && box.height <= at.height + 2
            && box.maxY >= line.minY && box.minY <= line.maxY
    }

    /// `act`'s settled frame differs from the agent's last image (`before`, with the cursor `then`) only by
    /// the text cursor (`now`) blinking.
    static func blinked(_ sig: Signature, from before: Signature, then: Caret, now: Caret, _ shot: Shot, _ t: Target) -> Bool {
        guard let box = sig.diff(before, outW: sig.w, outH: sig.h)?.box, shot.rect.width > 0, shot.rect.height > 0 else { return false }
        let o = origin(t)
        return onlyCaretBlinked(box, now: now, then: then,
                                scale: CGSize(width: Double(sig.w) / shot.rect.width, height: Double(sig.h) / shot.rect.height),
                                offset: CGPoint(x: shot.rect.minX - o.x, y: shot.rect.minY - o.y))
    }

    /// The window a reply is about, with whose it is: `yours` (the session opened it), and `used` when the user
    /// has used it since.
    static func describe(_ t: Target) -> [String: Any] {
        switch t {
        case .window(let w):
            let fresh = Windows.info(w.id) ?? w
            var d: [String: Any] = ["id": Int(w.id), "app": AgentBrowser.label(fresh), "title": fresh.title, "on_screen": fresh.onScreen]
            let o = owner(w.id)
            d["yours"] = o != .user
            if o == .shared { d["used"] = true }
            return d
        case .screen:
            return ["id": 0, "app": "screen", "title": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""]
        }
    }

    static func pid(_ t: Target) -> pid_t? {
        if case .window(let w) = t { return w.pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func screenshot(_ p: [String: Any]) async throws -> [String: Any] {
        let t = try resolve(p["window"])
        try Policy.checkLook(pid(t))
        current = t.key
        if readRequested(p["read"]) { return try await readText(t, p["read"]!, p) }  // one element's whole text: ReadText.swift
        let region = try regionPoints(p["region"]).map { try regionRect(t, $0) }
        // (`detail: "low"` for the window's picture; a zoom is a closer look, and no image needs none.)
        let o = region == nil && p["image"] as? Bool != false ? detailed(Opts(p), t) : Opts(p)
        // How the agent looks at this window from now on when an act isn't told (`ViewMode`), once this look is done.
        let mode = viewMode(afterScreenshot: p)
        func looked() { if case .window(let w) = t, let mode { Session.current.modes[w.id] = mode } }
        if p["image"] as? Bool == false {  // accessibility text only: the cheapest way to look
            var out: [String: Any] = ["window": describe(t)]
            if let region, case .window(let w) = t {  // just the words in that area
                out["text"] = try await regionText(t, w, region)
                return out
            }
            AppCards.enabled = p["app_cards"] as? Bool != false
            if case .window(let w) = t, let card = AppCards.card(pid: w.pid) { out["card"] = card }
            looked()
            return try await bearings(out.merging(accessibility(t, o), uniquingKeysWith: { _, new in new }), t) {
                accessibility(t, o)  // read again, once the window is drawn again
            }
        }
        let shot = try await plan(t, region: region, o).run()
        var out = try await result(t, shot, o, zoom: region != nil, text: p["text"] as? Bool == true)
        if region == nil, let note = partShown(t, shot) { out["notes"] = [note] }
        out["changed"] = true
        AppCards.enabled = p["app_cards"] as? Bool != false
        if case .window(let w) = t, let card = AppCards.card(pid: w.pid) { out["card"] = card }
        looked()
        guard region == nil else { return out }  // (a zoom is a closer look, not a new one)
        return try await bearings(out, t) {  // taken again, once the window is drawn again
            try await result(t, try await plan(t, region: nil, o).run(), o, zoom: false, text: p["text"] as? Bool == true)
        }
    }

    /// How a screenshot sets the agent's way of looking at its window (`ViewMode`): one without an image
    /// (its outline) makes acts that aren't told otherwise return the outline's changes rather than a picture;
    /// one with an image, a zoom included, puts them back to pictures. Reading one element's text or a
    /// region's (`read`, or `region` with no image) changes nothing: nil.
    nonisolated static func viewMode(afterScreenshot p: [String: Any]) -> ViewMode? {
        if readRequested(p["read"]) { return nil }
        guard p["image"] as? Bool == false else { return .visual }
        return regionPoints(p["region"]) == nil ? .outline(interactive: p["interactive"] as? Bool == true) : nil
    }

    nonisolated static func kind(_ a: [String: Any]) -> String {
        (a["type"] as? String ?? a["action"] as? String ?? "").lowercased()
    }

    /// Aimed with screenshot coordinates (x,y or a path) rather than an element.
    nonisolated static func aimsByCoordinates(_ a: [String: Any]) -> Bool {
        if kind(a) == "fill" { return (a["fields"] as? [[String: Any]] ?? []).contains(where: aimsByCoordinates) }
        // Window points (a macro step) don't come from a screenshot, so it can't be stale.
        guard a["element"] == nil, a["target"] == nil, a["units"] as? String != "pt" else { return false }
        return pointPath(a) != nil || ["x", "y", "coordinate", "from", "to", "start", "end", "start_coordinate"].contains { a[$0] != nil }
    }

    /// A drag's `path` ([[x,y], …]); nil for a menu's (["View", "Toggle Thing"]) or an open's (a file).
    nonisolated static func pointPath(_ a: [String: Any]) -> [Any]? {
        guard let path = a["path"] as? [Any], path.contains(where: { point($0) != nil }) else { return nil }
        return path
    }

    nonisolated static func needsCoordinates(_ a: [String: Any]) -> Bool {
        if aimsByCoordinates(a) { return true }
        let pointer: Set<String> = ["click", "left_click", "double_click", "triple_click", "right_click", "middle_click",
                                    "move", "mouse_move", "hover", "drag", "left_click_drag", "scroll"]
        return pointer.contains(kind(a)) && a["element"] == nil && a["target"] == nil && a["units"] as? String != "pt"
    }

    /// After these a sheet, dialog or menu may open, so the next action waits a moment to see (`Run.settle`).
    nonisolated static func mayOpen(_ a: [String: Any]) -> Bool {
        switch kind(a) {
        case "move", "mouse_move", "hover", "scroll", "wait", "sleep", "wait_for", "waitfor", "key_down", "keydown",
             "mouse_down", "focus", "set_value", "screenshot", "clipboard", "paste", "read":
            return false
        case "type", "type_text":
            return a["submit"] as? Bool == true || (a["text"] as? String ?? "").hasSuffix("\n")
        case "keypress", "key", "press_key", "hotkey", "key_up", "keyup", "hold_key", "hold":
            return Keys.sequence(a["keys"] ?? a["key"] ?? a["text"]).contains { c in
                c.count > 1 || ["return", "enter", "kpenter", "escape", "esc", "space"].contains(Keys.normalize(c.first ?? ""))
            }
        default:
            return true
        }
    }

    /// Whether the end of a batch gives a menu time to come up (`closeLeftOpenMenu`) after its last action
    /// (`combo`: keys typed into a web page's search box, whose suggestions come a moment later). Not after
    /// navigate: it has waited for its page, and its Return closed the address bar's suggestions (a
    /// screenshot still waits as long as it did: the page may be drawing itself). Nor after a close_window
    /// whose window is gone (`gone`): there's nothing left to open one over.
    nonisolated static func menuWait(_ last: [String: Any]?, combo: Bool, gone: Bool = false) -> Bool {
        guard let last else { return combo }
        if gone, closes(last) { return false }
        return combo || mayOpen(last) && !navigates(last)
    }

    nonisolated static func navigates(_ a: [String: Any]?) -> Bool { a.map { ["navigate", "goto", "go_to"].contains(kind($0)) } == true }

    /// How long `act` sleeps before its first settle frame, from `now` (after the menu check; `quiet`: the
    /// last input). Where it waits in full (`waitsInFull`): settle_ms, and after navigate, no sooner than
    /// the skipped menu poll's 0.4 s plus settle_ms. Elsewhere settle_ms from the last input.
    nonisolated static func firstFrameWait(full: Bool, navigated: Bool, settle: Double, quiet: Double, now: Double) -> Double {
        full ? max(settle, navigated ? quiet + 0.4 + settle - now : 0) : quiet + settle - now
    }

    nonisolated static func closes(_ a: [String: Any]?) -> Bool { a.map { ["close_window", "close"].contains(kind($0)) } == true }

    /// An action as `perform` runs it: the batch's last one is marked `_last` when the end of the batch looks
    /// for a menu after it as long as `AX.choose` would (`menuWait`; `menuLook`: not in foreground mode,
    /// which skips that look). A select, or a pop-up's click with item, then doesn't wait for its menu
    /// itself. Mid-batch it does: the check between actions doesn't wait. Keys starting with "_" are
    /// puter-use's own (`_last`, `_node`, `_pointer`): ones a client sent are dropped first (`external`).
    nonisolated static func marked(_ a: [String: Any], last: Bool, menuLook: Bool) -> [String: Any] {
        var m = external(a)
        if last, menuLook, menuWait(a, combo: false) { m["_last"] = true }
        return m
    }

    /// An action without the internal keys a client may have put in it (starting with "_"), in fill's
    /// fields and submit too.
    nonisolated static func external(_ a: [String: Any]) -> [String: Any] {
        func clean(_ d: [String: Any]) -> [String: Any] { d.filter { !$0.key.hasPrefix("_") } }
        var m = clean(a)
        if let fields = m["fields"] as? [[String: Any]] { m["fields"] = fields.map(clean) }
        if let submit = m["submit"] as? [String: Any] { m["submit"] = clean(submit) }
        return m
    }

    /// How long an act with no screenshot waits before looking for a window its actions opened (`act`):
    /// none if nothing ran (there's nothing to follow), 200 ms if something that ran may open one (or held
    /// keys down: key_down cmd, then n, is a shortcut), else a short gap for the app to catch up before the
    /// caller's next request. An action that failed partway counts as run: it may have pressed something.
    nonisolated static func followWait(_ actions: [[String: Any]], done: Int, failed: Bool) -> Double {
        guard done > 0 else { return 0 }
        let ran = actions.prefix(failed ? done + 1 : done)
        return ran.contains { mayOpen($0) || ["key_down", "keydown"].contains(kind($0)) } ? 0.2 : 0.05
    }

    enum Ending { case status, firstLook, check, settled }

    /// What an act returns at its end: no image with screenshot "never", nor after a batch that only reads
    /// text or the clipboard, or sets it (`clipboardOnly`: nothing it does shows), unless "always". When nothing ran,
    /// because the first action failed or the batch stopped before it for the user's OK (`confirm`): on a
    /// first look, the window it was going to be shown anyway, so the agent can aim from it; else one quick
    /// look, shown only if the window changed since the agent's last image (`check`). An empty batch: the
    /// status alone. A stop before coordinates (not `confirm`) shows the window. Else a settled screenshot
    /// if it changed (after a `confirm` stop, only then), as when the batch moved to a new window (`moved`,
    /// then failed): that one is the agent's now.
    nonisolated static func ending(wantShot: Bool, always: Bool, done: Int, stopped: Bool, confirm: Bool = false,
                                   failed: Bool, firstLook: Bool, moved: Bool = false, clipboardOnly: Bool = false) -> Ending {
        guard wantShot else { return .status }
        if always || moved { return .settled }
        if clipboardOnly { return .status }
        if done > 0 || (stopped && !confirm) { return .settled }
        guard failed || stopped else { return .status }
        return firstLook ? .firstLook : .check
    }

    /// A batch that only reads (text with read, the clipboard) or sets the clipboard: nothing on screen
    /// changes, so there's nothing to look at before or after it (unless "always" asks for a picture anyway).
    nonisolated static func onlyClipboard(_ actions: [[String: Any]], always: Bool) -> Bool {
        !always && !actions.isEmpty && actions.allSatisfy { ["clipboard", "read"].contains(kind($0)) }
    }

    /// `act`'s quick look when nothing ran (`Ending.check`): one frame (`capture`), and what in it differs
    /// from the agent's last image (`before`). Nil when nothing does, or only the text cursor blinked
    /// (`blinked`): then the agent's image still holds, and none is sent.
    static func quickLook(before: Signature, capture: () async throws -> Shot, blinked: (Signature, Shot) -> Bool) async throws
        -> (shot: Shot, change: (box: CGRect, fraction: Double)?) {
        let shot = try await capture()
        let sig = Signature(shot.image)
        guard let change = sig.diff(before, outW: shot.image.width, outH: shot.image.height), !blinked(sig, shot) else {
            return (shot, nil)
        }
        return (shot, change)
    }

    /// What an act was told about a picture at its end: "never", "auto" (only if the window changed) or
    /// "always".
    enum ShotMode { case never, auto, always }

    /// The screenshot mode an act was given (`screenshot`: false for "never", true for "auto" or, with
    /// `always_image`, "always"), or nil when it wasn't: then how the agent last chose to look at the window
    /// decides (`ViewMode`), and "auto" when that's pictures.
    nonisolated static func shotMode(_ p: [String: Any]) -> ShotMode? {
        let given = p["screenshot"].flatMap { $0 is NSNull ? nil : $0 as? Bool }
        if given != false, p["always_image"] as? Bool == true { return .always }
        return given.map { $0 ? .auto : .never }
    }

    /// Whether an act goes by its window's outline rather than pictures, and which outline (true: only what
    /// can be acted on): only when it wasn't told about a picture (`given` nil) and the agent's last look at
    /// the window had no image (`mode`). An outline asked for in the act itself (`text`, `interactive`) says
    /// which; else the one the agent last had. Nil: by pictures.
    nonisolated static func outlineKind(given: ShotMode?, mode: ViewMode?, _ p: [String: Any]) -> Bool? {
        guard given == nil, case .outline(let interactive)? = mode else { return nil }
        return p["text"] as? Bool == true ? p["interactive"] as? Bool == true : interactive
    }

    /// Why an act going by the window's outline (`ViewMode.outline`) shows the window after all, as "auto"
    /// would, from how its batch ended; nil if nothing did. An action failed; it stopped before an action
    /// aimed by position (coordinates come from a picture) or for the user's OK (a press that can't be undone
    /// is looked at before it's made); or it moved to another window.
    nonisolated static func outlineEscalation(failed: Bool, stopped: Bool, confirm: Bool, moved: Bool) -> String? {
        if failed { return "an action failed" }
        if confirm { return "the batch stopped for the user's OK (look before a press that can't be undone)" }
        if stopped { return "the batch stopped before an action aimed by position" }
        if moved { return "the batch moved to another window" }
        return nil
    }

    /// `notes` without `note` (an escalation's, when the act ends with no image after all).
    nonisolated static func dropping(_ note: String, from notes: [String]) -> [String] {
        notes.filter { $0 != note }
    }

    /// Why the window's outline (`text`, as `AX.outline` returned it: nil with no tree; `interactive`: of
    /// what can be acted on) can't stand in for a picture of it, or nil if it can: nothing in it (a canvas, an
    /// app without accessibility), or only part of the window (the walk ran out of time, `cutShort`, or the
    /// outline ran past its length cap: `truncated`, as its registry says, else told by its last lines).
    nonisolated static func outlineProblem(_ text: String?, interactive: Bool, cutShort: Bool, truncated: Bool? = nil) -> String? {
        guard let text else { return "the window has no accessibility tree" }
        if text.isEmpty { return interactive ? "its outline has nothing to act on" : "its outline is empty" }
        if cutShort { return "its outline was cut short (the app answered slowly)" }
        if truncated ?? outlineTruncated(text) { return "its outline is too long to send whole" }
        return nil
    }

    /// Whether an outline ends with the line saying it ran past its length cap (`AX.Registry.truncated` says so
    /// for the outline just written).
    nonisolated static func outlineTruncated(_ text: String) -> Bool {
        text.split(separator: "\n").suffix(2).contains { $0.hasPrefix("… (truncated") }
    }

    /// A batch that only brings its window forward (activate): the window becomes key at its start, as for
    /// keys, so that change of look is taken apart from what the batch does (`Baseline`).
    nonisolated static func activatesOnly(_ actions: [[String: Any]]) -> Bool {
        !actions.isEmpty && actions.allSatisfy { ["activate", "raise", "focus_window"].contains(kind($0)) }
    }

    /// Whether an act's start may change how its window looks by itself, so frames are taken around it
    /// (`Baseline.flip`): only with a picture the agent was shown to compare with (`seen`), the window on
    /// screen, and either its app not held on it yet (`heldHere`: being made active flips its title bar, the
    /// colour of what's selected) or keys to send (`keys`) to a window that isn't key yet (`keyHere`).
    nonisolated static func probesFlip(seen: Bool, onScreen: Bool, heldHere: Bool, keys: Bool, keyHere: Bool) -> Bool {
        seen && onScreen && (!heldHere || (keys && !keyHere))
    }

    /// How long the window gets to draw its new look after being made active or key, before the frame after
    /// it, and before one more if that one still differs from the frame before (s).
    nonisolated static let flipDraw = 0.05, flipRedraw = 0.06

    /// The agent's last image (`before`) as the window looks once `flip` has run (making its app active, the
    /// window key), when that's all that changed: a frame just before it (`capture`) that matches `before`, or
    /// differs only by the text cursor blinking (`blinked`), says nothing else had changed, and the window's
    /// place and what's over it staying the same (`basis`) says the flip opened nothing (a popover an app shows
    /// again as it becomes active). Then the frame after it, once its new look is drawn, is returned, to compare
    /// the act's end with. Else nil, and `before` stands: an outside change is never folded in. `flip` runs
    /// whatever the frames; one that can't be taken (nil) only means nil.
    static func rebase<Basis: Equatable>(_ before: Signature, basis: () -> Basis, capture: () async -> Shot?,
                                         flip: () async throws -> Void, pause: (Double) async -> Void,
                                         blinked: (Signature, Shot) -> Bool) async rethrows -> Signature? {
        let start = basis()
        var preSig: Signature?  // the frame before, when it matches `before`
        if let pre = await capture() {
            let s = Signature(pre.image)
            if s.diff(before, outW: s.w, outH: s.h) == nil || blinked(s, pre) { preSig = s }
        }
        try await flip()
        guard let preSig else { return nil }
        await pause(flipDraw)
        guard let first = await capture() else { return nil }
        var now = Signature(first.image)
        if now.diff(preSig, outW: now.w, outH: now.h) != nil {  // its new look: once more, in case it was still being drawn
            await pause(flipRedraw)
            if let again = await capture() { now = Signature(again.image) }
        }
        return basis() == start ? now : nil
    }

    /// What an act's end is compared with: the agent's last image of its window (`sig`), moved past the
    /// window's own change of look as the act makes its app active or the window key (`flip`), when nothing
    /// else has changed it since that image. Going by the outline, the window as the batch began instead
    /// (`kept` false: it's no image the agent was shown, so what's kept of that stays as it is).
    @MainActor
    final class Baseline {
        private(set) var sig: Signature
        let target: Target
        let opts: Opts
        let caretThen: Caret?  // the text cursor in the agent's image
        let kept: Bool
        /// Keys, typing or a click went to the window since the agent's image (before the batch, or in an action
        /// of it run already): a change shaped like a text cursor may be a character then.
        var typed: Bool
        private var plan: (plan: CapturePlan, basis: PlanBasis?)?

        init(sig: Signature, target: Target, opts: Opts, caretThen: Caret?, kept: Bool = true, typed: Bool = false) {
            (self.sig, self.target, self.opts, self.caretThen, self.kept, self.typed) = (sig, target, opts, caretThen, kept, typed)
        }

        var wid: CGWindowID { target.key }

        /// Run `body` (the activation, or the click that makes the window key) with a frame taken before and
        /// after it (`rebase`). A new baseline also goes into what's kept of the agent's image (`meta`, when
        /// `kept`), so the next act, the window held and key by then, doesn't see the flip either.
        func flip(_ body: () async throws -> Void) async rethrows {
            let t = target
            let new = try await Handlers.rebase(sig, basis: { PlanBasis.of(t) }, capture: { await self.frame() }, flip: body,
                                                pause: { _ = try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                                                blinked: { self.blinked($0, $1) })
            guard let new else { return }
            sig = new
            if kept { Handlers.meta[t.key]?.sig = new }
            if Trace.on { Trace.log(["k": "rebased"]) }
        }

        /// A frame of the window now: one plan for them all, made again when what's over the window or its
        /// place changes. Nil when it can't be taken.
        private func frame() async -> Shot? {
            let basis = PlanBasis.of(target)
            if plan == nil || plan?.basis != basis {
                guard let made = try? await Handlers.plan(target, region: nil, opts) else { return nil }
                plan = (made, basis)
            }
            return try? await plan?.plan.run()
        }

        /// Whether frame `s` differs from the baseline only by the text cursor blinking: where accessibility
        /// can't tell, by its shape (`cursorBlinked`), but for the frame a batch going by the outline began with
        /// (not `kept`): what that's compared with goes by the frames as they are.
        private func blinked(_ s: Signature, _ shot: Shot) -> Bool {
            guard kept else {
                guard let then = caretThen, let now = Handlers.caret(target) else { return false }
                return Handlers.blinked(s, from: sig, then: then, now: now, shot, target)
            }
            guard let d = CellDiff(s, from: sig) else { return false }
            return Handlers.cursorBlinked(d, then: caretThen, now: caretThen == nil ? nil : Handlers.caret(target), shot, target,
                                          typed: typed)
        }
    }

    /// A batch begun with open and no window: the window open brings up is the one it works in, so none is
    /// looked up, captured or activated before (the session's may be anyone's). Not with a macro step: a
    /// macro belongs to an app, known only once open has run.
    nonisolated static func opensFirst(_ p: [String: Any]) -> Bool {
        guard p["window"] == nil || p["window"] is NSNull, let actions = p["actions"] as? [[String: Any]],
              let first = actions.first else { return false }
        return opens(first) && !actions.contains { kind($0) == "macro" }
    }

    nonisolated static func opens(_ a: [String: Any]) -> Bool { ["open", "open_url", "launch"].contains(kind(a)) }

    /// Why the policy refuses actions `from` on of a batch in app `pid` (looking at it, then each of them),
    /// for its errors; nil if it allows them all. Checked before any of them runs.
    static func refusal(_ actions: [[String: Any]], from: Int, pid: pid_t, base: Int) -> String? {
        guard actions.indices.contains(from) else { return nil }
        do { try Policy.checkLook(pid) } catch { return "action \(base + from + 1) (\(kind(actions[from]))): \(error)" }
        for (i, a) in actions.enumerated().dropFirst(from) {
            do { try Policy.checkAction(a, pid: pid) } catch { return "action \(base + i + 1) (\(kind(a))): \(error)" }
        }
        return nil
    }

    /// The app open {url | path | file, app} would open its target in, by the same lookups open makes: nil
    /// when open would fail anyway (its own error says why then).
    static func openApp(_ a: [String: Any]) -> URL? {
        if let name = (a["app"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            return Windows.appURL(name) ?? Windows.runningApp(name)?.bundleURL
        }
        guard let s = (a["url"] ?? a["path"] ?? a["file"]) as? String, !s.isEmpty, let u = try? openable(s) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: u)
    }

    /// The level of `apps` (the policy's, keyed by lowercase bundle id or name) for an app that may not be
    /// running yet: its bundle id's, as `Policy.level` reads a running app's, else the strictest of its
    /// names' (an app's name can be read more than one way before it runs), else full.
    nonisolated static func launchLevel(_ apps: [String: Policy.Level], bundleID: String?, names: [String]) -> Policy.Level {
        if let id = bundleID?.lowercased(), let l = apps[id] { return l }
        return names.compactMap { apps[$0.lowercased()] }.min() ?? .full
    }

    /// The least level that lets action `a` start or use an app: navigate types into it (full); open
    /// only hands it something (click, as for any action that isn't typing).
    nonisolated static func levelToLaunch(_ a: [String: Any]) -> Policy.Level { navigates(a) ? .full : .click }

    /// Before action `a` (open, navigate) starts or uses the app at `url`: does the policy let it? Read by
    /// bundle id before anything is launched; for an app already running, as for any action in it.
    static func checkLaunch(_ url: URL, _ a: [String: Any]) throws {
        let bundle = Bundle(url: url)
        if let id = bundle?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
            return try Policy.checkAction(a, pid: app.processIdentifier)
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
        let info = [bundle?.localizedInfoDictionary, bundle?.infoDictionary].compactMap { $0 }
        let names = [name, url.deletingPathExtension().lastPathComponent]
            + ["CFBundleDisplayName", "CFBundleName"].flatMap { key in info.compactMap { $0[key] as? String } }
        let level = launchLevel(Policy.config.apps, bundleID: bundle?.bundleIdentifier, names: names)
        guard level < levelToLaunch(a) else { return }
        let what: String
        switch level {
        case .deny: what = "keeps agents out of \(name) entirely"
        case .view: what = "lets agents look at \(name) but not act in it"
        case .click: what = "lets agents click in \(name) but not type, press keys or run menu commands"
        case .full: what = "allows it"
        }
        throw HelperError("not allowed: puter-use's policy \(what) (\(kind(a))). The user can change that in \(Policy.file.path)")
    }

    /// The default browser (the app web addresses open in).
    static func defaultBrowser() -> URL? {
        URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    /// The target of an act: its window, as for every command. With none, a batch begun with navigate goes
    /// to a browser: the session's window when that's a browser's, else the default browser's window (the
    /// one its name would mean), the browser started or given a window first if it has none, in the
    /// background, once the policy is known to allow it (read by bundle id, before anything starts). With the
    /// agent's own Firefox on, it goes there instead of the user's Firefox (`AgentBrowser.routes`).
    static func actTarget(_ p: [String: Any]) async throws -> Target {
        let v = p["window"]
        guard let first = (p["actions"] as? [[String: Any]])?.first, navigates(first),
              !(p["actions"] as? [[String: Any]] ?? []).contains(where: { kind($0) == "macro" }) else { return try resolve(v) }
        // The agent's own Firefox, when the setting is on (or it's named): instead of the user's Firefox.
        let agents = AgentBrowser.wanted(p)
        if AgentBrowser.routes(AgentBrowser.aim(v), on: agents ? AgentBrowser.on() : .none, enabled: agents) {
            return try await agentBrowserTarget(first, p, launch: agents)
        }
        guard v == nil || v is NSNull else { return try resolve(v) }
        if let cur = current, cur != 0, let w = Windows.info(cur), isBrowser(w.pid) { return used(w) }
        guard let url = defaultBrowser(), let id = Bundle(url: url)?.bundleIdentifier, browsers.contains(id.lowercased()) else {
            throw HelperError("no window selected: pass window (a browser's name or id, from windows), or use open {url} "
                + "to open the address in the default browser")
        }
        do { try checkLaunch(url, first) } catch {
            throw HelperError("nothing was run: action \(max(int(p["first"], 1), 1)) (\(kind(first))) is \(error)")
        }
        var wins = Windows.targetable(app: id)
        if wins.isEmpty { wins = try await Windows.launch(id) }
        for pid in Set(wins.map(\.pid)) { reviewOwnership(pid) }  // a window the user took over isn't the session's to pick
        let system = { (w: WinInfo) in systemWindow(w, AX.window(pid: w.pid, wid: w.id)) }  // the dictation orb
        guard let w = pick(wins, current: current, own: Session.current.ownRecent, system: system)?.0 else {
            throw HelperError("no window for \(id) (use windows with launch=true)")
        }
        return used(w)
    }

    nonisolated static let keyboardActions: Set<String> = [
        "type", "type_text", "keypress", "key", "press_key", "hotkey", "key_down", "keydown", "key_up", "keyup",
        "hold_key", "hold", "fill", "navigate", "goto", "go_to", "paste",
    ]

    /// Actions that act on the app's keyboard focus: keys (including the modifiers a click or drag holds)
    /// and menu commands, which act on the focused window. That window has to be the app's key one first.
    enum KeyPrimer: Equatable { case none, fromAgentWindow, fromUserWindow, freshHold }

    /// Whether a keyboard act spends a click on its window `wid`, given the window AX says has the app's keyboard
    /// (`focused`) and whose each is (`owner`). Forced, at the start, to move the keyboard here:
    /// - from another of the agent's own windows (`fromAgentWindow`); in the user's front app (`front`) only while
    ///   they leave the keyboard and mouse alone (`quiet`), as they may be typing there;
    /// - from a window of the user's, or one of the agent's they've used, to the agent's own window, only while the
    ///   app is in the background (`fromUserWindow`): as a click there would, and as the agent's clicks there do.
    ///   The window is in front when the user next switches to the app. Never while they're in it.
    /// None, or this one, on a new hold (`Hold.fresh`): AX still names the window, but AppKit has no key window,
    /// so key equivalents go nowhere; that click waits for the first key (`primeKeys`). Otherwise none
    /// (guardKeyboard stops the keys instead).
    nonisolated static func keyPrimer(focused: CGWindowID?, wid: CGWindowID, fresh: Bool, front: Bool = false, quiet: Bool = true,
                                      owner: (CGWindowID) -> Owner) -> KeyPrimer {
        if let focused, focused != wid {
            switch owner(focused) {
            case .agent: return !front || quiet ? .fromAgentWindow : .none
            case .shared, .user: return !front && owner(wid) == .agent ? .fromUserWindow : .none
            }
        }
        return fresh && !front ? .freshHold : .none
    }

    /// Whether keys or a menu command going to `r` now need a new hold's click first (see `primeKeys`).
    static func keysNeedPrimer(_ r: Route) -> Bool {
        guard !r.foreground, r.primer, r.wid != 0, Hold.held[r.pid] == r.wid, Hold.fresh.contains(r.pid) else { return false }
        return keyPrimer(focused: AX.focusedWindow(pid: r.pid), wid: r.wid, fresh: true, owner: { owner($0) }) == .freshHold
    }

    /// On a new hold, the primer's click makes the window key, just before the first key or menu command
    /// goes out: after that action's checks (policy, confirm, guardKeyboard), so a batch that stops before
    /// any key clicks nothing. Once per hold: the click ends `Hold.fresh`. Becoming key changes how the
    /// window looks, so in the act's own window that's taken apart from what the act does (`Baseline`).
    static func primeKeys(_ r: Route) async {
        guard keysNeedPrimer(r) else { return }
        let click = {
            await Input.primer(r)
            await Input.afterPrimer()
        }
        if let base = Session.current.baseline, base.wid == r.wid { await base.flip(click) } else { await click() }
    }

    /// Thrown by a menu command's check on a new hold, so its click goes after the check and before the press.
    struct PrimeFirst: Error {}

    /// Thrown by a menu command's check when another window has the keyboard, so `ensureKeyboard` runs after
    /// item lookup and policy checks and before `kAXEnabledAttribute`.
    struct PromptFirst: Error {}

    nonisolated static func actsOnKeyboardFocus(_ a: [String: Any]) -> Bool {
        if keyboardActions.contains(kind(a)) || kind(a) == "menu" || kind(a) == "menu_item" { return true }
        // A move holds keys only when it names a modifier (OpenAI's computer use sends an empty list otherwise).
        if ["move", "mouse_move", "hover"].contains(kind(a)) {
            return Keys.splitCombo(modifierKeys(a)).contains { Keys.modifiers[Keys.normalize($0)] != nil }
        }
        guard a["keys"] != nil || a["modifiers"] != nil || modifierText(a) != nil else { return false }
        return ["click", "left_click", "double_click", "triple_click", "right_click", "middle_click", "mouse_down", "drag",
                "left_click_drag"].contains(kind(a))
    }

    /// The app's menu bar as text (every command and its shortcut), or the items matching `query`.
    static func menus(_ p: [String: Any]) throws -> [String: Any] {
        let t = try resolve(p["window"])
        guard let pid = pid(t) else { throw HelperError("no app for that target") }
        try Policy.checkLook(pid)
        let q = (p["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ["window": describe(t), "text": AX.menuListing(pid: pid, query: q)]
    }

    /// The opt-in accessibility view: focused element plus the numbered outline. Never sent by default.
    /// `within` (global points) limits the outline to one area and skips the focus line. With `diff`, and
    /// an earlier outline of this window that this session was sent (of the same kind, or a full one for an
    /// interactive one now), just what changed since when that's much shorter (`OutlineDiff`).
    static func accessibility(_ t: Target, _ o: Opts = Opts([:]), within: CGRect? = nil, diff: Bool = false) -> [String: Any] {
        let look = outlineLook(t, o, within: within, diff: diff)
        look.keep()
        return look.out
    }

    /// `accessibility`'s view, before it's sent: its fields (`out`), why it can't stand in for a picture of
    /// the window (`problem`, see `outlineProblem`; nil when it can), and `keep`, which records it as the
    /// outline the agent was sent (what the next diff is against). Not kept, the agent's last outline stands.
    /// `unchanged`: with `diff`, the outline says just what the agent's last one did, its text included (nothing
    /// to tell). Kept, the changes leave the agent what it had past where a cut outline stops (`Changes.baseline`).
    static func outlineLook(_ t: Target, _ o: Opts, within: CGRect? = nil, diff: Bool)
        -> (out: [String: Any], problem: String?, keep: () -> Void, unchanged: Bool) {
        var out: [String: Any] = [:]
        if within == nil, let pid = pid(t), let f = AX.focusedSummary(pid: pid, wid: t.key) { out["focused"] = f }
        guard case .window(let w) = t else { return (out, "the screen has no outline", {}, false) }
        let full = AX.outline(pid: w.pid, wid: w.id, within: within, maxChars: o.maxChars, interactive: o.interactive)
        out["text"] = full.map { $0.isEmpty ? (o.interactive
            ? "(no interactive elements in this window; try text: true, or find)"
            : "(no accessibility elements in this window)") : $0 } ?? "(no accessibility tree for this window)"
        let written = full != nil ? AX.registries[w.id] : nil
        let problem = outlineProblem(full, interactive: o.interactive, cutShort: written?.cutShort == true,
                                     truncated: written?.truncated)
        guard within == nil, let reg = written, let whole = full else { return (out, problem, {}, false) }
        if reg.cutShort {
            // Only part of the window: sent whole (a diff would list the rest as gone), and not kept to
            // diff the next one against (it would list the rest as new).
            return (out, problem, { Session.current.sentOutlines[w.id] = nil }, false)
        }
        let now = OutlineDiff.Outline(reg, interactive: o.interactive)  // now: the registry is rewritten by later outlines
        let changes = diff ? Session.current.sentOutlines[w.id].flatMap { OutlineDiff.changes($0, now, full: whole) } : nil
        if let changes { out["text"] = changes.text }
        let keep = changes?.baseline ?? now
        return (out, problem, { Session.current.sentOutlines[w.id] = keep }, changes?.unchanged ?? false)
    }

    /// The reply's picture of `shot` (and the outline, with `text`), kept as what the agent's coordinates refer to
    /// unless it's a zoom. `trim`: an act's picture, which leaves blank margins out (`Trim`, unless `trim_blank`
    /// is false; a window's, not a zoom); a screenshot's never does, as it would cut the ends of a browser's
    /// toolbar and tabs too. `ambient`: what kept moving by itself in the frames before it (`Meta.ambient`).
    /// `crop`: an act's picture of only what changed, this part of the capture (pixels, `ChangeCrop`): marks are
    /// drawn on it, it's never trimmed, and without marks or an outline the reply has the outline of what can be
    /// acted on in it (`crop_outline`; `cropOutline`: that, read already to decide on the crop). `withhold`: the
    /// reply is marked verified (`VerifyEdit`), so the agent isn't shown its picture, crop or whole: nothing of it is
    /// kept as what the agent saw (`VerifyEdit.remembers`; nor does a crop count towards the whole pictures due), and
    /// its own record goes to `withhold` instead.
    static func result(_ t: Target, _ shot: Shot, _ o: Opts, zoom: Bool, text: Bool, diff: Bool = false, trim: Bool = false,
                       ambient: [CGRect] = [], crop: CGRect? = nil, cropOutline given: String?? = nil,
                       withhold: ((Meta) -> Void)? = nil) async throws -> [String: Any] {
        let sig = Signature(shot.image)  // (of the whole capture, margins and all)
        let crops = meta[t.key]?.crops ?? 0  // (crops in a row before this picture; what's kept is replaced next)
        // The scale of the last image of the window the agent was shown (px/pt), before this one replaces it.
        let seenScale = meta[t.key].flatMap { $0.shown && $0.size.width > 0 ? Double($0.width) / $0.size.width : nil }
        let keep = VerifyEdit.remembers(zoom: zoom, verified: withhold != nil)
        if keep {  // the image goes to the agent in this reply
            remember(t, shot, sig, shown: true, sizing: o.sizing)
            meta[t.key]?.ambient = ambient
        }
        // A picture withheld from the agent: its own record, apart from what the agent saw (for where it changed).
        var own: Meta?
        if !keep, !zoom {
            let corner = origin(t)
            own = Meta(offset: CGPoint(x: shot.rect.minX - corner.x, y: shot.rect.minY - corner.y), size: shot.rect.size,
                       width: shot.image.width, height: shot.image.height, sig: sig, caret: caret(t), captured: shot.rect)
        }
        // What the picture shows: the whole capture, or only the part of it round what changed.
        var view = shot
        var shownPart: CGRect?  // the part of the capture a crop shows (pixels)
        if let crop, !zoom, case .window = t,
           case let c = crop.integral.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)),
           !c.isNull, !c.isEmpty, let part = shot.image.cropping(to: c) {
            shownPart = c
            view = Shot(image: part, rect: ChangeCrop.points(c, of: shot))
            if keep {
                meta[t.key]?.crop = c
                meta[t.key]?.crops = crops + 1
            }
            own?.crop = c
        }
        var acc: [String: Any] = [:]
        if text { acc = accessibility(t, o, within: zoom ? shot.rect : nil, diff: diff) }
        var image = view.image
        if o.marks, case .window(let w) = t {
            // Number what can be acted on (this outline isn't sent). Not when the outline just sent ran out of
            // time: this would too; its numbers are marked.
            if !text || !o.interactive, !(text && AX.registry(w.id).cutShort) {
                _ = AX.outline(pid: w.pid, wid: w.id, within: zoom || shownPart != nil ? view.rect : nil, maxChars: 40_000,
                               interactive: true)
            }
            let reg = AX.registry(w.id)
            let marks = reg.lines.compactMap { entry -> Marks.Mark? in
                guard let n = reg.nodes[entry.0], let f = n.frame, AX.actionable.contains(n.role) else { return nil }
                return Marks.Mark(id: entry.0, rect: f, role: n.role)
            }
            image = Marks.draw(view, marks)
        }
        // Blank margins left out, planned on the picture as it's sent (marks' badges are in it, so no cut goes
        // through one), never through the focused text field. (Not from a crop: it's round what changed already.)
        var cut: Trim?
        if trim, !zoom, shownPart == nil, o.trimBlank, case .window = t, let m = own ?? meta[t.key], let px = Pixels(image) {
            let s = Double(shot.scale)
            let focus = m.caret.map { c in
                CGRect(x: (c.field.minX - m.offset.x) * s, y: (c.field.minY - m.offset.y) * s,
                       width: c.field.width * s, height: c.field.height * s)
            }
            if let plan = Trim.plan(px, perPoint: s, protect: focus.map { [$0] } ?? [], tile: o.sizing.tile),
               let cropped = plan.crop(image) {
                cut = plan
                image = cropped
                if keep { meta[t.key]?.trim = plan }
                own?.trim = plan
            }
        }
        let (data, mime) = Capture.encode(image, format: o.format, quality: o.quality, maxBytes: o.maxBytes)
        var out: [String: Any] = [
            "image": data.base64EncodedString(), "mime": mime, "width": image.width,
            "height": image.height, "zoom": zoom, "window": describe(t),
            "scale": (Double(shot.scale) * 100).rounded() / 100,  // its pixels a point
        ]
        // The same window at another scale than the agent's last image of it looks another size: its size in points
        // says it isn't.
        if case .window(let w) = t, tellsWindowSize(scale: Double(shot.scale), last: seenScale, zoom: zoom) {
            let f = Windows.info(w.id)?.frame ?? w.frame
            out["window_pt"] = [Int(f.width.rounded()), Int(f.height.rounded())]
        }
        if let cut {
            // What was left out, for the status line: the whole capture's size, and columns cut at each side (the
            // right's left of the scroll bar, which stays) and rows at the bottom.
            out["trimmed"] = ["left": cut.left, "right": cut.right, "bottom": cut.bottom, "scroll_bar": cut.split,
                              "full": [cut.fullWidth, cut.fullHeight]] as [String: Any]
        }
        if shownPart != nil, let box = (own ?? meta[t.key])?.cropInWindow {
            // What the crop shows, in window points (as change_box gives a box), for the status line.
            out["crop"] = [Int(box.minX), Int(box.minY), Int(box.maxX), Int(box.maxY)]
            // The numbers to act on what it shows by, when neither marks nor an outline give them.
            if !o.marks, !text, case .window(let w) = t, let outline = given ?? cropOutline(w, within: view.rect) {
                out["crop_outline"] = outline
            }
        }
        if o.lowDetail, !zoom {
            // How sparse the picture is (px per point) and the text height that allowed it (points; none: not known).
            var d: [String: Any] = ["level": "low", "scale": (Double(shot.scale) * 100).rounded() / 100]
            if let h = o.textHeight { d["text_height"] = (h * 10).rounded() / 10 }
            out["detail"] = d
        }
        if let own { withhold?(own) }
        out.merge(acc) { _, new in new }
        return out
    }

    /// What can be acted on in the part of window `w` a picture of only what changed shows (`within`, global
    /// points), numbered as in its outline (`AX.outline`, interactive), so the agent can act on what it sees by
    /// element. Nil when there's nothing, it ran out of time, or asking would switch on the app's tree
    /// (`treeReady`): a picture never does.
    static func cropOutline(_ w: WinInfo, within: CGRect) -> String? {
        guard treeReady(w.pid),
              let text = AX.outline(pid: w.pid, wid: w.id, within: within, maxChars: ChangeCrop.outlineChars, interactive: true),
              !text.isEmpty, !AX.registry(w.id).cutShort else { return nil }
        return text
    }

    /// `o` for a picture of `t` at `detail: "low"` (`lowDetail`): its scale as low as keeps the window's text
    /// readable (`DetailLow`), by the text height accessibility gives (`AX.textHeight`; not asked where that would
    /// switch on the app's tree, `treeReady`, nor for the screen). Else `o` as it is.
    static func detailed(_ o: Opts, _ t: Target) -> Opts {
        guard o.lowDetail else { return o }
        var out = o
        if case .window(let w) = t, treeReady(w.pid) { out.textHeight = AX.textHeight(pid: w.pid, wid: w.id) }
        out.sizing.scale = DetailLow.scale(textHeight: out.textHeight, normal: o.sizing.scale)
        return out
    }

    // MARK: - actions

    static func route(_ t: Target, at p: CGPoint?, foreground: Bool) throws -> Route {
        switch t {
        case .window(let w):
            let fresh = Windows.info(w.id) ?? w
            if let p, !foreground, let pop = Windows.popup(over: fresh, at: p) {
                return Route(pid: w.pid, wid: pop.id, frame: pop.frame, foreground: false, primer: false)
            }
            return Route(pid: w.pid, wid: w.id, frame: fresh.frame, foreground: foreground)
        case .screen:  // whichever app is there: its policy applies
            if let p, let w = Windows.at(p) {
                try Policy.checkRoute(pid: w.pid, keyboard: false)
                return Route(pid: w.pid, wid: w.id, frame: w.frame, foreground: foreground)
            }
            guard let app = NSWorkspace.shared.frontmostApplication else { throw HelperError("no frontmost app") }
            try Policy.checkRoute(pid: app.processIdentifier, keyboard: p == nil)
            return Route(pid: app.processIdentifier, wid: 0, frame: .zero, foreground: foreground)
        }
    }

    /// Whether a click posted at a point that routes to window `routedTo` lands in one of the app's pop-ups (a menu,
    /// or a suggestions or saved-data list: `Run.popupLayer`, from `layer`) lying over the element it's aimed at,
    /// which is in the target window (`elementWindow`). An element in a sheet, panel or menu of its own (or one
    /// whose window isn't known) is left as it was.
    nonisolated static func popupCovers(routedTo: CGWindowID, target: CGWindowID, layer: Int?, elementWindow: CGWindowID?) -> Bool {
        routedTo != target && elementWindow == target && layer.map(Run.popupLayer) == true
    }

    /// route(t, at:) for every point of a move that crosses the app's windows (into a submenu), with the
    /// windows looked up once: a lookup per frame would hold the pointer up.
    static func router(_ t: Target) -> ((CGPoint) -> Route?)? {
        guard case .window(let w) = t else { return nil }
        let fresh = Windows.info(w.id) ?? w
        let pops = Windows.popups(over: fresh)
        return { p in
            if let pop = pops.first(where: { $0.frame.contains(p) }) {
                return Route(pid: w.pid, wid: pop.id, frame: pop.frame, foreground: false, primer: false)
            }
            return Route(pid: w.pid, wid: w.id, frame: fresh.frame, foreground: false)
        }
    }

    static func modifierFlags(_ v: Any?) -> CGEventFlags {
        var flags: CGEventFlags = []
        for k in Keys.splitCombo(v) { if let f = Keys.modifiers[Keys.normalize(k)] { flags.insert(f) } }
        return flags
    }

    /// Resolve an action's target point: an element (by number or by what it says) or screenshot
    /// coordinates. Text with no accessibility element is looked for on screen. `vet`: the policy's checks on
    /// the element, run before it's scrolled into view (a stop for the user's OK leaves everything as it was);
    /// `vetRead`, those on the line text read off the screen was found in, with no element to check. A window its app
    /// was brought forward to draw again as the screen was about to be read (`Redrawn`) is looked in again, once
    /// (`again`: this is that look).
    static func actionPoint(_ a: [String: Any], _ t: Target, required: Bool = true, vet: ((AX.Node) throws -> Void)? = nil,
                            vetRead: ((String) throws -> Void)? = nil, again: Bool = false) async throws -> (CGPoint, AX.Node?)? {
        // The element a compound action (type, fill) has just looked up and checked (internal `_node`): that
        // one, not a second search that could find another on a page that re-rendered.
        if let n = a["_node"] as? AX.Node {
            try reachable(n.element, aimName(a))
            return try await aimAt(n, aimName(a), vet: vet)
        }
        if let idx = num(a["element"]), case .window(let w) = t {
            let n = try await numbered(w, Int(idx), t)
            try reachable(n.element, "element \(Int(idx))")
            return try await aimAt(n, "element \(Int(idx))", vet: vet)
        }
        if let v = a["target"] {
            // A macro step names what it pressed and where it was: see Macros.spot.
            let saved = a["units"] as? String == "pt" ? num(a["x"]).flatMap { x in num(a["y"]).map { (x, $0) } } : nil
            if let (x, y) = saved, a["spot"] as? Bool == true {
                if let (p, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a), strict: true) {
                    TargetLookup.current?.found = true
                    return (p, n)
                }
                throw HelperError("\(try spec(v).description) isn't where it was when the macro was saved (others show the "
                    + "same), so nothing was pressed")
            }
            if saved == nil, a["spot"] as? Bool == true { throw Macros.noSpot(v) }
            let n: AX.Node
            do {
                let (id, found) = try findOne(v, t)
                guard AX.center(found) != nil else { throw HelperError("element \(id) has no position") }
                n = found
            } catch {
                if let (x, y) = saved, !(error is Behind) {
                    if let (p, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a)) {
                        TargetLookup.current?.found = true
                        return (p, n)
                    }
                    throw HelperError("\(error) (a macro step: what it pressed isn't where it was, so nothing was pressed)")
                }
                guard let miss = error as? NotFound else { throw error }
                do {
                    let read = try await readOffScreen(v, t)
                    try vetRead?(read.line)
                    return (read.point, nil)
                } catch is Redrawn where !again {
                    return try await actionPoint(a, t, required: required, vet: vet, vetRead: vetRead, again: true)
                } catch let e as Missing {
                    // Not on the screen either: missing only if nothing off screen showed it (that's listed then).
                    let text = "\(e)\(miss.hint)"
                    throw miss.clean ? Missing(description: text) : HelperError(text)
                } catch let e as NotDrawn.Miss {
                    throw e  // the window isn't being drawn: that alone, not what's like it (the browser's own controls)
                } catch let e as HelperError where !miss.hint.isEmpty {
                    throw HelperError("\(e)\(miss.hint)")  // with what's off screen showing it, and what's near it
                }
            }
            return try await aimAt(n, try spec(v).description, vet: vet)  // scrolled to first if it's out of view
        }
        if let x = num(a["x"]), let y = num(a["y"]) { return (try toGlobal(t, x, y, a), nil) }
        if let pt = point(a["coordinate"]) { return (try toGlobal(t, pt.x, pt.y, a), nil) }
        if required { throw HelperError("\(a["type"] ?? "action") needs x,y, element or target") }
        return nil
    }

    static func perform(_ a: [String: Any], _ run: Run) async throws {
        let t = run.target, foreground = run.foreground
        let type = kind(a)
        let flags = modifierFlags(modifierKeys(a))  // (a click's text too, as Anthropic's computer use gives them)
        let pressing: Set<String> = ["click", "left_click", "double_click", "triple_click", "right_click", "middle_click",
                                     "drag", "left_click_drag", "mouse_down"]
        if run.heldButton != nil, pressing.contains(type) {
            throw HelperError("the \(run.heldButton!.button) button is held down: mouse_up first")
        }
        switch type {
        case "click", "left_click", "double_click", "triple_click", "right_click", "middle_click":
            var button = (a["button"] as? String)?.lowercased() ?? "left"
            if type == "right_click" { button = "right" }
            if type == "middle_click" { button = "middle" }
            var count = int(a["count"] ?? a["clicks"], 1)
            if type == "double_click" { count = 2 }
            if type == "triple_click" { count = 3 }
            let pressed = button
            // Text read off the screen (no element to ask) is judged by its line, as a control with that name would be.
            let vetRead: ((String) throws -> Void)? = button == "left" ? { try Policy.checkReadPress(a, read: $0) } : nil
            guard let (aimed, node) = try await actionPoint(a, t, vet: { try clickChecks(a, $0, button: pressed) },
                                                            vetRead: vetRead) else { return }
            var p = aimed
            var r = try route(t, at: p, foreground: foreground)
            if button == "left" { try Policy.checkPress(a, node: node, at: p, pid: r.pid) }
            if let item = a["item"], let last = AX.menuPath(item).last {
                try Policy.checkItem(a, last)
                try Policy.checkPointerItem(r.pid, last)
            }
            // An indexed element is pressed through accessibility, which works in the background with no
            // event routing at all; the pointer still travels there (and the app sees it hover).
            // Modifiers held by key_down count as much as the click's own keys.
            let allFlags = flags.union(Input.held)
            if let item = a["item"], AX.menuPath(item).contains(where: { AX.menuKey($0) == "services" }) {
                throw HelperError("Services hand what's selected to other apps; puter-use doesn't use them")
            }
            if !flags.isEmpty { try await ensureKeyboard(mainRoute(t, r), run: run, action: type) }  // its modifiers go to whichever window has the keyboard
            // A pop-up's item is chosen through accessibility (see popUpButton).
            if let item = a["item"], AX.menuPath(item).count == 1, button == "left", count == 1, allFlags.isEmpty,
               !foreground, let popup = popUpButton(node?.element ?? AX.element(pid: r.pid, at: p)) {
                let want = AX.menuPath(item)[0]
                if let match = AX.optionTitle(popup, want) { try Policy.checkItem(a, match) }
                VerifyEdit.clicking(node, at: p, pid: r.pid)  // where it went, when the act checks its edits
                await pointer.move(to: p, r)
                await Input.sleep(clickTiming.aim())
                pointer.click()
                let keys = try? route(t, at: nil, foreground: false)  // for a web page's pop-up, if need be
                let chose = try await AX.choose(popup, want, menuLater: a["_last"] as? Bool == true, typeAhead: keys,
                                                click: { try await clickToOpen(popup, t) }) {
                    try Policy.checkItem(a, $0)
                }
                if AX.menuKey(chose) != AX.menuKey(want) { notes.append("chose \"\(chose)\"") }
                return
            }
            // A menu to choose from is opened with a real click: one opened through accessibility doesn't
            // follow the pointer.
            var viaAX = node.map { AX.isPressable($0.element) } == true && count == 1 && allFlags.isEmpty && !foreground
                && (button == "left" || button == "right") && a["_pointer"] == nil && a["item"] == nil
            // Web content in Firefox gets a real click instead: its accessibility press fires no pointer
            // events, which many web controls go by (see webAim). Aimed where the page really shows it.
            var web = false
            var over: String?  // pressed because something's over it: what (a click there would land on that)
            if viaAX, button == "left", let node, case .window(let w) = t,
               let how = try await webAim(node, w.id, pid: r.pid) {
                switch how {
                case .post(let q):
                    let rq = try route(t, at: q, foreground: false)
                    if rq.wid == w.id {
                        (p, r, viaAX, web) = (q, rq, false, true)
                    } else {  // a window of the app over it there (picture-in-picture, a smaller one) would take it
                        over = "is under another window of \(w.app) (#\(rq.wid))"
                    }
                case .press(let why):
                    over = why
                }
            }
            // A click aimed at an element but posted where one of the app's pop-ups lies over it (a suggestions or
            // saved-data list over the next field) would land in the pop-up, maybe on an entry that fills the form
            // in: the pop-up is closed first, and if it stays, nothing is clicked.
            if !viaAX, !foreground, let node, case .window(let w) = t,
               popupCovers(routedTo: r.wid, target: w.id, layer: Windows.info(r.wid)?.layer, elementWindow: AX.windowID(node.element)) {
                await closeSuggestions(r.pid, before: "clicking \(aimName(a))", route: try? route(t, at: nil, foreground: false))
                r = try route(t, at: p, foreground: false)
                if popupCovers(routedTo: r.wid, target: w.id, layer: Windows.info(r.wid)?.layer, elementWindow: w.id) {
                    throw HelperError("a pop-up of \(w.app) (#\(r.wid)) lies over \(aimName(a)) and couldn't be closed, so nothing "
                        + "was clicked (the click would land in it). keypress Escape may close it")
                }
            }
            // A link followed or a form sent by this click: the batch waits for the page it goes to.
            if run.pageMark == nil, button == "left", count == 1, allFlags.isEmpty, a["item"] == nil, isBrowser(r.pid),
               let mark = pageMark(at: node?.element ?? AX.element(pid: r.pid, at: p), run,
                                   watch: a["_submit"] != nil ? submitWatch : nil) {
                run.pageMark = mark
            }
            // Where it goes (a checkbox it names, as an edit), when the act checks its edits.
            VerifyEdit.clicking(node, at: p, pid: r.pid)
            if foreground { prepareForeground(r) }
            if !viaAX { await Input.primer(r) }
            let mods = await Input.pressModifiers(flags, r, typist: clickTiming)  // keys held on the way, as a hand does
            await pointer.move(to: p, r)
            await Input.sleep(clickTiming.aim())
            // The page may have moved while the pointer was on its way: aim again once; else press it.
            if web, let node, case .window(let w) = t, blocked(reach(node, at: p, wid: w.id, pid: r.pid)) != nil {
                if let seen = visiblePart(node, w.id), case .post(let q) = aim(node, seen, wid: w.id, pid: r.pid),
                   case let rq = try route(t, at: q, foreground: false), rq.wid == w.id {
                    (p, r) = (q, rq)
                    await pointer.move(to: p, r)
                    await Input.sleep(clickTiming.aim())
                }
                if let el = blocked(reach(node, at: p, wid: w.id, pid: r.pid)) {
                    (viaAX, web) = (true, false)
                    over = "looks covered by \(coverName(el)) (or the page moved under the pointer)"
                }
            }
            if viaAX, let node, AX.perform(node, button == "right" ? "showmenu" : "press") {
                if let over { notes.append("\(aimName(a)) \(over); pressed it through accessibility") }
                pointer.click()
                return
            }
            if viaAX, let over {  // a click at its spot would land on what's over it
                await Input.releaseModifiers(mods, r, typist: clickTiming)
                throw HelperError("\(aimName(a)) \(over), and pressing it through accessibility didn't work: nothing was done")
            }
            if viaAX {  // no accessibility press: click after all
                await Input.primer(r)
                Input.mouse(.mouseMoved, p, r)
            }
            // Text views judge a click in the selection, or a shift-click, by the hardware button and Shift
            // key, which the background doesn't touch (see TextSelection).
            let textSpot = !foreground && button == "left" && count == 1 && (allFlags.isEmpty || allFlags == .maskShift)
                ? AX.textSpot(pid: r.pid, wid: r.wid, at: p) : nil
            let selectedBefore = textSpot.flatMap { AX.selectedRange($0.element) }
            if allFlags.isEmpty, let textSpot, AX.clearForClick(textSpot, selectedBefore) { await Input.ms(20) }
            pointer.click()
            await Input.press(p, r, button: button, count: count, flags: flags, typist: clickTiming)
            await Input.releaseModifiers(mods, r, typist: clickTiming)
            if let textSpot {
                if allFlags.isEmpty { await AX.settleClick(textSpot, before: selectedBefore) }
                else { await AX.settleShiftClick(textSpot, before: selectedBefore) }
            }
            if a["item"] != nil { try await pickFromMenu(a, r, t) }
        case "move", "mouse_move", "hover":
            guard let (p, _) = try await actionPoint(a, t) else { return }
            let r = try run.heldButton?.route ?? route(t, at: p, foreground: foreground)
            // Its keys (OpenAI's computer use gives them) are held on the way, as a click's are: the moves carry them.
            // Not in an app the agent may only look at (a move alone is looking).
            if !flags.isEmpty, case let level = Policy.level(r.pid), level <= .view {
                throw Policy.refusal(r.pid, level, doing: "move holding keys")
            }
            if !flags.isEmpty { try await ensureKeyboard(mainRoute(t, r), run: run, action: type) }  // its modifiers go to whichever window has the keyboard
            let mods = await Input.pressModifiers(flags, r, typist: clickTiming)
            await pointer.move(to: p, r, button: run.heldButton?.button)  // a button is down: this is a drag
            await Input.releaseModifiers(mods, r, typist: clickTiming)
        case "mouse_down":
            let button = (a["button"] as? String)?.lowercased() ?? "left"
            var p: CGPoint
            var node: AX.Node?
            let vet: (AX.Node) throws -> Void = { n in
                if button == "left" { try Policy.checkPress(a, node: n, at: nil, pid: AX.pidOf(n.element) ?? 0) }
            }
            let vetRead: ((String) throws -> Void)? = button == "left" ? { try Policy.checkReadPress(a, read: $0) } : nil
            if let (q, n) = try await actionPoint(a, t, required: false, vet: vet, vetRead: vetRead) { (p, node) = (q, n) } else {
                guard let tip = pointer.tip else { throw HelperError("mouse_down needs x,y or element") }
                p = tip
            }
            let r = try route(t, at: p, foreground: foreground)
            if button == "left" { try Policy.checkPress(a, node: node, at: p, pid: r.pid) }
            let mkeys = Keys.splitCombo(a["keys"] ?? a["modifiers"])
            if !mkeys.isEmpty {
                for k in mkeys {
                    if Keys.modifiers[Keys.normalize(k)] == nil { _ = try Keys.parseCombo([k]) }
                }
                try await ensureKeyboard(mainRoute(t, r), run: run, action: type)
            }
            if foreground { prepareForeground(r) }
            await Input.primer(r)
            await pointer.move(to: p, r)
            await Input.sleep(clickTiming.aim())
            await Input.afterPrimer()  // its keys and button go down next
            // Its keys stay down with the button, as a hand holds shift through a shift-drag.
            if !mkeys.isEmpty { try guardKeyboard(mainRoute(t, r)) }
            for k in mkeys where !run.heldKeys.contains(where: { $0.name == Keys.normalize(k) }) {
                try run.keyDown(k, r)
                run.buttonKeys.append(k)
                await Input.sleep(clickTiming.modifierLead())
            }
            let (down, _, _, btn) = Input.buttonTypes(button)
            try Connection.check()  // no button goes down for a batch that's been given up
            Input.newClickGroup()
            Input.mouse(down, p, r, button: btn)
            pointer.click()
            run.heldButton = (button, r, p)
        case "mouse_up":
            guard let (button, r, _) = run.heldButton else { throw HelperError("no mouse button is down (mouse_down first)") }
            if let (p, _) = try await actionPoint(a, t, required: false) {
                // Cut short: the button stays held, and the cancel ends the drag (`endDrag`), so it isn't
                // dropped partway.
                guard await pointer.move(to: p, r, button: button),
                      await pointer.hold(clickTiming.clickHold(), r, button: button) else { throw Cancelled() }
            }
            try Connection.check()
            let (_, up, _, btn) = Input.buttonTypes(button)
            Input.mouse(up, pointer.tip ?? CGPoint(x: r.frame.midX, y: r.frame.midY), r, button: btn, flags: flags)
            run.heldButton = nil
            for k in run.buttonKeys.reversed() {
                await Input.sleep(clickTiming.modifierTrail())
                try? run.keyUp(k, r)
            }
            run.buttonKeys = []
        case "drag", "left_click_drag":
            var pts: [CGPoint] = []
            if let path = a["path"] as? [Any] {
                for item in path { if let q = point(item) { pts.append(try toGlobal(t, q.x, q.y, a)) } }
            } else {
                if let s = point(a["from"] ?? a["start"] ?? a["start_coordinate"]) { pts.append(try toGlobal(t, s.x, s.y, a)) }
                else if let x = num(a["x"]), let y = num(a["y"]) { pts.append(try toGlobal(t, x, y, a)) }
                if let e = point(a["to"] ?? a["end"] ?? a["coordinate"]) { pts.append(try toGlobal(t, e.x, e.y, a)) }
            }
            guard pts.count >= 2 else { throw HelperError("drag needs path [[x,y],[x,y],...] (or from/to)") }
            let r = try route(t, at: pts[0], foreground: foreground)
            let button = (a["button"] as? String) ?? "left"
            // Down and up on a button presses it, as a click would.
            if button == "left" { try Policy.checkPress(a, node: nil, at: pts[0], pid: r.pid) }
            if !flags.isEmpty { try await ensureKeyboard(mainRoute(t, r), run: run, action: type) }  // its modifiers go to whichever window has the keyboard
            if foreground { prepareForeground(r) }
            let (down, up, _, btn) = Input.buttonTypes(button)
            // Text views judge a drag by the hardware button, which is up in the background (see TextSelection).
            let textStart = !foreground && button == "left" && flags.isEmpty ? AX.textSpot(pid: r.pid, wid: r.wid, at: pts[0]) : nil
            let selectedBefore = textStart.flatMap { AX.selectedRange($0.element) }
            await Input.primer(r)
            let mods = await Input.pressModifiers(flags, r, typist: clickTiming)
            let there = await pointer.move(to: pts[0], r)
            await Input.sleep(clickTiming.aim())
            await Input.afterPrimer()
            if !there || Connection.hungUp {  // given up before the button went down
                await Connection.ungated { await Input.releaseModifiers(mods, r, typist: clickTiming) }
                throw Cancelled()
            }
            Input.newClickGroup()
            Input.mouse(down, pts[0], r, button: btn, flags: flags)
            pointer.click()
            var whole = await pointer.hold(clickTiming.clickHold(), r, button: button, flags: flags)
            if whole { whole = await pointer.stroke(pts, r, button: button, flags: flags) }
            if whole { whole = await pointer.hold(clickTiming.clickHold(), r, button: button, flags: flags) }
            if !whole {  // the client hung up partway: end the drag without dropping anything somewhere new
                await endDrag(r, from: pts[0], button: button)
                await Connection.ungated { await Input.releaseModifiers(mods, r, typist: clickTiming) }
                throw Cancelled()
            }
            Input.mouse(up, pts[pts.count - 1], r, button: btn, flags: flags)
            await Input.releaseModifiers(mods, r, typist: clickTiming)
            if let textStart {
                await AX.settleDragSelection(textStart, before: selectedBefore, pid: r.pid, wid: r.wid, end: pts[pts.count - 1])
            }
        case "scroll":
            var p: CGPoint
            if let (q, n) = try await actionPoint(a, t, required: false) {
                // Over what's shown of it: a text view's centre can be far below the window.
                let win: CGRect? = { if case .window(let w) = t { return Windows.info(w.id)?.frame ?? w.frame } else { return nil } }()
                p = n.flatMap { AX.shownPart($0.element, in: win) }.map { CGPoint(x: $0.midX, y: $0.midY) } ?? q
            } else if let until = a["until"], !(until is NSNull), case .window(let w) = t, let aim = untilAim(until, w) {
                // A scroll until aimed nowhere: the list or page that can hold its text, not what's under the middle.
                p = aim
            } else if case .window(let w) = t,
                meta[t.key] == nil || a["units"] as? String == "pt" {  // the middle of the window
                let f = Windows.info(w.id)?.frame ?? w.frame
                p = CGPoint(x: f.midX, y: f.midY)
            } else {
                // The middle of what the picture captured (whatever blank was left out of the picture itself).
                guard let c = captureCenter(t) else { throw HelperError("take a screenshot first") }
                p = c
            }
            let m = meta[t.key]
            let ptPerPx = a["units"] as? String == "pt" ? 1 : m.map { $0.size.width / Double($0.width) } ?? 1
            let r = try route(t, at: p, foreground: foreground)
            // Until a text shows: step by step, looking after each, only scrolling (see scrollUntil).
            if let until = a["until"], !(until is NSNull) {
                try await scrollUntil(a, until, at: p, r, ptPerPx: ptPerPx, t)
                return
            }
            let (dx, dy) = scrollDelta(a)  // (a batch's own scroll of 0 px was refused before it ran: `invalid`)
            await pointer.move(to: p, r)
            // A scroll that runs into the end stops there (see ScrollWatch), and says which end. One that doesn't
            // says where it left the scroll bar, where there's one to ask (the reply's scroll; the batch's last
            // scroll's).
            let watch = ScrollWatch(pid: r.pid, at: p, within: r.frame, dx: dx * ptPerPx, dy: dy * ptPerPx)
            let sent = await Input.scroll(p, dx: dx * ptPerPx, dy: dy * ptPerPx, r, watch: watch)
            if watch.stopped {
                let (asked, went) = watch.vertical ? (abs(dy), abs(sent.y) / ptPerPx) : (abs(dx), abs(sent.x) / ptPerPx)
                notes.append("the scroll reached \(ScrollWatch.end(vertical: watch.vertical, forward: watch.forward)) after "
                    + "about \(Int(went.rounded())) of \(Int(asked.rounded())); the rest wasn't sent")
                Session.current.scrolled = nil
            } else {
                Session.current.scrolled = watch.place()
            }
        case "type", "type_text":
            guard let text = a["text"] as? String ?? a["value"] as? String else { throw HelperError("type needs text") }
            if a["element"] != nil || a["target"] != nil || a["x"] != nil || a["coordinate"] != nil || a["clear"] != nil
                || a["submit"] != nil {
                try await typeInto(a, text, run)
                return
            }
            let r = try route(t, at: nil, foreground: foreground)
            try await ensureKeyboard(r, run: run, action: "type")
            if foreground { prepareForeground(r) }
            // Into the focused field: read back afterwards as for a field named (a key lost, an autocomplete
            // that took over, typing that went elsewhere), never a password field.
            let field = focusedField(r, for: text)
            let expected = VerifyEdit.expectation(field, typed: text)  // when the act checks its edits
            // A Return typed into a page's one-line field sends its form: the batch waits for the page it goes to.
            if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }), let mark = pageMark(keys: [["return"]], r, run) {
                run.pageMark = mark
            }
            try await typeText(text, r)
            if let field {
                let shows = try await readBack(field, text, whole: false, r)
                VerifyEdit.typed(field, expected: expected, shows: shows)
            }
        case "keypress", "key", "press_key", "hotkey":
            let seq = Keys.sequence(a["keys"] ?? a["key"] ?? a["text"])
            guard !seq.isEmpty else {
                throw HelperError("keypress needs keys: \"cmd+t\", [\"ctrl\",\"a\"], or a sequence like \"Tab Tab Return\"")
            }
            let times = int(a["repeat"] ?? a["times"], 1)
            guard (1...100).contains(times) else { throw HelperError("repeat is 1-100") }
            let r = try route(t, at: nil, foreground: foreground)
            // Shortcuts are judged up front, wherever the focus is; the rest just before each key goes out,
            // as a Tab or Return before it may have moved the focus.
            let held = run.heldKeys.map(\.name)
            try Policy.checkShortcuts(a, seq.map { held + $0 }, r.pid)
            try await ensureKeyboard(r, run: run, action: "keypress")
            if foreground { prepareForeground(r) }
            // Return in a page's field (a form sent), or on a link there: the batch waits for the page it goes to.
            if held.isEmpty, let mark = pageMark(keys: seq, r, run) { run.pageMark = mark }
            var pressed = 0
            for _ in 0..<times {
                for combo in seq {
                    try checkKey(held + combo, r, after: pressed)
                    if pressed > 0 { await Input.sleep(typist.between()) }
                    try await press(combo, r)
                    pressed += 1
                }
            }
        case "key_down", "keydown", "key_up", "keyup", "hold_key", "hold":
            let keys = Keys.splitCombo(a["keys"] ?? a["key"] ?? a["text"])
            let r = try route(t, at: nil, foreground: foreground)
            if type.hasPrefix("key_up") || type == "keyup" {
                if foreground { prepareForeground(r) }
                let names = keys.isEmpty ? run.heldKeys.map(\.name) : keys
                for (i, k) in names.reversed().enumerated() {
                    if i > 0 { await Input.sleep(typist.modifierTrail()) }
                    try run.keyUp(k, r)
                }
                return
            }
            guard !keys.isEmpty else { throw HelperError("\(type) needs keys, e.g. \"shift\" or \"cmd+option\"") }
            let seconds = num(a["ms"]).map { $0 / 1000 } ?? num(a["duration"] ?? a["seconds"]) ?? 1
            if type.hasPrefix("hold"), !(0...10).contains(seconds) {
                throw HelperError("hold_key holds for at most 10 s (ms 0-10000)")
            }
            for k in keys {
                if Keys.modifiers[Keys.normalize(k)] == nil { _ = try Keys.parseCombo([k]) }
            }
            // What they do with the keys already held: a shortcut, Return or Space on a button, a character.
            let combo = run.heldKeys.map(\.name) + keys
            try Policy.checkShortcuts(a, [combo], r.pid)
            try await ensureKeyboard(r, run: run, action: type)  // a held key would be pressed in whichever window has the keyboard
            if foreground { prepareForeground(r) }
            try checkKey(combo, r, after: 0)
            await primeKeys(r)
            for (i, k) in keys.enumerated() {
                if i > 0 { await Input.sleep(typist.modifierLead()) }
                try run.keyDown(k, r)
            }
            if type.hasPrefix("hold") {
                try await Run.pause(seconds)
                for (i, k) in keys.reversed().enumerated() {
                    if i > 0 { await Input.sleep(typist.modifierTrail()) }
                    try run.keyUp(k, r)
                }
            }
        case "menu", "menu_item":
            guard let pid = pid(t) else { throw HelperError("menu needs a window target") }
            // A menu command acts on the app's focused window (Paste, Select All, Undo, …): not another one.
            let menuRoute = try route(t, at: nil, foreground: foreground)
            let path = AX.menuPath(a["item"] ?? a["path"] ?? a["text"])
            // Look up the item and run Policy.checkItem before prompting or priming, and before kAXEnabledAttribute
            // (so the wrong window's disabled state doesn't hide a command that's enabled in our window).
            let (chosen, shortcut): (String, String?)
            do {
                (chosen, shortcut) = try AX.pressMenu(pid: pid, path: path, check: { try Policy.checkItem(a, $0) }, beforePress: {
                    if !keysReachTarget(menuRoute) || switchedIn(menuRoute) != nil || userAtKeys(menuRoute) {
                        throw PromptFirst()
                    }
                    if keysNeedPrimer(menuRoute) { throw PrimeFirst() }
                })
            } catch is PromptFirst {
                try await ensureKeyboard(menuRoute, run: run, action: "menu")
                if keysNeedPrimer(menuRoute) { await primeKeys(menuRoute) }
                (chosen, shortcut) = try AX.pressMenu(pid: pid, path: path, check: { try Policy.checkItem(a, $0) }, beforePress: {
                    try guardKeyboard(menuRoute)
                })
            } catch is PrimeFirst {
                await primeKeys(menuRoute)
                (chosen, shortcut) = try AX.pressMenu(pid: pid, path: path, check: { try Policy.checkItem(a, $0) }, beforePress: {
                    try guardKeyboard(menuRoute)
                })
            }
            run.ranMenu = path.count == 1 ? chosen : nil  // a macro saves the path a name alone ran (`Macros.ran`)
            if let shortcut {
                // A background app's menus are only brought up to date when opened, so "disabled" may be
                // stale; its shortcut is checked by the app as it's pressed.
                try await press(Keys.splitCombo(shortcut), menuRoute)
                notes.append("\(chosen) looked disabled in its menu (which may be out of date): pressed its shortcut \(shortcut)")
            } else if AX.menuKey(chosen) != AX.menuKey(path.joined(separator: " > ")) {
                notes.append("menu \(chosen)")
            }
        case "fill":
            try await fill(a, run)
        case "select", "choose":
            try await select(a, run)
        case "navigate", "goto", "go_to":
            try await navigate(a, run)
        case "open", "open_url", "launch":
            if let app = openApp(a) { try checkLaunch(app, a) }  // the app it starts or uses, before it does
            try await open(a, run)
        case "wait_for", "waitfor":
            try await waitFor(a, run)
        case "clipboard":
            if let text = a["text"] as? String {
                try Connection.check()
                Clipboard.set(text)
                notes.append("clipboard set (\(text.count) characters; what was there is replaced)")
            } else {
                let (text, note) = Clipboard.read(a)  // offset (below 0: from the end), limit, query
                run.clipboard = text
                if let note { notes.append(note) }
            }
        case "read":  // text, for the reply's reads (ReadText.swift)
            Session.current.reads.append(try await readStep(a, t))
        case "paste":
            guard let text = a["text"] as? String, !text.isEmpty else { throw HelperError("paste needs text") }
            let r = try route(t, at: nil, foreground: foreground)
            try await ensureKeyboard(r, run: run, action: "paste")
            try Policy.checkSecureFocus(r.pid)
            if foreground { prepareForeground(r) }
            try Connection.check()
            Clipboard.borrow(text)
            do { try await press(["cmd", "v"], r) } catch {
                Clipboard.giveBack()
                throw error
            }
            Clipboard.giveBack()
        case "set_value":
            guard let n = try await elementNode(a, t) else { throw HelperError("set_value needs element or target") }
            if Policy.isSecure(n.element), !Policy.config.allowSecureFields { throw Policy.secureRefusal() }
            let text = a["value"] as? String ?? a["text"] as? String ?? ""
            let shown = try await reveal(n, aimName(a))  // scrolled to first if it's out of view, as for every action
            if let c = shown.map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? AX.center(n) {
                await pointer.move(to: c, try route(t, at: c, foreground: false))
            }
            if !AX.setValue(n, text) { throw HelperError("the \(n.name) did not accept a value") }
            VerifyEdit.valueSet(n, text)  // when the act checks its edits
        case "focus":
            guard let n = try await elementNode(a, t) else { throw HelperError("focus needs element or target") }
            _ = try await reveal(n, aimName(a))
            if !AX.focus(n) { throw HelperError("the \(n.name) can't take focus") }
        case "ax", "secondary", "perform":
            guard let n = try await elementNode(a, t) else { throw HelperError("\(type) needs element or target") }
            let name = a["name"] as? String ?? a["ax_action"] as? String ?? "press"
            let idx = num(a["element"]) ?? 0
            if ["press", "axpress", "confirm", "axconfirm", "pick", "axpick"].contains(name.lowercased()), let pid = pid(t) {
                try Policy.checkPress(a, node: n, at: nil, pid: pid)
                // A link followed or a form sent by the press: the batch waits for the page it goes to.
                if run.pageMark == nil, let mark = pageMark(at: n.element, run) { run.pageMark = mark }
            }
            let shown = try await reveal(n, aimName(a))
            if shown != nil, ["scrolltovisible", "scrollto", "scrollintoview", "reveal"].contains(name.lowercased().filter(\.isLetter)) {
                return  // what it asked for is done (AppKit's controls don't take the action itself)
            }
            if let c = shown.map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? AX.center(n) {
                await pointer.move(to: c, try route(t, at: c, foreground: false))
            }
            if AX.perform(n, name) {
                pointer.click()
            } else {
                let supported = AX.actionNames(n).map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
                throw HelperError("\(idx > 0 ? "element \(Int(idx))" : "the \(n.name)") doesn't support \(name)"
                    + (supported.isEmpty ? "" : " (supports: \(supported.joined(separator: ", ")))"))
            }
        case "wait", "sleep":
            let given = a["ms"] ?? a["seconds"] ?? a["duration"]
            let ms = num(a["ms"]) ?? num(a["seconds"] ?? a["duration"]).map { $0 * 1000 } ?? (given == nil ? 1000 : -1)
            guard ms >= 0, ms <= 30000 else { throw HelperError("wait takes ms, a number from 0 to 30000") }
            if let (button, r, _) = run.heldButton {  // a hand holding a button down never quite stops
                if !(await pointer.hold(ms / 1000, r, button: button)) { throw Cancelled() }
            } else {
                try await Run.pause(ms / 1000)
            }
        case "activate", "raise", "focus_window":
            guard case .window(let w) = t else { return }
            // Keys after it go to the app's key window: check it's this one (when the app says), and try
            // again twice before saying it isn't.
            if let key = try await raiseToKey(w, pause: 0.25, wait: Run.pause) {
                throw HelperError("\(w.app) didn't bring window #\(w.id) forward: its keyboard is still in #\(key), so "
                    + "keys would go there. Look at the screen before going on")
            }
        case "close_window", "close":
            guard case .window(let w) = t else { throw HelperError("close_window needs a window target") }
            // One of the agent's windows may hold the user's pages too: the user is asked first.
            if a["confirm"] as? Bool != true, owner(w.id) != .user || Session.current.given.contains(w.id),
               let why = closeRefusal(wid: w.id, given: Session.current.given.contains(w.id),
                                      tabsThen: Session.current.owned[w.id]?.tabs, tabsNow: tabCount(w)) {
                throw HelperError(why)
            }
            if !AX.closeWindow(pid: w.pid, wid: w.id) { throw HelperError("window has no close button") }
            // Gone at once or in a moment; still there after 0.3 s, it's asking something.
            let gone = try await Run.pollUntil(floor: 0, every: 0.05, cap: 0.3) { Windows.info(w.id)?.onScreen != true }
            if !gone {
                notes.append("the window is still open: the app may be asking something, or keeps it (a sheet may have opened)")
            }
        case "screenshot":
            return
        default:
            throw HelperError("unknown action type \"\(type)\"")
        }
    }

    /// The policy's checks on one key that depend on where the focus is when it goes out: Return on a
    /// default button or Space on a focused one that needs the user's OK, or a character into a password
    /// field. `after` keys of the same action have gone out already: a stop then says so.
    static func checkKey(_ combo: [String], _ r: Route, after: Int) throws {
        do {
            try Policy.checkFocusKeys(Policy.running ?? [:], [combo], r)
        } catch let ok as Policy.NeedsOK where after > 0 {
            throw HelperError("stopped before \(combo.joined(separator: "+")): \(ok); the \(after) key"
                + (after == 1 ? "" : "s") + " before it went out. Ask the user; if they agree, press the rest with "
                + "\"confirm\": true")
        }
        if Policy.typesText(combo) { try Policy.checkSecureFocus(r.pid) }
    }

    /// Whether keys sent for `r` reach the window they're meant for. Key events follow the app's key window
    /// (their window stamp doesn't change that), so when the user has another window of the same app in
    /// front, typing would land in theirs.
    static func keysReachTarget(_ r: Route) -> Bool {
        guard !r.foreground, r.wid != 0 else { return true }  // foreground is the explicit, user-visible fallback
        if let key = AX.focusedWindow(pid: r.pid) { return key == r.wid }
        return !Hold.isFront(r.pid)  // can't tell which window has it: only safe while the user is in another app
    }

    /// Stop before keys that would land in a window the user is using rather than the agent's. Nothing is
    /// ever typed into the user's window: if their window has the keyboard, the action stops and says so. Nor
    /// into the agent's while the user may be typing there too (`waitsForUser`).
    static func guardKeyboard(_ r: Route) throws {
        if let p = switchedIn(r) { throw refused(r, keyboardRefusal(p)) }
        guard !keysReachTarget(r) else {
            if userAtKeys(r) {
                let busy = keyboardBusy(app: Policy.appName(r.pid), target: r.wid)
                throw refused(r, busy.text, retry: busy.retry)
            }
            return
        }
        let app = Policy.appName(r.pid)
        let key = AX.focusedWindow(pid: r.pid)
        if let key, owner(key) == .agent {
            let title = Windows.info(key)?.title ?? ""
            let what = title.isEmpty ? "window #\(key)" : "window #\(key) \"\(AX.clip(title, 40))\""
            // In the user's front app, it's moved at the start of a call (act), and only while they leave the
            // keyboard and mouse alone: they may be typing into that window.
            if Hold.isFront(r.pid) {
                if !Input.userQuiet() {
                    let retry = "Try again in a few seconds, or work in #\(key)"
                    throw refused(r, "your other \(what) has \(app)'s keyboard, and \(app) is the user's front app: "
                        + "they're using the keyboard or mouse, maybe typing there, so puter-use didn't move it. The "
                        + "action didn't run. \(retry)", retry: retry)
                }
                let retry = "Run it again in a new call (that moves it when it can), or click inside #\(r.wid) first; "
                    + "or work in #\(key)"
                throw refused(r, "your other \(what) has \(app)'s keyboard, and it wasn't moved to #\(r.wid): the "
                    + "action didn't run. \(retry)", retry: retry)
            }
            throw refused(r, "your other \(what) has \(app)'s keyboard, and it couldn't be moved to #\(r.wid): the "
                + "action didn't run. Work in #\(key), or close it if you're done with it")
        }
        throw refused(r, keyboardRefusal(elsewhere(r, key: key)), retry: keyboardRetry(app: app, target: r.wid))
    }

    /// When `r` routed a pointer action to a popover/menu over window `t` (`!r.primer || r.wid != w.id`),
    /// return the main window route for keyboard checks and prompts so `FocusPrompt` never targets a transient popup.
    static func mainRoute(_ t: Target, _ r: Route) -> Route {
        if case .window(let w) = t, !r.primer || r.wid != w.id {
            return Route(pid: w.pid, wid: w.id, frame: Windows.info(w.id)?.frame ?? w.frame, foreground: r.foreground)
        }
        return r
    }

    /// CG top-left frame of the user's active front window, used to pick the display for `FocusPrompt`.
    static func activeWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != Windows.ownPID else { return nil }
        if let wid = keyWindow(pid, timeout: 0.05), let f = Windows.info(wid)?.frame { return f }
        return Windows.all(onScreenOnly: true).first { $0.pid == pid && $0.layer == 0 }?.frame
    }

    /// Whether the session holds an active, unrevoked `FocusGrant` for `pid` (and `wid`, when given).
    static func validFocusGrant(pid: pid_t, wid: CGWindowID?) -> Bool {
        guard let g = Session.current.focusGrant else { return false }
        return g.isValid(pid: pid, wid: wid, now: ProcessInfo.processInfo.systemUptime,
                         presses: Input.userPresses(), sinceExtra: Run.sinceUser(FocusGrant.extraRevokers))
    }

    /// Whether rebasing `Session.current.baseline` across a focus change is safe: never absorb a covered/frozen
    /// window redraw or a title change into the baseline signature.
    static func safeToFlipBaseline(_ w: WinInfo) -> Bool {
        guard Session.current.baseline?.wid == w.id else { return false }
        let m = meta[w.id]
        guard m?.frozen == nil else { return false }
        guard coverOf(w).cover == .inView else { return false }
        if let seenTitle = m?.title, let nowTitle = Windows.info(w.id)?.title, nowTitle != seenTitle { return false }
        return true
    }

    /// Move a background app's keyboard to the agent's own window `w` from `from` via a primer click, preserving
    /// `Session.current.keyMove` (when moving off a user/shared window), wrapping in `baseline.flip` when safe,
    /// and appending the note on success.
    @discardableResult
    static func moveKeyboardInBackground(_ w: WinInfo, from: CGWindowID, flip: Bool = true) async throws -> Bool {
        guard !Hold.isFront(w.pid), owner(w.id) == .agent else { return false }
        let fromAgent = owner(from) == .agent
        let move: () async throws -> Void = {
            if Hold.held[w.pid] != w.id {
                _ = Hold.activate(pid: w.pid, wid: w.id)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
            if !fromAgent { Session.current.keyMove = KeyMove(pid: w.pid, wid: w.id, from: from) }
            await Input.primer(try route(.window(w), at: nil, foreground: false), force: true)
            await Input.afterPrimer()
            try await Run.pause(0.1)
        }
        if flip, let base = Session.current.baseline, safeToFlipBaseline(w) {
            try await base.flip(move)
        } else {
            try await move()
        }
        guard AX.focusedWindow(pid: w.pid) == w.id else { return false }
        if !fromAgent { Session.current.keyMove?.took = true }
        let app = Policy.appName(w.pid)
        if fromAgent {
            notes.append("moved \(app)'s keyboard here from your other window #\(from)")
        } else {
            notes.append("moved \(app)'s keyboard to your window #\(w.id) from "
                + (owner(from) == .shared ? "your #\(from), which the user has used" : "the user's #\(from)")
                + "; it'll be in front when they next switch to \(app)")
        }
        return true
    }

    /// Activate `w` as its frontmost app's key window after the user clicked Approve on `FocusPrompt`, issuing a
    /// `FocusGrant` if no new user key/click arrived during `raiseToKey`. Returns the window that kept focus if
    /// raising failed (e.g. a modal sheet on another window), or nil on success.
    static func activateApprovedFront(_ w: WinInfo, presses: Fronts.Presses, at: TimeInterval,
                                      allowBaselineFlip: Bool, run: Run? = nil) async -> CGWindowID? {
        var other: CGWindowID?
        let raise: () async -> Void = {
            SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
            if let win = AX.window(pid: w.pid, wid: w.id) { AX.write(win, kAXMainAttribute, kCFBooleanTrue) }
            other = try? await raiseToKey(w, pause: 0.08, wait: Run.pause)
        }
        if allowBaselineFlip, let base = Session.current.baseline, safeToFlipBaseline(w) {
            await base.flip(raise)
            if !base.typed, let run, run.changeBase?.wid == w.id, let sig = try? await changeLook(.window(w)) {
                run.changeBase = (wid: w.id, sig: sig)
            }
        } else {
            await raise()
        }
        guard !Connection.hungUp else { return other }
        guard other == nil else { return other }
        Fronts.watch()
        if Input.userPresses() == presses {
            Session.current.focusGrant = FocusGrant(pid: w.pid, wid: w.id, presses: presses, grantedAt: at)
        }
        if Session.current.owned[w.id] != nil {
            Session.current.owned[w.id]?.since = ProcessInfo.processInfo.systemUptime
            Session.current.owned[w.id]?.input = Input.userPresses()
        }
        Session.current.keyMove = nil
        Session.current.refusals[w.id] = nil
        return nil
    }

    /// Switch `w` to be its background app's key window after the user clicked Approve while in another app
    /// (`back`), flashing briefly and returning focus to `back` before restoring the AppKit hold.
    static func activateApprovedBackground(_ w: WinInfo, back: NSRunningApplication,
                                           presses: Fronts.Presses, at: TimeInterval) async throws {
        Hold.flashing[w.pid] = .infinity
        SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
        if let win = AX.window(pid: w.pid, wid: w.id) { AX.write(win, kAXMainAttribute, kCFBooleanTrue) }
        let other = try? await raiseToKey(w, pause: 0.08) { await Input.sleep($0) }
        if !Hold.isFront(w.pid) {
            AX.write(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute, kCFBooleanTrue)
            _ = await cameForward(w.pid, within: 0.2)
        }
        if back.processIdentifier != Windows.ownPID { _ = await giveBack(back) }
        Hold.flashing[w.pid] = ProcessInfo.processInfo.systemUptime + 0.35
        if !Hold.isFront(w.pid) {
            if Hold.held[w.pid] == w.id {
                Hold.restore(w.pid)
            } else {
                _ = Hold.activate(pid: w.pid, wid: w.id)
                Hold.fresh.insert(w.pid)
            }
        } else {
            Fronts.watch()
            if Input.userPresses() == presses {
                Session.current.focusGrant = FocusGrant(pid: w.pid, wid: w.id, presses: presses, grantedAt: at)
            }
            if Session.current.owned[w.id] != nil {
                Session.current.owned[w.id]?.since = ProcessInfo.processInfo.systemUptime
                Session.current.owned[w.id]?.input = Input.userPresses()
            }
        }
        if let other {
            throw HelperError("\(AgentBrowser.label(w)) didn't switch its keyboard to #\(w.id) (still on #\(other)), so the action didn't run")
        }
        guard AX.focusedWindow(pid: w.pid) == w.id else {
            throw HelperError("\(AgentBrowser.label(w))'s keyboard didn't stay on #\(w.id), so the action didn't run")
        }
        Session.current.keyMove = nil
        Session.current.refusals[w.id] = nil
    }

    /// Top-level pre-check for keyboard, menu, and modifier actions: fast-passes when `r` already safely owns its
    /// app's keyboard, attempts silent background recovery for the agent's own window when applicable, and
    /// otherwise asks the user via `FocusPrompt` when eligible before falling back to `guardKeyboard`.
    static func ensureKeyboard(_ r: Route, run: Run? = nil, action: String? = nil) async throws {
        try Connection.check()
        if keysReachTarget(r) && switchedIn(r) == nil && !userAtKeys(r) { return }

        func classify() -> (trigger: FocusPrompt.Trigger?, key: CGWindowID?) {
            if switchedIn(r) != nil { return (.switchedIn, AX.focusedWindow(pid: r.pid)) }
            if !keysReachTarget(r) { return (.otherWindow, AX.focusedWindow(pid: r.pid)) }
            return (nil, nil)  // keysReachTarget && userAtKeys -> keyboardBusy: never prompt
        }

        func trySilentBackgroundMove(trigger: FocusPrompt.Trigger?, key: CGWindowID?) async throws -> Bool {
            guard trigger == .otherWindow, !r.foreground, r.wid != 0, !Hold.isFront(r.pid),
                  owner(r.wid) == .agent, let key, key != r.wid, let w = Windows.info(r.wid) else { return false }
            if owner(key) != .agent, Session.current.keyMove?.wid == r.wid { return false }
            _ = try await moveKeyboardInBackground(w, from: key)
            return keysReachTarget(r) && switchedIn(r) == nil && !userAtKeys(r)
        }

        func hasHeldInput() -> Bool {
            !Input.held.isEmpty || Run.active.values.contains {
                $0.session === Session.current && ($0.run.heldButton != nil || !$0.run.heldKeys.isEmpty)
            }
        }

        var (trigger, key) = classify()
        if try await trySilentBackgroundMove(trigger: trigger, key: key) { return }
        (trigger, key) = classify()

        func checkEligible(_ trig: FocusPrompt.Trigger?) -> (ok: Bool, cooldown: FocusPrompt.CooldownReason?, win: WinInfo?) {
            let win = Windows.info(r.wid)
            let held = hasHeldInput()
            let cooldown = FocusPrompt.activeCooldown(pid: r.pid)
            let ok = FocusPrompt.shouldPromptKeyboard(
                enabled: Connection.current?.focusPrompt ?? false,
                quitting: Connection.quitting, foreground: r.foreground, wid: r.wid,
                screenLocked: Windows.screenLocked, onScreen: win?.onScreen == true,
                heldInput: held, inCooldown: cooldown != nil, trigger: trig
            )
            if !ok, let reason = cooldown,
               FocusPrompt.shouldPromptKeyboard(enabled: Connection.current?.focusPrompt ?? false,
                                                quitting: Connection.quitting, foreground: r.foreground, wid: r.wid,
                                                screenLocked: Windows.screenLocked, onScreen: win?.onScreen == true,
                                                heldInput: held, inCooldown: false, trigger: trig) {
                return (false, reason, win)
            }
            return (ok, nil, win)
        }

        let initial = checkEligible(trigger)
        if !initial.ok {
            if let reason = initial.cooldown {
                let app = initial.win.map { AgentBrowser.label($0) } ?? Policy.appName(r.pid)
                throw HelperError(FocusPrompt.cooldownKeyboardError(app: app, wid: r.wid, reason: reason))
            }
            try guardKeyboard(r)
            return
        }

        do { try await FocusPrompt.acquireGate() } catch {
            Connection.current?.work.promptCancelled = true
            throw Cancelled()
        }
        defer { FocusPrompt.releaseGate() }

        if Connection.hungUp || Connection.quitting {
            Connection.current?.work.promptCancelled = true
            throw Cancelled()
        }
        if keysReachTarget(r) && switchedIn(r) == nil && !userAtKeys(r) { return }

        (trigger, key) = classify()
        if try await trySilentBackgroundMove(trigger: trigger, key: key) { return }
        (trigger, key) = classify()

        let again = checkEligible(trigger)
        if !again.ok {
            if let reason = again.cooldown {
                let app = again.win.map { AgentBrowser.label($0) } ?? Policy.appName(r.pid)
                throw HelperError(FocusPrompt.cooldownKeyboardError(app: app, wid: r.wid, reason: reason))
            }
            try guardKeyboard(r)
            return
        }

        guard let targetWin = again.win, let trig = trigger else {
            try guardKeyboard(r)
            return
        }
        let front = Hold.isFront(r.pid)
        let keyInfo = key.flatMap { Windows.info($0) }
        let appLabel = AgentBrowser.label(targetWin)
        let targetOwner = owner(r.wid)
        let req = FocusPrompt.Request(
            pid: r.pid, wid: r.wid, app: appLabel, title: targetWin.title,
            targetOwner: targetOwner, keyWid: key, keyTitle: keyInfo?.title ?? "",
            keyOwner: key.map { owner($0) } ?? .user, trigger: trig, action: action ?? "",
            front: front, sessionOrdinal: Session.current.ordinal,
            anchorFrame: (front ? keyInfo?.frame : nil) ?? activeWindowFrame()
        )
        let outcome = await FocusPrompt.ask(req) {
            guard Windows.info(r.wid)?.onScreen == true,
                  NSRunningApplication(processIdentifier: r.pid)?.isTerminated == false else { return .windowGone }
            switch trig {
            case .switchedIn:
                if !Hold.isFront(r.pid) { return .clearedBackground }
                return nil
            case .otherWindow:
                if !Hold.isFront(r.pid) && owner(r.wid) == .agent { return .clearedBackground }
                if keyWindow(r.pid, timeout: 0.05) == r.wid { return .clearedFocused }
                return nil
            case .frozen:
                return nil
            }
        }
        let keyDesc: String? = trig == .switchedIn ? nil : key.map { k in
            let kt = FocusPrompt.sanitizeTitle(keyInfo?.title ?? "", limit: 40)
            return kt.isEmpty ? "#\(k)" : "#\(k) \"\(kt)\""
        }
        switch outcome {
        case .approved(let presses, let at):
            FocusPrompt.clearCooldown(pid: r.pid)
            if Connection.hungUp || Connection.quitting {
                Connection.current?.work.promptCancelled = true
                throw Cancelled()
            }
            guard let fresh = Windows.info(r.wid), fresh.onScreen else {
                throw HelperError("window #\(r.wid) is no longer on screen")
            }
            let liveFront = Hold.isFront(r.pid)
            let back = NSWorkspace.shared.frontmostApplication
            if liveFront || back == nil || back?.processIdentifier == Windows.ownPID {
                if let other = await activateApprovedFront(fresh, presses: presses, at: at, allowBaselineFlip: true, run: run) {
                    throw HelperError("\(appLabel) didn't switch its keyboard to #\(r.wid) (still on #\(other)), so the action didn't run")
                }
                if Connection.hungUp || Connection.quitting {
                    Connection.current?.work.promptCancelled = true
                    throw Cancelled()
                }
                let verb = trig == .switchedIn ? "allowed continuing in" : "approved switching \(appLabel) to"
                Connection.current?.ownerNotes.append("the user \(verb) #\(r.wid)")
            } else {
                try await activateApprovedBackground(fresh, back: back!, presses: presses, at: at)
                Connection.current?.ownerNotes.append("the user approved switching \(appLabel) to #\(r.wid) in the background")
            }
            try guardKeyboard(r)
        case .declined:
            FocusPrompt.recordDecline(pid: r.pid)
            throw HelperError(FocusPrompt.declinedKeyboardError(app: appLabel, wid: r.wid, title: targetWin.title,
                                                                targetOwner: targetOwner, keyDesc: keyDesc))
        case .timedOut:
            FocusPrompt.recordTimeout(pid: r.pid)
            throw HelperError(FocusPrompt.timedOutKeyboardError(app: appLabel, wid: r.wid, title: targetWin.title,
                                                                targetOwner: targetOwner, keyDesc: keyDesc,
                                                                seconds: Int(FocusPrompt.timeout.rounded())))
        case .clearedBackground:
            if trig == .otherWindow, !Hold.isFront(r.pid), let fresh = Windows.info(r.wid),
               let keyNow = AX.focusedWindow(pid: r.pid), keyNow != r.wid, owner(r.wid) == .agent {
                _ = try await moveKeyboardInBackground(fresh, from: keyNow)
            }
            try guardKeyboard(r)
        case .clearedFocused, .windowGone, .unavailable, .clearedInView:
            try guardKeyboard(r)
        case .cancelled:
            Connection.current?.work.promptCancelled = true
            throw Cancelled()
        }
    }

    /// Whether keys for `r`, whose window has its app's keyboard, wait for the user (`waitsForUser`), as things are now.
    /// An active `FocusGrant` (from clicking Approve on `FocusPrompt`) lets keys through despite post-click mouse drift;
    /// any real user input immediately marks it revoked and pauses keys until the user is quiet again (including on `.user` windows).
    static func userAtKeys(_ r: Route) -> Bool {
        guard r.wid != 0, !r.foreground else { return false }
        if var g = Session.current.focusGrant, g.matches(pid: r.pid, wid: r.wid) {
            if g.isValid(pid: r.pid, wid: r.wid, now: ProcessInfo.processInfo.systemUptime,
                         presses: Input.userPresses(), sinceExtra: Run.sinceUser(FocusGrant.extraRevokers)) {
                return false
            }
            if !g.revoked {
                g.revoked = true
                Session.current.focusGrant = g
            }
            if !Input.userQuiet() { return true }
            Session.current.focusGrant = nil
        }
        return waitsForUser(foreground: r.foreground, front: Hold.isFront(r.pid), targetOwner: owner(r.wid),
                            quiet: Input.userQuiet())
    }

    /// Whether keys going to one of the agent's windows that has its app's keyboard (`targetOwner` not the user's)
    /// wait for the user: the app is their front app (`front`), so that window is the one they're in, and they've
    /// touched the keyboard or mouse in the last moments (`quiet` false), so they may be typing there too. Asked before
    /// each key, so typing stops when they come in. Not in foreground mode, where the real keyboard is used with the
    /// user's OK.
    nonisolated static func waitsForUser(foreground: Bool, front: Bool, targetOwner: Owner, quiet: Bool) -> Bool {
        !foreground && front && targetOwner != .user && !quiet
    }

    /// Why keys stop when the user may be typing in the agent's window `target` (`waitsForUser`), with the part that
    /// says to try again (`retry`, for `refused`).
    nonisolated static func keyboardBusy(app: String, target: CGWindowID) -> (text: String, retry: String) {
        let retry = "Try again once they've left the keyboard for a moment"
        return ("the user is in \(app) and its keyboard is on your window #\(target): they may be typing there, so the "
            + "action didn't run. \(retry)", retry)
    }

    /// What a refusal of keys for the agent's own window says to try again, when the keyboard hasn't been moved there
    /// yet this act (`keyboardElsewhere`).
    nonisolated static func keyboardRetry(app: String, target: CGWindowID) -> String {
        "Run it again in a new call: that moves the keyboard to #\(target) while \(app) is in the background"
    }

    /// What keys stopped for a window of the user's say, as one error (`keyboardElsewhere`'s parts).
    nonisolated static func keyboardRefusal(_ p: (why: String, effect: String, advice: String)) -> String {
        "\(p.why), so the action didn't run: \(p.effect). \(p.advice)"
    }

    /// Why keys stop when a window of the user's (`key`, titled `keyTitle`; `keyOwner` `.shared` for one of the
    /// agent's they've used; nil when the app can't say which) has `app`'s keyboard rather than `target`, the window
    /// the action is for (named with whose it is, `targetOwner`, never called the agent's unless it is), in parts:
    /// the cause (`why`), what keys would do (`effect`) and what to do about it (`advice`). In the user's front app
    /// (`front`) it clears when they leave it. In the background it never moves by itself, so retrying is no use,
    /// unless the agent's own window hasn't been tried yet this act (`tried`: a new call moves the keyboard there,
    /// `keyPrimer`). Never take it from the user. Clicks without keys aren't held up.
    nonisolated static func keyboardElsewhere(app: String, target: CGWindowID, targetOwner: Owner, key: CGWindowID?,
                                              keyTitle: String = "", keyOwner: Owner = .user, front: Bool, tried: Bool = true)
        -> (why: String, effect: String, advice: String) {
        let aim = "#\(target), the window this action is for (\(whose(targetOwner)))"
        let clicks = "Clicks without keys still reach #\(target)"
        let title = keyTitle.isEmpty ? "" : " \"\(AX.clip(keyTitle, 40))\""
        func named(_ theirs: String) -> String? {
            key.map { k in keyOwner == .shared ? "your window #\(k)\(title), which the user has used," : "\(theirs) #\(k)\(title)" }
        }
        if front {
            return (named("their window").map { "the user is in \(app) (\($0) has the keyboard)" }
                        ?? "the user is in \(app), and which of its windows has the keyboard can't be told",
                    "keys and menu commands would act there, not in \(aim)",
                    "This clears when they leave \(app); or ask them. Don't take the keyboard from them (no foreground, "
                        + "activate or a click just to move it). \(clicks)")
        }
        let on = named("the user's window").map { $0.hasSuffix(",") ? $0 : $0 + "," } ?? "another window,"
        return ("\(app)'s keyboard is on \(on) and it won't move by itself",
                "keys and menu commands would act there, not in \(aim)",
                !tried && targetOwner == .agent
                    ? "\(keyboardRetry(app: app, target: target)). \(clicks)"
                    : "Don't retry: ask the user to click into #\(target). \(clicks)")
    }

    /// Why keys stop when the user switched to the app after the act moved its keyboard off their window (`from`,
    /// `KeyMove`): the agent's window came to the front with it, so their keys would go to `target` too.
    nonisolated static func keyboardSwitchedIn(app: String, target: CGWindowID, targetOwner: Owner = .agent,
                                               from: CGWindowID) -> (why: String, effect: String, advice: String) {
        ("the user switched to \(app) after its keyboard was moved off their #\(from)",
         "their keys would go to #\(target), the window this action is for (\(whose(targetOwner))), too",
         "This clears when they leave \(app); or ask them")
    }

    /// The user came into the app after the act under way moved its keyboard to the agent's window (`KeyMove`).
    static func switchedIn(_ r: Route) -> (why: String, effect: String, advice: String)? {
        guard let m = Session.current.keyMove, m.took, m.pid == r.pid, !r.foreground, Hold.isFront(r.pid) else { return nil }
        return keyboardSwitchedIn(app: Policy.appName(r.pid), target: r.wid, targetOwner: owner(r.wid), from: m.from)
    }

    /// `keyboardElsewhere` for keys going to `r` while `key` has the app's keyboard, as things are now.
    static func elsewhere(_ r: Route, key: CGWindowID?) -> (why: String, effect: String, advice: String) {
        let m = Session.current.keyMove
        return keyboardElsewhere(app: Policy.appName(r.pid), target: r.wid, targetOwner: owner(r.wid), key: key,
                                 keyTitle: key.flatMap { Windows.info($0)?.title } ?? "", keyOwner: key.map { owner($0) } ?? .user,
                                 front: Hold.isFront(r.pid), tried: m?.pid == r.pid && m?.wid == r.wid)
    }

    /// Refusals of keys for one window are counted over this long: the third says to stop retrying.
    nonisolated static let refusalSpan: TimeInterval = 180

    /// The times keys for a window were refused that still count at `now` (`refusalSpan`), with this one.
    nonisolated static func refusals(_ before: [TimeInterval], now: TimeInterval) -> [TimeInterval] {
        before.filter { now - $0 < refusalSpan } + [now]
    }

    /// What a refusal adds once keys for the window were refused `count` times lately: retrying won't help.
    nonisolated static func refusalNote(_ count: Int) -> String? {
        count >= 3 ? "Refused \(count) times in 3 minutes: stop retrying and ask the user" : nil
    }

    /// What a refusal (`text`) says once keys for its window were refused `count` times lately, this one too: from the
    /// third on, that retrying won't help (`refusalNote`), in place of the part of it that says to try again (`retry`,
    /// when it has one), so the two don't disagree.
    nonisolated static func refusalText(_ text: String, retry: String? = nil, count: Int) -> String {
        guard let note = refusalNote(count) else { return text }
        if let retry, !retry.isEmpty, let at = text.range(of: retry, options: .backwards) {
            return text.replacingCharacters(in: at, with: note)
        }
        return "\(text). \(note)"
    }

    /// The error for keys refused for `r`'s window (`text`, with the part that says to try again: `retry`), counted
    /// for the session.
    static func refused(_ r: Route, _ text: String, retry: String? = nil) -> HelperError {
        let times = refusals(Session.current.refusals[r.wid] ?? [], now: ProcessInfo.processInfo.systemUptime)
        Session.current.refusals[r.wid] = times
        return HelperError(refusalText(text, retry: retry, count: times.count))
    }

    /// Press a shortcut or key. Chromium ignores key equivalents while in the background, so there the
    /// matching menu item is pressed instead.
    static func press(_ keys: [String], _ r: Route) async throws {
        try Connection.check()
        try guardKeyboard(r)
        await primeKeys(r)
        if !r.foreground, Windows.isChromium(r.pid), NSRunningApplication(processIdentifier: r.pid)?.isActive != true,
           let title = AX.pressMenuShortcut(pid: r.pid, keys: keys) {
            notes.append("\(keys.joined(separator: "+")) → menu \"\(title)\"")
            return
        }
        try await Input.keyCombo(keys, r, typist: typist)
    }

    /// Text that's only a web address, as one is typed into an address bar, a final Return aside: with a scheme
    /// ("https://…", "about:…"), or localhost or an IP address, or a host name with a dot ("example.com/docs"), each
    /// with a port if any. Nothing with a space in it, nor an email address, nor a file's name ("index.html",
    /// "report.pdf": a host whose last part is a common file extension, unless it starts with "www.").
    nonisolated static func loneAddress(_ text: String) -> Bool {
        var t = Substring(text)
        while let last = t.last, last.isNewline { t = t.dropLast() }
        let s = t.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, s.count <= 2048, !s.contains(where: \.isWhitespace) else { return false }
        if s.hasPrefix("about:"), s.count > 6 { return true }
        if let r = s.range(of: "://"), r.upperBound < s.endIndex {
            let scheme = s[..<r.lowerBound]
            return scheme.first?.isLetter == true && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+.-".contains($0) }
        }
        let authority = s.prefix { !"/?#".contains($0) }
        let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isASCII) || !parts[1].allSatisfy(\.isNumber) { return false }
        let name = parts.first.map(String.init) ?? ""
        if name == "localhost" { return true }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ $0.count <= 3 && Int($0).map { (0...255).contains($0) } == true }) {
            return true
        }
        guard labels.count >= 2, let tld = labels.last, (2...24).contains(tld.count), tld.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return false }
        if fileExtensions.contains(String(tld)), labels.first != "www" { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.first != "-" && l.last != "-" && l.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }

    /// Common file extensions a typed web address's host rarely ends in (not those much used as domains too, as
    /// .app, .ai, .io and .sh are).
    nonisolated static let fileExtensions: Set<String> = [
        "html", "htm", "xhtml", "php", "asp", "aspx", "jsp", "pdf", "txt", "md", "rtf", "csv", "tsv", "json", "xml",
        "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "plist", "js", "mjs", "ts", "tsx", "jsx", "css", "scss", "swift",
        "py", "rb", "java", "kt", "cpp", "hpp", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "pages", "numbers",
        "key", "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tif", "tiff", "bmp", "ico", "mp3", "mp4", "m4a", "wav",
        "mov", "avi", "mkv", "zip", "gz", "tgz", "tar", "rar", "dmg", "pkg", "exe", "dll", "sql", "db", "sqlite",
    ]

    /// Whether a `type` action `a` would put a lone web address (`loneAddress`) into a browser's page: it names no
    /// field to type into, and the focus in its window isn't on a text input (`focusOnText` false; nil when the
    /// focus is in another window). Typed there, an address doesn't load. Not into a page's own field, which may
    /// rightly ask for one, nor for navigate's or fill's typing.
    nonisolated static func addressIntoPage(_ a: [String: Any], text: String, browser: Bool, focusOnText: Bool?) -> Bool {
        guard browser, focusOnText == false, ["type", "type_text"].contains(kind(a)) else { return false }
        guard a["element"] == nil, a["target"] == nil, a["x"] == nil, a["coordinate"] == nil else { return false }
        return loneAddress(text)
    }

    /// Type `text` like a person: up to `pasteOver` characters is typed; a longer stretch is pasted (as people
    /// do with long text), borrowing the clipboard and giving it back. Newlines and tabs are always the
    /// Return and Tab keys, so a "\n" still submits a field even between pasted paragraphs.
    ///
    /// A Tab moves the focus and a Return can open something, so what each stretch between them lands in
    /// is checked just before it goes out (a password field; a button that Space or Return would press).
    static func typeText(_ text: String, _ r: Route) async throws {
        // Typing with a key held down would mix the two (and type's own Shift would let go of a held one).
        if !Input.held.isEmpty {
            throw HelperError("keys are held down (key_down): key_up first, or press combinations with keypress")
        }
        // An address typed at the focus, in a browser whose focus is in the page: it would go into the page (or set
        // off its shortcuts), not load. A page's own text field takes it as typed (a form can ask for a URL).
        if let a = Policy.running, isBrowser(r.pid), loneAddress(text) {
            var onText: Bool?  // nil: the focus is in another window (guardKeyboard speaks to that)
            if let f = AX.focusedElement(pid: r.pid) {
                if AX.windowID(f).map({ $0 == r.wid }) ?? true { onText = AX.isTextInput(f) }
            } else if keysReachTarget(r) {
                onText = false
            }
            if addressIntoPage(a, text: text, browser: true, focusOnText: onText) {
                throw HelperError("the focus isn't in the address bar or a text field, so nothing was typed. To load an "
                    + "address, use navigate {url} (" + (agentWindows.contains(r.wid)
                        ? "in your window #\(r.wid) it loads there)" : "it opens a window of your own)"))
            }
        }
        // A browser's address bar holds one address: typing a new one replaces the old (cmd+l and a click
        // select it; when the caret was just left in it, select it here rather than add to it). Only in
        // the agent's own window: the app's focus may be the user's window.
        let focused = isBrowser(r.pid) ? AX.focusedElement(pid: r.pid) : nil
        let focusedHere = focused.map { f in
            r.wid == 0 || (AX.windowID(f).map { $0 == r.wid } ?? keysReachTarget(r))
        } ?? false
        // An address goes into the address bar at once (pasted, as people do with a link): typed, its
        // suggestions chase each letter, and it takes a while.
        let addressBar = focused.map { focusedHere && AX.isBrowserAddressBar($0, pid: r.pid) } ?? false
        if let f = focused, addressBar,
           let current = AX.value(f, kAXValueAttribute) as? String, !current.isEmpty,
           (AX.selectedRange(f)?.length ?? 0) == 0,
           !AX.select(f, CFRange(location: 0, length: (current as NSString).length)) {
            try await press(["cmd", "a"], r)  // accessibility didn't take it: its own select-all
            await Input.sleep(typist.between())
        }
        var stretches: [(text: String, end: Character?)] = []
        var run = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\r\n" || ch == "\t" {
                stretches.append((run, ch))
                run = ""
            } else {
                run.append(ch)
            }
        }
        if !run.isEmpty || stretches.isEmpty { stretches.append((run, nil)) }
        let a = Policy.running ?? [:]
        var sent = 0  // characters gone out
        // Before each key: the keys still reach the window, and the user hasn't come into its app since the act moved
        // its keyboard there, nor is busy in it with the agent's window in front of them (the checks a stretch starts
        // with, between its keys too: a stretch takes seconds).
        let stillSafe = { keysReachTarget(r) && switchedIn(r) == nil && !userAtKeys(r) }
        for (i, s) in stretches.enumerated() {
            do {
                if !s.text.isEmpty { try Policy.checkSecureFocus(r.pid) }
                if s.text.contains(" ") { try Policy.checkFocusKeys(a, [["space"]], r) }
                if let end = s.end, end != "\t" { try Policy.checkFocusKeys(a, [["return"]], r) }
            } catch let ok as Policy.NeedsOK where sent > 0 {
                throw HelperError("stopped partway through the text: \(ok); the first \(sent) characters were typed. "
                    + "Ask the user; if they agree, type the rest with \"confirm\": true")
            }
            try Connection.check()
            // The user may have taken the keyboard since the last stretch (a long text takes a while, and
            // its last key coming up isn't checked): then what went out is said, as when typing stops.
            do { try guardKeyboard(r) } catch where sent > 0 { throw typingInterrupted(sent, r) }
            await primeKeys(r)
            if i > 0 { await Input.sleep(typist.between()) }
            let end = s.end.map { String($0) } ?? ""
            let quick = addressBar && i == 0  // (a Return after it leaves the address bar)
            if pasteOver > 0, s.text.count > pasteOver || (quick && !s.text.isEmpty) {
                await Input.sleep(typist.instant || quick ? 0 : Double.random(in: 0.15...0.35))  // reach for the shortcut
                try Connection.check()
                Clipboard.borrow(s.text)
                do { try await press(["cmd", "v"], r) } catch {
                    Clipboard.giveBack()
                    throw error
                }
                Clipboard.giveBack()
                try Connection.check()
                Connection.current?.work.typed += s.text.count
                await Input.sleep(typist.instant || quick ? 0.03 : Double.random(in: 0.12...0.25))
                if !end.isEmpty,
                   !(await Input.type(end, r, typist: typist, stillSafe: stillSafe)) {
                    throw try interruption(sent, r)
                }
            } else if !(await Input.type(s.text + end, r, typist: typist, stillSafe: stillSafe)) {
                throw try interruption(sent, r)
            }
            sent += s.text.count + end.count
        }
    }

    /// Why typing stopped short: the client hanging up is a cancel, not the user taking the keyboard.
    private static func interruption(_ sent: Int, _ r: Route) throws -> HelperError {
        try Connection.check()
        return typingInterrupted(sent, r)
    }

    /// End a drag whose client hung up, without dropping what's dragged somewhere new. If the agent's
    /// window has the app's keyboard, Escape cancels the drag (in AppKit and browsers) and the button
    /// comes up where it is. Otherwise Escape would go to the user's window of that app (cancelling their
    /// rename, closing their sheet), so the pointer goes back to where the drag started and lets go there.
    static func endDrag(_ r: Route, from start: CGPoint, button: String) async {
        let (_, up, _, btn) = Input.buttonTypes(button)
        await Connection.ungated {
            if keysReachTarget(r), escapeIsOnlyTheDrags(r) {
                let esc = Keys.named["escape"] ?? 0x35
                Input.key(esc, down: true, flags: [], r, withHeld: false)
                await Input.ms(30)
                Input.key(esc, down: false, flags: [], r, withHeld: false)
                Input.mouse(up, pointer.tip ?? start, r, button: btn)
            } else {
                await pointer.move(to: start, r, button: button)
                Input.mouse(up, start, r, button: btn)
            }
        }
    }

    /// Whether Escape in `r`'s window would only end a drag: not in a sheet or dialog, or a window with a
    /// cancel button or a sheet open, where it would cancel that (discarding a form).
    static func escapeIsOnlyTheDrags(_ r: Route) -> Bool {
        guard let w = AX.window(pid: r.pid, wid: r.wid) else { return false }
        if AX.value(w, kAXSubroleAttribute) as? String != "AXStandardWindow" { return false }
        if AX.value(w, kAXCancelButtonAttribute) != nil { return false }
        return !AX.children(w).contains { AX.value($0, kAXRoleAttribute) as? String == "AXSheet" }
    }

    /// An action in a few words, for the note about a call whose result never reached the agent. Typed
    /// text is counted, not repeated.
    static func brief(_ a: [String: Any]) -> String {
        let k = kind(a)
        var aim = ""
        if let t = a["target"] {
            aim = " \"\(AX.clip((t as? [String: Any])?["text"] as? String ?? "\(t)", 30))\""
        } else if let e = num(a["element"]) {
            aim = " element \(Int(e))"
        } else if let x = num(a["x"]), let y = num(a["y"]) {
            aim = " at (\(Int(x)),\(Int(y)))"
        }
        switch k {
        case "type", "type_text", "paste":
            let n = (a["text"] as? String ?? a["value"] as? String ?? "").count
            return "\(k == "paste" ? "pasted" : "typed") \(n) character\(n == 1 ? "" : "s")" + (aim.isEmpty ? "" : " into\(aim)")
                + (a["submit"] as? Bool == true ? ", then Return" : "")
        case "keypress", "key", "press_key", "hotkey":
            return "pressed " + Keys.sequence(a["keys"] ?? a["key"] ?? a["text"]).map { $0.joined(separator: "+") }.joined(separator: " ")
        case "menu", "menu_item":
            return "menu " + AX.menuPath(a["item"] ?? a["path"] ?? a["text"]).joined(separator: " > ")
        case "fill":
            let count = (a["fields"] as? [Any])?.count ?? (a["fields"] as? [String: Any])?.count ?? 0
            return "filled \(count) fields" + (a["submit"] != nil ? " and submitted" : "")
        case "navigate", "goto", "go_to":
            return "went to " + AX.clip(a["url"] as? String ?? "", 60)
        default:
            return k + aim + (a["item"].map { " > \($0)" } ?? "")
        }
    }

    /// The action under way when the client gave up, and how far it got.
    static func partway(_ n: Int, _ a: [String: Any]) -> String {
        guard let w = Connection.current?.work else { return "action \(n) (\(kind(a))) was under way" }
        var bits: [String] = []
        if let f = w.fields { bits.append(f.done == 0 ? "none of its \(f.of) fields was done" : "fields 1-\(f.done) of \(f.of) were done") }
        bits += w.did
        if w.typed > 0 {
            let text = w.fields == nil ? a["text"] as? String ?? a["value"] as? String : nil
            let of = text.map { t in " of \(t.filter { !$0.isNewline && $0 != "\t" }.count)" } ?? ""
            bits.append("\(w.typed)\(of) characters had gone out" + (w.fields == nil ? "" : " in the next one"))
        }
        if bits.isEmpty { return "action \(n) (\(kind(a))) was under way: it may or may not have taken effect" }
        return "action \(n) (\(kind(a))) stopped partway: " + bits.joined(separator: ", ")
    }

    /// Windows of the batch's app that weren't there when it started.
    static func openedBy(_ run: Run) -> [CGWindowID] {
        Windows.all(onScreenOnly: true).filter {
            $0.pid == run.pidAtStart && $0.layer == 0 && !run.visibleBefore.contains($0.id)
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }.map(\.id)
    }

    /// Another window of the app took the keyboard partway through the text, or the user came in where it goes: why,
    /// as a refusal would say it, and what to do about the rest.
    private static func typingInterrupted(_ sent: Int, _ r: Route) -> HelperError {
        let sofar = sent == 0 ? "only part of it had gone out" : "the first \(sent) characters had gone out"
        let app = Policy.appName(r.pid)
        var why = "\(app)'s keyboard left #\(r.wid), the window this action is for (\(whose(owner(r.wid))))"
        var advice = "Look at the window before typing the rest"
        let reaches = keysReachTarget(r)
        if let p = switchedIn(r) {
            (why, advice) = (p.why, p.advice)
        } else if reaches, userAtKeys(r) {
            why = "the user is in \(app) and its keyboard is on your window #\(r.wid): they may be typing there"
            advice = "Type the rest once they've left the keyboard for a moment"
        } else if !reaches {
            let key = AX.focusedWindow(pid: r.pid)
            if let key, owner(key) == .agent {
                why = "your other window #\(key) took \(app)'s keyboard"
                advice = "Type the rest in a new call (that moves it back when it can), or work in #\(key)"
            } else {
                let p = elsewhere(r, key: key)
                (why, advice) = (p.why, p.advice)
            }
        }
        return HelperError("stopped partway through the text: \(why); \(sofar), and nothing more was typed. \(advice)")
    }

    /// Button holds are a hand's, whatever the typing speed; instant only when the pointer jumps (speed 0).
    static var clickTiming: Typist { Typist(wpm: pointer.speed <= 0 ? 0 : 140) }

    static func prepareForeground(_ r: Route) {
        AX.raise(pid: r.pid, wid: r.wid)
        usleep(150_000)
    }

    static func act(_ p: [String: Any]) async throws -> [String: Any] {
        let given = p["actions"] as? [[String: Any]] ?? []
        // An action as the agent gave it that can't run that way (a kind no action has, a key its kind doesn't
        // read, a scroll of 0 px) runs nothing, numbered as it gave them, before any window is looked up (or a
        // browser started for navigate). Not a saved macro's steps: the macro ran to its end when it was saved,
        // and replays as it did. Nor the rest of a batch carried on after the user's OK (`first`): checked as
        // the batch began (a macro's steps may be in it).
        if p["first"] == nil {
            for (i, a) in given.enumerated() {
                if let why = invalid(a) { throw HelperError("nothing was run: action \(i + 1) (\(kind(a))) \(why)") }
            }
        }
        // Begun with open and no window: the batch works in the window open brings up. Until then it has
        // none (`.screen` stands in, and is never captured, activated, locked or checked against).
        let opening = opensFirst(p)
        let t: Target
        if opening { t = .screen } else { t = try await actTarget(p) }
        if !opening { current = t.key }
        guard AXIsProcessTrusted() else {
            throw HelperError("Accessibility permission missing for PuterUse (run: puter-use setup)")
        }
        // A macro step runs as the steps it saved.
        let (actions, expanded) = try Macros.expand(given, pid: pid(t))
        let saveAs = p["save_as"].flatMap { $0 is NSNull ? nil : $0 }
        if let saveAs { _ = try Macros.check(saveAs) }
        let base = max(int(p["first"], 1), 1) - 1  // a batch continued after the user's OK numbers on from there
        // The policy first: an app the agent may not act in isn't activated, captured or described on the
        // way to a refusal, and a batch with a refused action doesn't half run. Begun with open: the app it
        // starts or uses, by its bundle id, before it's started (the rest once its window is there).
        if opening {
            if let app = openApp(actions[0]) {
                do { try checkLaunch(app, actions[0]) } catch {
                    throw HelperError("nothing was run: action \(base + 1) (\(kind(actions[0]))) is \(error)")
                }
            }
        } else {
            try Policy.checkLook(pid(t))
        }
        for (i, a) in actions.enumerated() {
            do { try Policy.checkAction(a, pid: opening ? nil : pid(t)) } catch {
                throw HelperError("nothing was run: action \(base + i + 1) (\(kind(a))) is \(error)")
            }
        }
        // (With `detail: "low"`, its scale from the window's text, asked once the policy lets the agent look at it.)
        let o = detailed(Opts(p), t)
        // Continuing after the user's OK: the steps recorded before the stop (never with a confirm).
        var recorded: [[String: Any]] = (p["recorded"] as? [[String: Any]] ?? []).map { step in
            var s = step
            s["confirm"] = nil
            return s
        }
        let wantShot = p["screenshot"] as? Bool != false
        let always = wantShot && p["always_image"] as? Bool == true
        // Only reads (text, the clipboard) and clipboard writes: nothing on screen changes, so no picture is
        // taken before or after (none is kept as what the agent saw), and the app isn't activated for them.
        let readsOnly = onlyClipboard(actions, always: always)
        // Told nothing about a picture: how the agent last chose to look at this window decides (`ViewMode`).
        // After a screenshot without an image, the outline's changes stand in for one (`outlined`: interactive
        // or not; an outline asked for here sets which). Told "always", it's back to pictures.
        let shotGiven = shotMode(p)
        var outlined: Bool?
        if !opening, case .window(let w) = t {
            if shotGiven == .always { Session.current.modes[w.id] = .visual }
            outlined = outlineKind(given: shotGiven, mode: Session.current.modes[w.id], p)
            if let kind = outlined { Session.current.modes[w.id] = .outline(interactive: kind) }
        }
        // Coordinates with no screenshot of this window to refer to (none yet in this session, or the helper
        // restarted since): they were read off a picture that may be out of date, so the batch stops
        // before them. (Begun with open, the window it moves to hasn't been looked at: that stops them too.)
        // The picture find took to place what it listed counts for coordinates (its x,y came from it), but
        // the agent hasn't seen it (`unseen`).
        let (firstLook, unseen) = startLook(meta[t.key], opening: opening)
        var shownAtStart = false
        if case .window(let w) = t { shownAtStart = Windows.info(w.id)?.onScreen == true }
        let blind = firstLook && p["guard"] as? Bool != false && actions.contains(where: aimsByCoordinates)
        // Nor coordinates read off a picture of a window its app wasn't drawing then, or isn't now (`aimCheck`): they
        // may point at anything the window shows by now. (`drawnTitle`: a title the window was found drawn with.)
        var drawnTitle: String?
        var firstShot: (plan: CapturePlan, basis: PlanBasis?, shot: Shot)?  // shown if the first action fails (`ending`)
        // (Going by the outline, none to show: a failed first action takes one then, if it comes to that.)
        if firstLook && !readsOnly && ((wantShot && outlined == nil) || actions.contains(where: needsCoordinates)) {
            // Establish the coordinate mapping (for actions that need one, like a scroll in the middle).
            let basis = PlanBasis.of(t)  // read before planning, as `settle` does
            let start = try await plan(t, region: nil, o)
            let shot = try await start.run()
            remember(t, shot, Signature(shot.image), shown: false, sizing: o.sizing)
            firstShot = (start, basis, shot)
        }
        // A picture the agent hasn't seen isn't a "before": until it's seen one, the result shows the window.
        var before = unseen || opening ? nil : meta[t.key]?.sig
        let caretThen = unseen || opening ? nil : meta[t.key]?.caret  // the text cursor in that picture
        // What the end is compared with, moved past the window's own change of look as the act makes its app
        // active or the window key, when nothing else has changed it (`Baseline`; the primer's click too).
        let baseline = readsOnly || t.key == 0 ? nil : before.map {
            Baseline(sig: $0, target: t, opts: o, caretThen: caretThen, typed: meta[t.key]?.typedSince == true)
        }
        Session.current.baseline = baseline
        defer { Session.current.baseline = nil }
        let foreground = p["foreground"] as? Bool == true
        let run = Run(target: t, foreground: foreground, guarded: p["guard"] as? Bool != false, box: o.windowBox)
        Run.active[ObjectIdentifier(run)] = (run, Session.current)
        defer { Run.active[ObjectIdentifier(run)] = nil }
        // One session drives an app at a time; another's act on it waits for this one to finish. (Begun
        // with open: the app whose window it moves to, then.)
        if !opening, let pid = pid(t) {
            run.pidAtStart = pid
            try await AppLocks.acquire(pid)
            run.locked.insert(pid)
        }
        defer { for pid in run.locked { AppLocks.release(pid) } }
        pointer.enabled = p["cursor"] as? Bool != false
        pointer.speed = num(p["cursor_speed"]) ?? 1
        typist = Typist(wpm: num(p["typing_wpm"]) ?? 280)
        pasteOver = max(0, int(p["paste_over"], 80))
        Trace.configure(p["trace"] as? String)
        AppCards.enabled = p["app_cards"] as? Bool != false
        var errors: [String] = []
        var done = 0
        var cancelled = false
        if case .window(let w) = t { Connection.current?.work.window = "\(w.app) #\(w.id)" }
        Connection.current?.work.total = actions.count
        Session.current.acts += 1
        Connection.current?.work.first = base
        notes = expanded
        Session.current.reads = []
        Session.current.scrolled = nil
        Session.current.keyMove = nil
        defer {
            Session.current.keyMove = nil
            // What its windows show now, for telling later whether the user has taken one over (`reviewOwnership`).
            recordOwned([t.key, run.target.key, current ?? 0] + (Connection.current?.work.opened ?? []))
        }
        // Background apps drop clicks (as "activation clicks") and key equivalents. Tell the target's AppKit
        // layer it is active (and keep it so between calls, see `Hold`); the user's real focus is untouched.
        try Connection.check()
        if readsOnly || opening {
            // Nothing to make active: reads don't need the app active, and open's window is held once it's there
            // (`Run.moveTo`). The session's holds stay as they are.
        } else if !foreground, case .window(let w) = t, !Hold.isFront(w.pid) {
            // Held on this window since an earlier call: the app has taken the record already, so it's sent
            // again (it's cheap) without waiting for it.
            let wasHeld = Hold.heldSettled(pid: w.pid, wid: w.id)
            // Keyboard input (and key equivalents like cmd+a) only reach a window AppKit considers key. A batch
            // that only brings the window forward makes it key here too.
            let keys = actions.contains(where: { actsOnKeyboardFocus($0) }) || activatesOnly(actions)
            let heldHere = Hold.held[w.pid] == w.id
            let activation: () async throws -> Void = {
                if Hold.activate(pid: w.pid, wid: w.id), !wasHeld { try await Task.sleep(nanoseconds: 30_000_000) }
                guard keys else { return }
                // Held here and key already: sent again too, with no wait (and nothing to move).
                let wasKey = wasHeld && AX.focusedWindow(pid: w.pid) == w.id
                SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
                guard !wasKey else { return }
                try await Task.sleep(nanoseconds: 30_000_000)
                let focused = AX.focusedWindow(pid: w.pid)
                switch keyPrimer(focused: focused, wid: w.id, fresh: Hold.fresh.contains(w.pid), owner: { owner($0) }) {
                case .fromAgentWindow:
                    // Not taken (Firefox ignores it) while another of the agent's own windows has the keyboard: a
                    // click just outside this one's content moves it, as a click on the window would.
                    await Input.primer(try route(t, at: nil, foreground: false), force: true)
                    await Input.afterPrimer()  // the keyboard gets the primer's whole gap and the pause to move
                    try await Run.pause(0.1)
                case .fromUserWindow:
                    // A window of the user's has it, and the app is in the background: moved to the agent's own
                    // window the same way (the agent's clicks there move it too), so its keys don't wait on a
                    // keyboard that never comes back by itself. Not once the user has come into the app: there
                    // their keyboard stays where they left it (guardKeyboard says so).
                    guard let from = focused, !Hold.isFront(w.pid) else { break }
                    _ = try await moveKeyboardInBackground(w, from: from, flip: false)
                case .freshHold, .none:
                    break  // a new hold's click waits for the first key or menu command (`primeKeys`)
                }
            }
            // Becoming active or key changes how the window looks (its title bar, what's selected): with a
            // picture to compare the end with, that's taken apart from what the act does. Paid only when it
            // changes something: not again for a window held (and key) since an earlier act. (On a new hold AX
            // may name the window before AppKit has made it key: not key yet.)
            if let baseline, probesFlip(seen: true, onScreen: shownAtStart, heldHere: heldHere, keys: keys,
                                        keyHere: wasHeld && AX.focusedWindow(pid: w.pid) == w.id) {
                try await baseline.flip(activation)
            } else {
                try await activation()
            }
        } else {
            Hold.release(for: Session.current)
            // The app is the user's front app, but its keyboard is on another of the agent's own windows, so
            // what they'd type goes there already, not to a window of theirs. It's moved here the same way
            // (as a click here would), only while they're leaving the keyboard and mouse alone: they may be
            // typing into that window. Never off one they've used (`keyPrimer`).
            if !foreground, case .window(let w) = t, actions.contains(where: { actsOnKeyboardFocus($0) }),
               let key = AX.focusedWindow(pid: w.pid),
               keyPrimer(focused: key, wid: w.id, fresh: false, front: true, quiet: Input.userQuiet(),
                         owner: { owner($0) }) == .fromAgentWindow {
                await Input.primer(try route(t, at: nil, foreground: false), force: true)
                await Input.afterPrimer()
                try await Run.pause(0.1)
                if AX.focusedWindow(pid: w.pid) == w.id {
                    notes.append("moved \(Policy.appName(w.pid))'s keyboard here from your other window #\(key)")
                }
            }
        }
        // wait_for {change} compares with the window as it was before anything ran (taken only for such a batch).
        if case .window(let w) = t, actions.contains(where: waitsForChange) {
            run.changeBase = (try? await changeLook(t)).map { (wid: w.id, sig: $0) }
        }
        // Going by the outline: what's over the window as the batch begins (a sheet or popover that comes is shown).
        var overAtStart: WindowSet?
        if outlined != nil, case .window(let w) = t { overAtStart = WindowSet.of(w) }
        // And a frame of it as the batch begins (made active by now), for when its outline doesn't change: what
        // changed may be what the outline leaves out (`outlineMissed`). It's what the primer's click is taken
        // apart from, in place of the agent's image (`Baseline`, not kept as that image).
        var outlineStart: Baseline?
        if outlined != nil, !readsOnly, case .window = t, let shot = try? await plan(t, region: nil, o).run() {
            outlineStart = Baseline(sig: Signature(shot.image), target: t, opts: o, caretThen: caret(t), kept: false)
            Session.current.baseline = outlineStart
        }
        // Told to check its edits (verify_edits): each as it's made, and the window as the batch begins, for the
        // verdict at its end (`VerifyEdit`).
        if p["verify_edits"] as? Bool == true, !opening, !readsOnly, case .window(let w) = t {
            Session.current.edits = VerifyEdit.Collector(given, window: w)
        }
        defer { Session.current.edits = nil }
        var stopped: String?
        var confirm: [String: Any]?
        // Begun with open, which hasn't (yet) moved the batch to a window: there's no target to act in, look
        // at or check against (`.screen` only stands in for one).
        func noWindow() -> Bool { opening && !run.moved }
        for (i, a) in actions.enumerated() {
            if Connection.hungUp {  // the client gave up: nothing more runs
                cancelled = true
                break
            }
            Connection.current?.work.typed = 0
            Connection.current?.work.did = []
            Connection.current?.work.fields = nil
            Connection.current?.work.promptCancelled = false
            if opening, i == 1 {
                guard case .window(let w) = run.target, !noWindow() else {
                    errors.append("action \(base + 2) (\(kind(a))): there's no window to do it in: open brought up no "
                        + "window of its own (pass window; windows lists the app's)")
                    break
                }
                // Its app is known now: the policy for the rest, before any of it runs.
                run.pidAtStart = w.pid
                if let refused = refusal(actions, from: 1, pid: w.pid, base: base) {
                    errors.append(refused)
                    break
                }
            }
            // A macro step by position means the same only with the same things open over the window as
            // when it was saved.
            if run.guarded, !foreground, Macros.positional(a), case .window(let w) = run.target {
                let now = WindowSet.of(w).over.count, then = int(a["over"], 0)
                if now != then {
                    let rest = i + 1 == actions.count ? "it was" : "actions \(base + i + 1)-\(base + actions.count) were"
                    stopped = "stopped before action \(base + i + 1) (\(kind(a)), a macro step by position): "
                        + (now > then ? "something is open over the window that wasn't when the macro was saved"
                                      : "what was open over the window when the macro was saved isn't now")
                        + "; \(rest) not run. " + (wantShot ? "Look at the new screenshot" : "Take a screenshot") + " to see why."
                    break
                }
            }
            // Coordinates come from the last screenshot: if a sheet, dialog or menu has opened (or closed)
            // over the window since, they may point at something else now. Stop and let the agent look.
            let unseenWindow = blind && !run.moved
            var why: String? = !aimsByCoordinates(a) ? nil : unseenWindow
                ? "there's no earlier screenshot of this window to read them from (puter-use may have restarted)"
                : run.staleCoordinates()
            // A suggestions or saved-data list that the last action's typing opened: closed, and if the window is as
            // the agent saw it again, its coordinates hold (they can't be aimed at a list it hasn't seen).
            if why != nil, !unseenWindow, i > 0, !foreground, let pid = pid(run.target), typedIntoField(actions[i - 1], pid),
               AX.openMenu(pid: pid) != nil {
                await closeSuggestions(pid, before: "action \(base + i + 1)", route: try? route(run.target, at: nil, foreground: false))
                why = run.staleCoordinates()
            }
            // A picture of a window its app wasn't drawing (or isn't now: asked when its title has changed since).
            var instead: String?  // what to do then: a new picture wouldn't help
            if why == nil, aimsByCoordinates(a), case .window(let w) = run.target {
                let m = meta[w.id], title = m?.title == nil ? nil : Windows.info(w.id)?.title
                let check = aimCheck(a, guarded: run.guarded, foreground: foreground, moved: run.moved, frozenThen: m?.frozen != nil,
                                     titleChanged: title != nil && title != m?.title && title != drawnTitle)
                var frozen = check == .stop ? m?.frozen : nil
                if check == .look {
                    frozen = try await frozenNow(run.target, tree: treeReady(w.pid))
                    if let f = frozen { meta[w.id]?.frozen = f } else { drawnTitle = title }
                }
                // Judged not drawn at that picture: what's in the way is asked again first. In view again, the window
                // is drawn: its coordinates hold if it still looks as that picture does, else a new one is wanted.
                if check == .stop, var f = frozen {
                    (f.cover, f.key) = coverOf(w)
                    let holds = f.cover == .inView ? await pictureHolds(run.target) : nil
                    switch recheckAim(cover: f.cover, holds: holds) {
                    case .go:
                        meta[w.id]?.frozen = nil
                        frozen = nil
                    case .stop:
                        meta[w.id]?.frozen = f
                        frozen = f
                    case .retake:
                        frozen = nil
                        why = unseenSinceInView(app: w.app, wid: w.id)
                    }
                }
                // Still not drawn: its app is brought forward for a moment to draw it, when that's allowed (`revive`).
                // Drawn again, its coordinates hold if it still looks as that picture does, else a new one is wanted.
                if var f = frozen {
                    if await revive(w, &f) {
                        frozen = nil
                        if await pictureHolds(run.target) == true {
                            meta[w.id]?.frozen = nil
                        } else {
                            why = redrawnSince(app: w.app, wid: w.id)
                        }
                    } else {
                        meta[w.id]?.frozen = f
                        frozen = f
                    }
                }
                if let f = frozen { (why, instead) = staleAim(f, app: w.app, wid: w.id) }
            }
            if let why {
                let rest = i + 1 == actions.count ? "it was" : "actions \(base + i + 1)-\(base + actions.count) were"
                stopped = "stopped before action \(base + i + 1) (\(kind(a)) by coordinates): \(why); \(rest) not run. "
                    + (instead ?? (!unseenWindow && run.onlyPopupsOpened() ? "If it's a pop-up you don't want, keypress Escape closes it. " : "")
                        + (wantShot ? "Look at the new screenshot, then continue." : "Take a screenshot, then continue."))
                break
            }
            defer { notes += AX.remarks; AX.remarks.removeAll() }
            // An optional step's lookups say whether its target was found: a miss only before that skips it.
            let lookup = optionalStep(a) ? TargetLookup() : nil
            run.pageMark = nil
            Session.current.edits?.begin()  // what it edits is its own (verify_edits)
            do {
                try Policy.checkAction(a, pid: noWindow() ? nil : pid(run.target))  // (open's app: `checkLaunch`)
                try await Policy.$running.withValue(a) {
                    // Saved as it stands now: element numbers and pixels only mean something until the window changes.
                    let step = saveAs == nil ? nil : Macros.record(external(a), run.target)
                    // Keys pressed with a mouse button down: the hand on the mouse still trembles meanwhile.
                    let tremor: Task<Void, Never>? = run.heldButton.flatMap { held in
                        keyboardActions.contains(kind(a)) || kind(a) == "menu"
                            ? Task { await pointer.hold(30, held.route, button: held.button) } : nil
                    }
                    defer {
                        tremor?.cancel()
                        if tremor != nil { pointer.endHold() }
                    }
                    // What's over the window before it, so `settle` sees a sheet the action made at once.
                    let overBefore = i < actions.count - 1 && mayOpen(a) ? run.baseline() : nil
                    Session.current.pressing = []  // the presses its checks let through, kept once it's done
                    try await TargetLookup.$current.withValue(lookup) {
                        try await perform(marked(a, last: i == actions.count - 1, menuLook: !foreground && pid(run.target) != nil), run)
                    }
                    Policy.pressesMade()
                    // A link followed or a form sent: the next action (or the batch's picture) meets the new page.
                    if let mark = run.pageMark {
                        run.pageMark = nil
                        try await awaitPage(after: mark, run)
                    }
                    try Connection.check()  // given up partway: whether this one took effect isn't known
                    if let step { recorded.append(Macros.ran(step, menu: run.ranMenu)) }
                    done += 1
                    if !CaretShape.leavesTextAlone(a) { baseline?.typed = true }  // (a later key's change of look)
                    Connection.current?.work.done = done
                    Connection.current?.work.steps.append(brief(a))
                    if i < actions.count - 1 {
                        if let (button, r, _) = run.heldButton {  // a hand holding the button down never quite stops
                            await pointer.hold(0.06, r, button: button)
                        } else if mayOpen(a) {
                            try await run.settle(since: overBefore)
                            // A menu left open would take the next actions' keys (and the user's): closed now.
                            if !foreground, !noWindow(), let pid = pid(run.target) {
                                await closeLeftOpenMenu(pid: pid, wait: false, afterKeys: typedIntoField(a, pid),
                                                        route: try? route(run.target, at: nil, foreground: false))
                            }
                        } else {
                            await Input.ms(60)
                        }
                    }
                }
            } catch let ok as Policy.NeedsOK where !Connection.hungUp {
                // Nothing of it has happened yet (or only what `partly` says): the agent asks the user, then
                // repeats it with confirm: true.
                let n = base + i + 1
                if let partly = ok.partly {
                    let rest = i + 1 == actions.count ? "" : " Actions \(n + 1)-\(base + actions.count) were not run."
                    stopped = "stopped at action \(n) (\(kind(a))): \(ok); \(partly).\(rest) Ask the user; "
                        + "if they agree, repeat action \(n) with \"confirm\": true"
                } else {
                    let rest = i + 1 == actions.count ? "it was" : "actions \(n)-\(base + actions.count) were"
                    stopped = "stopped before action \(n) (\(kind(a))): \(ok); \(rest) not run. Ask the user; "
                        + "if they agree, repeat it with \"confirm\": true"
                }
                confirm = ["action": n, "label": ok.label, "rest": Array(actions[i...]),
                           "app": run.pidAtStart > 0 ? Policy.appName(run.pidAtStart) : ""]
                if saveAs != nil { confirm?["recorded"] = recorded }  // to save the whole batch once it's carried on
                break
            } catch let miss as Missing where !Connection.hungUp && skipsOptional(a, miss, found: lookup?.found ?? true) {
                // Optional, and nothing shows what it names: nothing of it was done, and the batch goes on. A macro
                // saved from the batch keeps it, optional, for when it's there.
                notes.append("skipped optional action \(base + i + 1) (\(kind(a))): \(miss)")
                if saveAs != nil { recorded.append(Macros.record(external(a), run.target)) }
                done += 1
                Connection.current?.work.done = done
                Connection.current?.work.steps.append(brief(a) + " (skipped: not there)")
            } catch let miss as NotReached where !Connection.hungUp && i == actions.count - 1 {
                // A scroll until, last in the batch, that didn't find its text: nothing after it depends on it, so
                // it's a note, and the end shows where it stopped. (Before other actions, it stops the batch.)
                notes.append("action \(base + i + 1) (\(kind(a))): \(miss)")
                if saveAs != nil { recorded.append(Macros.record(external(a), run.target)) }
                done += 1
                Connection.current?.work.done = done
                Connection.current?.work.steps.append(brief(a))
            } catch {
                if error is Cancelled || Connection.hungUp {
                    cancelled = true
                    // (A wait, look, or pre-side-effect focus prompt that was cut short did nothing.)
                    let promptOnly = Connection.current.map {
                        let w = $0.work
                        return w.promptCancelled && w.fields == nil && w.typed == 0 && w.did.isEmpty
                    } == true
                    if done == i, !promptOnly, !["wait", "sleep", "wait_for", "waitfor", "screenshot"].contains(kind(a)) {
                        Connection.current?.work.partial = partway(base + i + 1, a)
                    }
                    break
                }
                errors.append("action \(base + i + 1) (\(a["type"] ?? "?")): \(error)")
                break
            }
        }
        // Begun with open: the batch's app is the one whose window it moved to (a macro saved from it is that app's).
        if opening, run.pidAtStart == 0, !noWindow(), case .window(let w) = run.target { run.pidAtStart = w.pid }
        if cancelled || Connection.hungUp {
            // The client gave up: let go of what's held and close a menu left open (cleanup always runs),
            // then stop. No settle, screenshot or record of what was shown: no one would see it.
            if let w = Connection.current?.work { Connection.current?.work.opened += openedBy(run).filter { !w.opened.contains($0) } }
            await Connection.ungated {
                _ = await run.releaseAll(clickTiming, cancelled: true)
                if !foreground, !noWindow(), let pid = pid(run.target) {  // not remembered: the agent never hears of it
                    await closeLeftOpenMenu(pid: pid, wait: cancelWait(actions, done: done),
                                            route: try? route(run.target, at: nil, foreground: false), remember: false)
                }
            }
            throw Cancelled()
        }
        let released = await run.releaseAll(clickTiming)
        // The last input: settle_ms counts from here (the menu check and the work below are part of it), or
        // from a menu closed just now.
        var quiet = ProcessInfo.processInfo.systemUptime
        if !foreground, !noWindow(), let pid = pid(run.target) {
            let last = done > 0 && actions.indices.contains(done - 1) ? actions[done - 1] : nil
            let typed = typedIntoField(last, pid)
            // A web page's combo box (a search box with suggestions) shows its list a moment after the keys: wait for it.
            let combo = typed && AX.focusedElement(pid: pid).map {
                AX.value($0, kAXRoleAttribute) as? String == "AXComboBox" && AX.webArea(of: $0) != nil
            } == true
            var gone = false  // close_window closed it (checked again below, before saying so)
            if closes(last), case .window(let w) = run.target { gone = Windows.info(w.id)?.onScreen != true }
            if await closeLeftOpenMenu(pid: pid, wait: menuWait(last, combo: combo, gone: gone), afterKeys: typed,
                                       route: try? route(run.target, at: nil, foreground: false)) {
                quiet = ProcessInfo.processInfo.systemUptime
            }
        }
        if !released.isEmpty { notes.append("let go of \(released.joined(separator: ", ")) (still held at the end)") }
        if let saveAs {
            if done == actions.count, !actions.isEmpty {
                do { notes.append(try Macros.save(saveAs, steps: recorded, pid: run.pidAtStart)) } catch {
                    errors.append("save_as: \(error)")
                }
            } else {
                notes.append("not saved as a macro: only a batch that runs to the end is")
            }
        }
        // An action may have opened a window in this app (cmd+n, a link, a dialog): it becomes the target.
        var target = run.target
        if let baseline { before = baseline.sig }  // (past the window's own change of look, if that was all)
        if run.moved { before = nil }
        var onNewWindow = false  // one window at most: once followed, it's the one shown
        func followNewWindow() async -> Bool {
            guard !onNewWindow else { return true }
            guard done > 0, case .window(let w) = target,
                  let found = await follow(w, visibleBefore: run.visibleBefore, existedBefore: run.existedBefore,
                                           box: o.windowBox, arrange: run.arrange(w.pid))  // only w.pid's windows
            else { return false }
            let nw = found.window
            guard found.followed else {  // may be the user's (noted): not looked at again, nor counted as one the batch opened
                run.visibleBefore.insert(nw.id)
                run.existedBefore.insert(nw.id)
                return false
            }
            target = .window(nw)
            agentWindows.insert(nw.id)
            if validFocusGrant(pid: nw.pid, wid: nil) { Session.current.focusGrant?.wid = nw.id }
            Connection.current?.work.opened.append(nw.id)
            current = nw.id
            before = nil
            onNewWindow = true
            return true
        }
        var out: [String: Any] = ["done": done, "total": actions.count]
        // Where the agent is in the window it's shown, beside the picture (`orient`), as what ran makes worth
        // saying: the actions done, and one that failed partway (it may have done something).
        let ran = Array(actions.prefix(done < actions.count && !errors.isEmpty ? done + 1 : done))
        // The end found the window as the agent's last picture of it, pixel for pixel, though its title had changed
        // (`undrawn`): its app may not be drawing it.
        var undrawnEnd = false
        func oriented(_ r: [String: Any]) async throws -> [String: Any] {
            readsOnly ? r : try await orient(r, target, ran: ran, undrawn: undrawnEnd) {  // once it's drawn again
                try await result(target, try await plan(target, region: nil, o).run(), o, zoom: false,
                                 text: p["text"] as? Bool == true, trim: true)
            }
        }
        func sameButTitle(_ sig: Signature, _ b: Signature) -> Bool {
            guard target.key == t.key, case .window(let w) = target else { return false }
            return undrawn(title: Windows.info(w.id)?.title, drawn: meta[w.id]?.title, sig: sig, last: b)
        }
        // Keys, typing or a click went to the window (`CaretShape`). Ending with no new picture of it, that's kept:
        // a change shaped like a text cursor isn't taken for one blinking until the agent has seen the window again.
        let typedHere = !ran.allSatisfy(CaretShape.leavesTextAlone)
        func noPicture() {
            guard typedHere else { return }
            meta[t.key]?.typedSince = true
            meta[target.key]?.typedSince = true
        }
        // Where the picture of `w` just sent changed (`c`, in the capture's pixels), in the picture's: through the
        // margins left out of it. Nothing to point at when all of it is in what was left out. `picture`: the record of
        // a picture withheld from the agent (marked verified), which isn't the one kept.
        func reportChange(_ c: (box: CGRect, fraction: Double), _ w: Target, picture: Meta? = nil) {
            var box: CGRect? = c.box
            if let m = picture ?? meta[w.key] { box = m.pictureBox(c.box) }  // (in a crop, from its origin)
            if let box { out["change_box"] = [Int(box.minX), Int(box.minY), Int(box.maxX), Int(box.maxY)] }
            out["change_fraction"] = c.fraction
        }
        if !errors.isEmpty { out["errors"] = errors }
        if let c = run.clipboard { out["clipboard"] = c }
        if !Session.current.reads.isEmpty { out["reads"] = Session.current.reads }  // each marked as data by the client
        if case .window(let w) = run.target, let card = AppCards.card(pid: w.pid) { out["card"] = card }
        if let stopped { out["stopped"] = stopped }
        if let confirm { out["confirm"] = confirm }
        // The window went (closed, or hidden as some apps do): there's nothing to show or compare.
        if case .window(let w) = t, target.key == t.key, shownAtStart, Windows.info(w.id)?.onScreen != true {
            try await Task.sleep(nanoseconds: 150_000_000)  // not just between states
            if Windows.info(w.id)?.onScreen != true {
                out["closed"] = "window #\(w.id) is no longer on screen"
                if !notes.isEmpty { out["notes"] = notes }
                current = nil
                return out
            }
        }
        // Begun with open, which brought up no window of its own (or didn't run): nothing of the batch's to
        // show, and the session's window may be anyone's. Nor a window of an app the policy keeps agents out of.
        if noWindow() || (opening && Policy.level(pid(run.target) ?? 0) == .deny) {
            if !notes.isEmpty { out["notes"] = notes }
            return out
        }
        // Going by the window's outline (`outlined`): what changed in it, and no image, unless the outline can't
        // stand in for one. Then the window is shown as "auto" would show it, saying why (`escalation`).
        var escalationNote: String?
        // Not shown after all, as "auto" would (the window is as the agent last saw it): the note saying why there's
        // no outline would promise a picture that isn't there.
        func noEscalation() {
            guard let e = escalationNote else { return }
            notes = Self.dropping(e, from: notes)
            if let n = out["notes"] as? [String] {
                let kept = Self.dropping(e, from: n)
                out["notes"] = kept.isEmpty ? nil : kept
            }
        }
        if let interactive = outlined, !readsOnly {
            var escalation = outlineEscalation(failed: !errors.isEmpty, stopped: stopped != nil, confirm: confirm != nil,
                                               moved: run.moved)
            if escalation == nil {
                do { try await Run.pause(followWait(actions, done: done, failed: false)) } catch {
                    // The client gave up meanwhile: the note for its lost result names what opened.
                    if let w = Connection.current?.work { Connection.current?.work.opened += openedBy(run).filter { !w.opened.contains($0) } }
                    throw error
                }
                if await followNewWindow() {
                    escalation = "a new window opened"
                } else if case .window(let w) = target, let then = overAtStart, let change = WindowSet.of(w).change(since: then) {
                    escalation = change  // a sheet, dialog or popover came (or went)
                } else {
                    var oo = o
                    oo.interactive = interactive
                    let look = outlineLook(target, oo, diff: true)
                    escalation = look.problem
                    // The outline says nothing changed: the window may have all the same (a display, a status text
                    // or a picture the outline leaves out). One frame tells, against the batch's first.
                    var cursorNote: String?
                    if escalation == nil, look.unchanged, done > 0, let start = outlineStart, target.key == t.key {
                        let missed = await outlineMissCheck(start, target, o)
                        if let why = missed.why {
                            escalation = why
                            before = start.sig  // what changed is shown against the window as the batch began
                        }
                        cursorNote = missed.note
                    }
                    if escalation == nil {
                        look.keep()
                        if firstLook { meta[t.key] = nil }  // no image: coordinates stay unanchored, as with "never"
                        noPicture()
                        if let cursorNote { notes.append(cursorNote) }
                        if !notes.isEmpty { out["notes"] = notes }
                        out["window"] = describe(target)
                        return try await oriented(out.merging(look.out, uniquingKeysWith: { _, new in new }))
                    }
                }
            }
            if let escalation {
                escalationNote = "no outline this time: \(escalation)"
                notes.append("no outline this time: \(escalation)")
            }
        }
        let end = ending(wantShot: wantShot, always: always, done: done, stopped: stopped != nil, confirm: confirm != nil,
                         failed: !errors.isEmpty, firstLook: unseen, moved: run.moved, clipboardOnly: readsOnly)
        if end == .firstLook {
            // Taken again (one capture): the failed action, or a wait_for that timed out, may have changed the
            // window since. With the start's plan, unless something opened over the window or it moved: then
            // a new plan, which the mapping (`result`) follows. None was taken at the start when find's picture
            // was there to aim from: one now.
            let shot: Shot?
            if let first = firstShot {
                let again = PlanBasis.of(t) == first.basis ? first.plan : try? await plan(t, region: nil, o)
                shot = (try? await again?.run()) ?? first.shot
            } else {
                shot = try? await plan(t, region: nil, o).run()
            }
            if let shot, let res = try? await result(t, shot, o, zoom: false, text: p["text"] as? Bool == true, diff: true,
                                                     trim: true) {
                if !notes.isEmpty { out["notes"] = notes }
                out.merge(res) { _, new in new }
                if let note = partShown(t, shot) { out["notes"] = (out["notes"] as? [String] ?? []) + [note] }
                out["changed"] = true
                return try await oriented(out)
            }
        }
        if end == .check, let b = before {
            // Nothing ran, but the window may have changed by itself since the agent's last image (a page
            // loaded, a dialog came up): one quick look, with no settling, sent only if it did.
            // (The text cursor blinking, told by its shape where accessibility can't: not after keys or a click.)
            let typed = typedHere || meta[t.key]?.typedSince == true
            let blink = { (sig: Signature, shot: Shot) -> Bool in
                guard let d = CellDiff(sig, from: b) else { return false }
                return cursorBlinked(d, then: caretThen, now: caretThen == nil ? nil : caret(target), shot, target, typed: typed)
            }
            let look = try? await quickLook(before: b, capture: { try await plan(target, region: nil, o).run() }, blinked: blink)
            if let look, let c = look.change,
               let res = try? await result(target, look.shot, o, zoom: false, text: p["text"] as? Bool == true, diff: true,
                                           trim: true) {
                if !notes.isEmpty { out["notes"] = notes }
                out.merge(res) { _, new in new }
                if let note = partShown(target, look.shot) { out["notes"] = (out["notes"] as? [String] ?? []) + [note] }
                out["changed"] = true
                reportChange(c, target)
                return try await oriented(out)
            }
            if let look {  // the agent's last image still holds
                out["changed"] = false
                undrawnEnd = sameButTitle(Signature(look.shot.image), b)
            }
        }
        if end != .settled {
            // No image: the agent still hasn't seen the window, so its coordinates stay unanchored (a picture find
            // took stays: the x,y it gave came from it).
            if firstLook { meta[t.key] = nil }
            do { try await Run.pause(readsOnly ? 0 : followWait(actions, done: done, failed: !errors.isEmpty)) } catch {
                // The client gave up meanwhile: as above, the note for its lost result names what opened.
                if let w = Connection.current?.work { Connection.current?.work.opened += openedBy(run).filter { !w.opened.contains($0) } }
                throw error
            }
            if !readsOnly { _ = await followNewWindow() }  // (reads open no window)
            noPicture()
            noEscalation()
            if !notes.isEmpty { out["notes"] = notes }
            out["window"] = describe(target)
            if p["text"] as? Bool == true { out.merge(accessibility(target, o, diff: true)) { _, new in new } }
            return try await oriented(out)  // (with "never", the only word of where the focus went)
        }

        // settle_ms after the last input, then still frames. Ones that show a change from what the agent last
        // saw end the wait at once; ones that don't go on until the second frame the wait used to take (all of
        // settle_ms after the menu check, then a frame, then 0.15 s), so "no visible change" comes no sooner.
        // Web pages, Electron apps and the screen wait as before: there a hover or focus ring changes the
        // picture before the page answers.
        let settle = min(max(num(p["settle_ms"]) ?? 250, 0), 10000) / 1000
        let full = waitsInFull(run.target), now = ProcessInfo.processInfo.systemUptime
        func early() -> Early? {
            full ? nil : Early(before: before, start: now + settle, wait: { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) })
        }
        var shadow: (sig: Signature?, at: Double)?
        // After navigate there's no menu poll (`menuWait`), but a page may still be drawing itself after it
        // says it's loaded: its first frame comes no sooner than with the poll (0.4 s), as before.
        let navigated = !foreground && navigates(done > 0 && actions.indices.contains(done - 1) ? actions[done - 1] : nil)
        if full, Trace.on, !navigated, min(settle, now - quiet) > 0.2 {
            // Trace only: the frame an early end would have returned, to measure whether it's safe here too.
            await Input.sleep(quiet + settle - now)
            shadow = (await earlyFrame(target, o, before: before), ProcessInfo.processInfo.systemUptime)
            await Input.sleep(now + settle - ProcessInfo.processInfo.systemUptime)
        } else {
            await Input.sleep(firstFrameWait(full: full, navigated: navigated, settle: settle, quiet: quiet, now: now))
        }
        let followed = await followNewWindow()
        var shot: Shot, sig: Signature
        var motion = Motion()  // what moved between its frames, nothing being done (`Ambient`)
        var watched: Double?  // how long it went on looking for a new window after an early end (trace)
        do {
            let e = early()
            (shot, sig, motion) = try await settledShot(target, o, early: e)
            if !followed {  // slower apps
                var found = await followNewWindow()
                // An early end comes before the wait used to look again: after an action that may open a window
                // a moment later, keep looking until then.
                if !found, let e, opensWindow(done > 0 ? actions[done - 1] : nil) {
                    let began = ProcessInfo.processInfo.systemUptime
                    found = try await watchForWindow(until: e.lookedAgain, look: followNewWindow, pause: { try await Run.pause(0.05) })
                    watched = ProcessInfo.processInfo.systemUptime - began
                }
                if found { (shot, sig, motion) = try await settledShot(target, o, early: early()) }
            }
        } catch {
            if case .window(let w) = target, Windows.info(w.id) != nil { throw error }
            out["closed"] = "\(error)"
            current = nil
            return out
        }
        if Trace.on {
            var line: [String: Any] = ["k": "settled", "after": ProcessInfo.processInfo.systemUptime - quiet, "full": full]
            if let watched { line["watched"] = watched }
            if let shadow, target.key == run.target.key {
                line["early"] = shadow.sig != nil  // the early end would have stopped at its second frame
                if let s = shadow.sig {
                    line["early_after"] = shadow.at - quiet
                    line["early_diff"] = s.diff(sig, outW: 1, outH: 1)?.fraction ?? 0  // vs the frame returned
                }
            }
            Trace.log(line)
        }
        if !notes.isEmpty { out["notes"] = notes }
        let caretNow = caretThen != nil && target.key == t.key ? caret(target) : nil
        let perPoint = cellScale(sig.w, sig.h, shot, target).perPoint
        // What kept moving by itself in these frames: kept with the picture, if it's sent (`Meta.ambient`).
        var moving: [CGRect] { motion.w == sig.w && motion.h == sig.h ? Ambient.regions(motion, perPoint: perPoint) : [] }
        var change: (box: CGRect, fraction: Double)? = before == nil
            ? (CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height), 1) : nil
        // Nothing but waiting since the agent's last image (nothing typed or clicked in between): what changed since
        // then changed by itself, and is kept with the picture too (`Ambient.record`).
        let idle = before != nil && outlined == nil && target.key == t.key && meta[t.key]?.typedSince != true && !ran.isEmpty
            && ran.allSatisfy { ["wait", "sleep"].contains(kind($0)) }
        if let b = before {
            // Nothing the agent needs to see: only what keeps moving by itself changed (left out only after a
            // batch that otherwise left the window alone, waiting, scrolling or moving the pointer, and away from
            // where it aimed), or the text cursor blinked (told by its shape where accessibility can't, not once
            // keys or a click went to the window). Neither when the outline's check asked for this picture: that
            // goes by the frames as they are.
            let byPicture = outlined == nil, same = target.key == t.key
            var mask: [CGRect] = [], known: [CGRect] = [], touched: [CGRect] = []
            if byPicture, same, !typedHere, let k = meta[t.key]?.ambient, !k.isEmpty, let aimed = aimedPoints(ran, t) {
                known = k
                touched = Ambient.touched(points: aimed, frames: [], perPoint: perPoint, offset: shot.rect.origin)
                mask = Ambient.mask(known: known, moving: moving, touched: touched, maxSide: Ambient.maxCells(perPoint: perPoint))
            }
            let typed = !byPicture || typedHere || meta[t.key]?.typedSince == true
            func shownWith(_ mask: [CGRect]) -> (change: (box: CGRect, fraction: Double)?, leftOut: Bool, blinked: Bool) {
                shownChange(sig, from: b, outW: shot.image.width, outH: shot.image.height, mask: mask) { rest in
                    cursorBlinked(rest, then: caretThen, now: caretNow, shot, target, typed: typed)
                }
            }
            var shown = shownWith(mask)
            // A part that moves only now and then (a clock ticking once a second) may not have between these frames:
            // when all that's left is in what was moving before, it's watched a moment longer (`Ambient.watch`).
            if shown.change != nil, !known.isEmpty {
                let basis = PlanBasis.of(target)
                var again: CapturePlan?  // (made at the first frame it takes)
                mask = try await Ambient.watch(known: known, touched: touched, perPoint: perPoint, motion: &motion, last: sig,
                                               quiet: { shownWith($0).change == nil }, frame: {
                    guard PlanBasis.of(target) == basis else { return nil }
                    if again == nil { again = try? await plan(target, region: nil, o) }
                    return (try? await again?.run()).map { Signature($0.image) }
                }, pause: { try await Run.pause(0.15) }, clock: { ProcessInfo.processInfo.systemUptime })
                shown = shownWith(mask)
            }
            change = shown.change
            if shown.blinked { Trace.log(["k": "blink"]) }
            if change == nil, shown.leftOut {
                out["notes"] = (out["notes"] as? [String] ?? []) + ["only what keeps moving by itself changed (a spinner or a clock, say)"]
                Trace.log(["k": "ambient", "regions": mask.count])
            }
        }
        // The cursor moved (a click in the text, an arrow key) but shows in neither picture, being between
        // blinks: say so rather than drop it. (When it shows, that's a change, with the picture.)
        if change == nil, let then = caretThen, let now = caretNow, now.moved(from: then) {
            out["notes"] = (out["notes"] as? [String] ?? []) + ["the text cursor moved: it's now \(now.at) characters into the text"]
            meta[t.key]?.caret = now  // the agent knows: its blinking there isn't a change
        }
        // A stop that guards coordinates or a macro's positions (something opened over the window, or the agent
        // hasn't seen it) shows the window whatever. One for the user's OK only if the window changed: the
        // agent has the picture it chose the press from.
        if change == nil && !always && (stopped == nil || confirm != nil) {
            Run.look(target)  // what the agent last saw still holds
            noPicture()
            noEscalation()
            out["changed"] = false
            out["window"] = describe(target)
            if p["text"] as? Bool == true { out.merge(accessibility(target, o, diff: true)) { _, new in new } }
            if let b = before { undrawnEnd = sameButTitle(sig, b) }
            return try await oriented(out)
        }
        // With crop_changes: only the part round what changed, when that's a small part of a window the agent has
        // seen whole lately and nothing about the batch calls for all of it (`ChangeCrop`). All of what changed is
        // in it (one box round every change).
        var crop: CGRect?
        var cropText: String??  // its outline, when it was read to decide (`result` reads it otherwise)
        if o.cropChanges, let c = change, case .window(let w) = target {
            let m = meta[w.id]
            let reshaped = m?.captured != shot.rect || Run.seen[w.id].map { WindowSet.of(w).change(since: $0) != nil } ?? true
            let agreed = ran.contains { a in  // a press the user agreed to: its outcome is looked at whole
                a["confirm"] as? Bool == true || (a["fields"] as? [[String: Any]])?.contains { $0["confirm"] as? Bool == true } == true
            }
            if !ChangeCrop.keyframe(seen: before != nil && m?.shown == true, crops: m?.crops ?? 0,
                                    newWindow: run.moved || onNewWindow || target.key != t.key, reshaped: reshaped,
                                    failed: !errors.isEmpty, stopped: stopped != nil || confirm != nil, irreversible: agreed,
                                    outlined: outlined != nil, always: always) {
                let size = CGSize(width: shot.image.width, height: shot.image.height)
                crop = ChangeCrop.decide(changeBox: c.box, fraction: c.fraction, picture: size, perPoint: Double(shot.scale),
                                         tile: o.sizing.tile)
                // The outline of what's in it goes with it (no marks, no outline asked for): counted too, or the
                // whole window it is.
                if let part = crop, !o.marks, p["text"] as? Bool != true {
                    let text = cropOutline(w, within: ChangeCrop.points(part, of: shot))
                    crop = ChangeCrop.decide(changeBox: c.box, fraction: c.fraction, picture: size, perPoint: Double(shot.scale),
                                             tile: o.sizing.tile, outline: text?.count ?? 0)
                    cropText = .some(text)
                }
            }
        }
        // Told to check its edits (verify_edits): only routine field edits that accessibility confirms, nothing else
        // changed, and nothing about the batch ruling it out (`VerifyEdit`). Then the reply is marked verified, and
        // its picture, which the agent isn't shown, isn't kept as what it saw (`result`'s withhold): the next reply
        // is compared with the last one it was shown.
        let part = partShown(target, shot)
        var verified = false
        if let edits = Session.current.edits, target.key == t.key {
            let ending = VerifyEdit.Ending(failed: !errors.isEmpty, stopped: stopped != nil || confirm != nil,
                                           noted: !notes.isEmpty || part != nil, firstLook: unseen,
                                           newWindow: run.moved || onNewWindow)
            verified = edits.verdict(actions, now: sig, before: before, capture: shot.rect, ending: ending)
        }
        var withheld: Meta?  // that picture's own record
        var withhold: ((Meta) -> Void)?
        if verified { withhold = { withheld = $0 } }
        let res = try await result(target, shot, o, zoom: false, text: p["text"] as? Bool == true, diff: true, trim: true,
                                   ambient: Ambient.record(moving, now: sig, before: before, idle: idle, perPoint: perPoint),
                                   crop: crop, cropOutline: cropText, withhold: withhold)
        if firstLook, target.key != t.key { meta[t.key] = nil }  // it was shown the window it moved to instead
        out.merge(res) { _, new in new }
        if let part { out["notes"] = (out["notes"] as? [String] ?? []) + [part] }
        out["changed"] = change != nil
        if let c = change { reportChange(c, target, picture: withheld) }
        if verified {
            out["verified"] = true
            Session.current.edits?.withhold()  // its edits are judged again with the next act's here
            noPicture()  // (the agent has no new picture after the typing)
        }
        return try await oriented(out)
    }

    // MARK: - where the agent is

    /// A reply (`out`) with where the agent is in `t`'s window, beside the picture, as the batch's actions
    /// (`ran`) make worth saying, each field only when there's news (`Session.told`, per window):
    /// - `url`: the page's address (`pageAddress`: its address bar's when the page's can't be read), after an action
    ///   that may go to another page (`mayNavigate`), in a browser's window, when it isn't the one the agent was last
    ///   told;
    /// - `focus`: what has the keyboard focus (`AX.focusedSummary`: role and label, or "in another window
    ///   (#N)"), after keys, a click or a press (`movesFocus`), when it changed; an outline's own focus line
    ///   (`focused`) has said it already;
    /// - `selected`: what's selected (`selectedText`), after a gesture that selects text (`selects`);
    /// - `scroll`: where the batch's last scroll left the scroll bar (`ScrollWatch.place`).
    /// A password field's text is never in it: the focus is named by role and label, and a selection there
    /// isn't read. A browser's or Electron app's accessibility tree isn't switched on for these (`treeReady`).
    /// Then what shows the window's app isn't drawing it, when something does (`staleReply`; `undrawn`: the act's end
    /// found it as the agent's last picture with another title; `recapture`: the picture taken anew, once it's drawn
    /// again).
    static func orient(_ out: [String: Any], _ t: Target, ran: [[String: Any]], undrawn: Bool = false,
                       recapture: (() async throws -> [String: Any])? = nil) async throws -> [String: Any] {
        var out = out
        if let s = Session.current.scrolled { out["scroll"] = s }
        guard case .window(let w) = t else { return out }
        var told = Session.current.told[w.id] ?? Orientation()
        let ready = treeReady(w.pid)
        var page: (tree: PageTree?, address: String?)?  // read when the page's address couldn't be
        if ready, isBrowser(w.pid), ran.contains(where: mayNavigate) {
            let read = pageAddress(w)
            page = read.page
            if let url = read.url, url != told.url {
                out["url"] = url
                told.url = url
            }
        }
        if let f = out["focused"] as? String {
            told.focus = f
        } else if ready, ran.contains(where: movesFocus), let f = AX.focusedSummary(pid: w.pid, wid: w.id), f != told.focus {
            out["focus"] = f
            told.focus = f
        }
        if ready, ran.contains(where: selects), let s = AX.selection(pid: w.pid, wid: w.id) {
            out["selected"] = selectedText(s.text, count: s.count)
        }
        Session.current.told[w.id] = told
        return try await staleReply(out, w, undrawnEnd: undrawn, page: page, recapture: recapture)
    }

    /// A screenshot's reply (`out`) with the page's address in a browser's window, whatever the agent was told
    /// before: a screenshot is how it gets its bearings again (after its context was cut short, too). What the
    /// reply tells, the address and an outline's focus line, is what it was last told (`Session.told`). Then what
    /// shows the window's app isn't drawing it, when something does (`staleReply`, with `recapture`).
    static func bearings(_ out: [String: Any], _ t: Target,
                         recapture: (() async throws -> [String: Any])? = nil) async throws -> [String: Any] {
        guard case .window(let w) = t else { return out }
        var out = out
        var told = Session.current.told[w.id] ?? Orientation()
        var page: (tree: PageTree?, address: String?)?  // read when the page's address couldn't be
        if isBrowser(w.pid), treeReady(w.pid) {
            let read = pageAddress(w)
            page = read.page
            if let url = read.url {
                out["url"] = url
                told.url = url
            }
        }
        if let f = out["focused"] as? String { told.focus = f }
        Session.current.told[w.id] = told
        return try await staleReply(out, w, page: page, recapture: recapture)
    }

    /// A browser window's page address for a reply: its web page's (`shortURL`), else, when that can't be read (no page
    /// in its tree, as in a window its app isn't drawing), its address bar's (`shortAddress`), with what was read of
    /// the page then (`page`).
    static func pageAddress(_ w: WinInfo) -> (url: String?, page: (tree: PageTree?, address: String?)?) {
        if let u = AX.pageURL(pid: w.pid, wid: w.id) { return (shortURL(u), nil) }
        let page = browserPage(w)
        return (page?.address.map(shortAddress), page)
    }

    /// Whether asking `pid`'s accessibility about its page or its focus won't be what switches on its tree:
    /// apps other than Chromium's and Gecko's always have theirs; those have it once a look that needs it has
    /// switched it on (`AX.appElement`), never for a reply's extras (as a picture never does, see `caret`).
    static func treeReady(_ pid: pid_t) -> Bool {
        if Windows.isGecko(pid) { return AX.enhanced.contains(pid) }
        if Windows.isChromium(pid) { return AX.treeAsked[pid] != nil }
        return true
    }

    /// How long a page's address may be in a reply, and its query (with its fragment) within that.
    nonisolated static let urlClip = 120, queryClip = 40

    /// A page's address as a reply gives it: scheme, host and path, then its query and fragment clipped to
    /// about `queryClip` characters (a token in one is cut short), the whole to `urlClip`; never the user name
    /// or password an address may carry.
    nonisolated static func shortURL(_ s: String) -> String {
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        guard let c = URLComponents(string: s), let scheme = c.scheme else { return clip(s, urlClip) }
        var base = c.host.map { scheme + "://" + $0 + (c.port.map { ":\($0)" } ?? "") } ?? scheme + ":"
        base += c.percentEncodedPath
        let rest = (c.percentEncodedQuery.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? "")
            + (c.percentEncodedFragment.flatMap { $0.isEmpty ? nil : "#" + $0 } ?? "")
        return clip(base + clip(rest, queryClip + 1), urlClip)
    }

    /// Whether action `a` may take a browser's window to another page: a click (not a right-click, which opens
    /// a menu), Return or a shortcut with cmd (back, forward, reload, a bookmark), a submit, a menu command, an
    /// accessibility press, a pop-up's choice, navigate and open; and a wait for the page, which may be loading
    /// from an action in an earlier call.
    nonisolated static func mayNavigate(_ a: [String: Any]) -> Bool {
        switch kind(a) {
        case "click", "left_click", "double_click", "triple_click", "middle_click", "mouse_up", "navigate", "goto", "go_to",
             "open", "open_url", "launch", "menu", "menu_item", "ax", "secondary", "perform", "select", "choose",
             "wait_for", "waitfor":
            return true
        case "type", "type_text":
            return mayOpen(a)  // ends with Return
        case "fill":
            if let submit = a["submit"] as? Bool { return submit }
            return a["submit"] != nil
        case "keypress", "key", "press_key", "hotkey", "key_up", "keyup", "hold_key", "hold":
            let keys = Keys.sequence(a["keys"] ?? a["key"] ?? a["text"]).flatMap { $0 }.map(Keys.normalize)
            return keys.contains { ["return", "enter", "kpenter"].contains($0) || Keys.modifiers[$0] == .maskCommand }
        default:
            return false
        }
    }

    /// Whether action `a` may move the keyboard focus: keys and typing, a click, drag or press, focus,
    /// set_value, a pop-up's choice, a menu command (Find puts it in a search field), open, activate.
    nonisolated static func movesFocus(_ a: [String: Any]) -> Bool {
        let k = kind(a)
        return keyboardActions.contains(k) || [
            "click", "left_click", "double_click", "triple_click", "right_click", "middle_click", "mouse_down", "mouse_up",
            "drag", "left_click_drag", "focus", "set_value", "select", "choose", "menu", "menu_item", "ax", "secondary",
            "perform", "open", "open_url", "launch", "activate", "raise", "focus_window",
        ].contains(k)
    }

    /// Keys that, with shift, move one end of a selection.
    nonisolated static let selectionKeys: Set<String> = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown",
                                                         "prior", "next"]

    /// Whether action `a` selects text: a double or triple click (or a click counting 2 or 3), a shift-click, a
    /// drag, shift with an arrow, Home, End or a page key, cmd+a, the Select All menu command.
    nonisolated static func selects(_ a: [String: Any]) -> Bool {
        switch kind(a) {
        case "double_click", "triple_click", "drag", "left_click_drag":
            return true
        case "click", "left_click":
            if let n = num(a["count"] ?? a["clicks"]), n >= 2 { return true }
            return Keys.splitCombo(modifierKeys(a)).contains { Keys.normalize($0) == "shift" }
        case "keypress", "key", "press_key", "hotkey":
            return Keys.sequence(a["keys"] ?? a["key"] ?? a["text"]).contains { combo in
                let keys = combo.map(Keys.normalize)
                if keys.contains("shift"), keys.contains(where: { selectionKeys.contains($0) }) { return true }
                return keys.count == 2 && keys.contains("a") && keys.contains { Keys.modifiers[$0] == .maskCommand }
            }
        case "menu", "menu_item":
            return AX.menuPath(a["item"] ?? a["path"] ?? a["text"]).last.map { Policy.phrase($0) == "select all" } ?? false
        default:
            return false
        }
    }

    /// How much of a selection's text a reply shows.
    nonisolated static let selectedClip = 60

    /// What's selected (`text`, `count` characters long), as a reply says it: the text in quotes, on one line
    /// and clipped to `selectedClip` characters, then its length (`"…" (N chars)`, about 80 characters at
    /// most). With no text to show (the app gave only where it is), the length alone.
    nonisolated static func selectedText(_ text: String, count: Int) -> String {
        let n = "\(count) char" + (count == 1 ? "" : "s")
        let one = text.prefix(selectedClip * 4).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !one.isEmpty else { return "(\(n))" }
        return "\"" + (one.count > selectedClip ? String(one.prefix(selectedClip - 1)) + "…" : one) + "\" (\(n))"
    }

    /// After an act going by the outline whose outline didn't change: one frame of the window, against the
    /// batch's first (`start`, past a primer click's change of look). Why the window is shown after all
    /// (`outlineMissed`), or nil; and, when the text cursor only moved in its field, a note saying where to.
    static func outlineMissCheck(_ start: Baseline, _ t: Target, _ o: Opts) async -> (why: String?, note: String?) {
        guard let shot = try? await plan(t, region: nil, o).run(), shot.rect.width > 0, shot.rect.height > 0 else { return (nil, nil) }
        let sig = Signature(shot.image)
        guard let box = sig.diff(start.sig, outW: sig.w, outH: sig.h)?.box else { return (nil, nil) }
        let then = start.caretThen, now = then == nil ? nil : caret(t)
        if let then, let now, blinked(sig, from: start.sig, then: then, now: now, shot, t) { return (nil, nil) }
        var field: CGRect?  // the field the cursor stayed in, in the signature's cells
        if let then, let now, Caret.near(now.field, then.field) {
            let at = origin(t), sx = Double(sig.w) / shot.rect.width, sy = Double(sig.h) / shot.rect.height
            field = CGRect(x: (now.field.minX - (shot.rect.minX - at.x)) * sx, y: (now.field.minY - (shot.rect.minY - at.y)) * sy,
                           width: now.field.width * sx, height: now.field.height * sy)
        }
        if let why = outlineMissed(box: box, cursorField: field) { return (why, nil) }
        guard let then, let now, now.moved(from: then) else { return (nil, nil) }
        return (nil, "the text cursor moved: it's now \(now.at) characters into the text")
    }

    /// Whether an act going by the outline shows the window after all, though its outline didn't change, from
    /// the cells of its picture that differ from the batch's first frame (`box`, at the signature's size; nil
    /// when none do): not when they all lie in the text field the cursor stayed in (`cursorField`, in the same
    /// cells), which is the cursor moving (no outline shows it). Else the change is in something the outline
    /// leaves out (a display, a status text, a picture), and this says so.
    nonisolated static func outlineMissed(box: CGRect?, cursorField: CGRect?) -> String? {
        guard let box else { return nil }
        if let f = cursorField, f.insetBy(dx: -1, dy: -1).contains(box) { return nil }
        return "the window changed but its outline didn't (what changed isn't in it: a display or a status text, say)"
    }

    /// A window partly off screen (or across two displays) is captured only where it's on the display
    /// it's mostly on: the screenshot says so, or the agent reads a nearly blank picture as the page.
    static func partShown(_ t: Target, _ shot: Shot) -> String? {
        guard case .window(let w) = t, let f = Windows.info(w.id)?.frame, f.width > 0, f.height > 0 else { return nil }
        let shown = f.intersection(shot.rect)
        let part = shown.isNull ? 0 : shown.width * shown.height / (f.width * f.height)
        guard part < 0.9 else { return nil }
        return "only \(Int(part * 100))% of window #\(w.id) is in the screenshot: the rest is off screen (or on "
            + "another display). Elements there can still be reached by number or target"
    }

    /// Capture `t` once the UI has settled: re-capture until two consecutive frames match (ignoring tiny
    /// blips like a caret), for at most ~0.9 s. A window that opens over it meanwhile (a dialog, panel or
    /// popover), or the window moving, gets a new capture plan: the old one would leave it out. With
    /// `early`, frames that show no change from `before` take longer to count as settled (see `settle`).
    /// With what moved between its frames of one plan, nothing being done (`Motion`: what keeps moving by itself).
    static func settledShot(_ t: Target, _ o: Opts, early: Early? = nil) async throws -> (Shot, Signature, Motion) {
        var motion = Motion()
        let (shot, sig) = try await settle(basis: { PlanBasis.of(t) }, makePlan: { try await plan(t, region: nil, o) },
                                           capture: { try await $0.run() }, pause: { try await Task.sleep(nanoseconds: 150_000_000) },
                                           early: early, moved: { motion.add($0, $1) })
        return (shot, sig, motion)
    }

    /// `act`'s early end, for `settle`.
    final class Early {
        /// What the agent last saw (nil: nothing, so any still frames are the answer).
        let before: Signature?
        /// When the wait used to take its first frame: all of settle_ms after the menu check (by `clock`).
        let start: Double
        /// A pause of a given length (s), to take a frame right when the wait used to take its second.
        let wait: (Double) async throws -> Void
        /// Set by `settle`: when the wait used to end at the soonest (its second frame taken), which is when
        /// `act` used to look for a new window a second time.
        var lookedAgain = 0.0

        init(before: Signature?, start: Double, wait: @escaping (Double) async throws -> Void) {
            (self.before, self.start, self.wait) = (before, start, wait)
        }
    }

    /// `settledShot`'s loop, apart from the screen (unit-tested). Before each capture `basis` is read
    /// again, and if it changed, `makePlan` makes a new plan. The shot and signature returned come from
    /// the same plan, so the image, its change box and its coordinate mapping agree.
    /// With `early` (`act`): matching frames that both show a change from `before` end the loop as ever.
    /// Ones that don't (they look like it, a caret aside) end it only from when the loop used to take its
    /// second frame: `start`, plus what this first plan and capture took, plus 0.15 s. Until then it keeps
    /// looking, past the usual seven frames if need be, with a frame timed to land right then (the pause
    /// before it stretched to at most 0.3 s). So "no visible change", or a frame only a caret tells from
    /// `before`, comes no sooner than it did. `moved` gets each two frames in a row of one plan (not across a
    /// new plan): what differs between them moved by itself (`Motion`).
    static func settle<Plan, Basis: Equatable>(
        basis: () -> Basis, makePlan: () async throws -> Plan, capture: (Plan) async throws -> Shot,
        pause: () async throws -> Void, early: Early? = nil, moved: (Signature, Signature) -> Void = { _, _ in },
        clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> (Shot, Signature) {
        let began = clock()
        var madeFor = basis()  // read before planning: what changes while the plan is made shows up next time
        var plan = try await makePlan()
        let shotAt = clock()
        var shot = try await capture(plan)
        var sig = Signature(shot.image)
        let floor = early.map { $0.start + (clock() - began) + 0.15 } ?? 0
        early?.lookedAgain = floor + (clock() - shotAt)  // and its second frame captured
        let shows = { (s: Signature) in early.map { showsChange(s, from: $0.before) } ?? true }
        var frames = 1, at = began
        while frames < 7 || (at < floor && !shows(sig)) {
            // Waiting for the floor: a frame right on it, not one just before it and the next well after.
            let left = floor - clock()
            if let early, left > 0, !shows(sig) { try await early.wait(left <= 0.3 ? left : 0.15) } else { try await pause() }
            frames += 1
            let now = basis()
            let replanned = now != madeFor
            if replanned {
                guard let fresh = try? await makePlan() else { break }
                (plan, madeFor) = (fresh, now)
            }
            let taken = clock()
            guard let next = try? await capture(plan) else { break }
            let nsig = Signature(next.image)
            if !replanned { moved(sig, nsig) }
            let new = shows(sig) && shows(nsig)
            let held = still(sig, nsig)
            (shot, sig, at) = (next, nsig, taken)
            // Settled: two matching frames of one plan, with nothing opening or closing over the window
            // meanwhile (a sheet's window comes a moment before it's drawn).
            if !replanned, held, basis() == madeFor, new || taken >= floor - 0.001 { break }
        }
        return (shot, sig)
    }

    /// Two frames that match, but for tiny blips like a caret.
    nonisolated static func still(_ a: Signature, _ b: Signature) -> Bool {
        a.diff(b, outW: b.w, outH: b.h).map { $0.fraction < 0.002 } ?? true
    }

    /// A frame that shows a change from `before` (nil: there's nothing to compare with), more than a caret
    /// blinking in a text field: a change in a sliver at most 3 of the signature's cells wide doesn't count
    /// (`act` still calls it a change; the early end just doesn't take it for the action's effect).
    nonisolated static func showsChange(_ s: Signature, from before: Signature?) -> Bool {
        guard let before else { return true }
        guard let d = s.diff(before, outW: s.w, outH: s.h) else { return false }
        return d.box.width > 3
    }

    /// Where `act` waits all of settle_ms after its menu check and takes the first frames that match, as it
    /// always did: web pages (the early end isn't measured there yet) and the screen. Web pages are browsers,
    /// Electron and other Chromium apps, Gecko apps, and any window showing one in a system web view (a mail
    /// message, an app built on a web view).
    static func waitsInFull(_ t: Target) -> Bool {
        guard case .window(let w) = t else { return true }
        if isBrowser(w.pid) || Windows.isChromium(w.pid) || Windows.isGecko(w.pid) { return true }
        return showsWebPage(w.id) { AX.window(pid: w.pid, wid: w.id).flatMap { AX.webArea($0) } != nil }
    }

    /// Windows found to show a web page or not (`showsWebPage`), and when.
    static var webPages: [CGWindowID: (web: Bool, at: Double)] = [:]
    /// A window found with no web page is looked at again after this long (s): one can open in it later.
    static let webRecheck = 30.0

    /// Whether window `wid` shows a web page: `look` (a walk of its accessibility tree), then what it found,
    /// so an act doesn't walk the window each time. Yes is kept. No is looked at again after `webRecheck`
    /// s, and the first no at the next act: a web view may build its accessibility tree only once asked.
    static func showsWebPage(_ wid: CGWindowID, now: Double = ProcessInfo.processInfo.systemUptime,
                             look: () -> Bool) -> Bool {
        let seen = webPages[wid]
        if let seen, seen.web || now - seen.at < webRecheck { return seen.web }
        let began = ProcessInfo.processInfo.systemUptime
        let web = look()
        if Trace.on { Trace.log(["k": "webpage", "ms": (ProcessInfo.processInfo.systemUptime - began) * 1000, "web": web]) }
        webPages[wid] = (web, web || seen != nil ? now : -.infinity)
        return web
    }

    /// After these a window may open a moment later (a document a double-click opens, a dialog Return or a
    /// shortcut brings up, a menu command's), so after an early end `act` keeps looking for one until the
    /// wait used to look again (`watchForWindow`). Not after single clicks, typing, scrolls or selects.
    nonisolated static func opensWindow(_ a: [String: Any]?) -> Bool {
        guard let a else { return false }
        let keys: [String]
        switch kind(a) {
        case "double_click", "menu", "menu_item": return true
        case "click", "left_click", "right_click", "middle_click":
            return a["item"] != nil || (a["count"] ?? a["clicks"]) as? Int == 2  // a menu command, or a double-click
        case "type", "type_text": return mayOpen(a)  // ends with Return
        case "fill": return a["submit"] as? Bool == true  // Return
        case "keypress", "key", "press_key", "hotkey", "key_up", "keyup", "hold_key", "hold":
            keys = Keys.sequence(a["keys"] ?? a["key"] ?? a["text"]).flatMap { $0 }.map(Keys.normalize)
        default: return false
        }
        return keys.contains { ["return", "enter", "kpenter"].contains($0) || Keys.modifiers[$0] == .maskCommand }
    }

    /// After an early end: until `until` (by `clock`), when the wait used to look for a new window a second
    /// time, `look` for one (it follows it) after each `pause`. Whether one turned up.
    static func watchForWindow(until: Double, look: () async -> Bool, pause: () async throws -> Void,
                               clock: () -> Double = { ProcessInfo.processInfo.systemUptime }) async throws -> Bool {
        while clock() < until {
            try await pause()
            if await look() { return true }
        }
        return false
    }

    /// Trace only, where `act` waits in full: the frame its early end would have returned now, if it would
    /// have ended at its second frame (two frames 0.15 s apart that match and both show a change from `before`).
    static func earlyFrame(_ t: Target, _ o: Opts, before: Signature?) async -> Signature? {
        let basis = PlanBasis.of(t)
        guard let p = try? await plan(t, region: nil, o), let a = try? await p.run() else { return nil }
        await Input.sleep(0.15)
        guard let b = try? await p.run(), PlanBasis.of(t) == basis else { return nil }
        let (sa, sb) = (Signature(a.image), Signature(b.image))
        return still(sa, sb) && showsChange(sa, from: before) && showsChange(sb, from: before) ? sb : nil
    }

    /// A window that appeared in `w`'s app during a batch: a browser window from cmd+n, a dialog, a
    /// settings window. Sheets and popovers drawn over `w` don't count (they're captured with it). With a
    /// `box`, windows the batch created are shrunk to it (points), so the screenshot fits the token cap at a readable scale
    /// whatever the display's pixel density. `arrange` (`Run.arrange`) says whether it may be shrunk and moved,
    /// and whether it's switched to at all (`followed`): not when the user may have opened it, which is noted.
    static func follow(_ w: WinInfo, visibleBefore: Set<CGWindowID>, existedBefore: Set<CGWindowID>, box: CGSize?,
                       arrange: (fit: Bool, place: Bool, follow: Bool, users: Bool) = (true, true, true, false)) async
        -> (window: WinInfo, followed: Bool)? {
        let parent = Windows.info(w.id)?.frame ?? w.frame
        let fresh = Windows.all(onScreenOnly: true).filter {
            $0.pid == w.pid && $0.layer == 0 && !visibleBefore.contains($0.id)
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }
        guard let nw = fresh.first(where: { c in
            let el = AX.window(pid: c.pid, wid: c.id)
            let subrole = el.flatMap { AX.value($0, kAXSubroleAttribute) as? String }
            guard parent.contains(c.frame) else { return !systemWindow(c, el) }
            return subrole == "AXStandardWindow"
        }) else { return nil }
        guard arrange.follow else {  // it may be the user's: left as it is, and not taken over
            notes.append(Run.notFollowedNote(id: nw.id, title: nw.title, app: nw.app))
            return (nw, false)
        }
        var note = "now on new window #\(nw.id)"
        if arrange.users, !existedBefore.contains(nw.id) { note += Run.leftAloneNote(nw.frame.size, box: box) }
        if let box, arrange.fit, !existedBefore.contains(nw.id), AX.fit(pid: nw.pid, wid: nw.id, box: box) {
            // Until it's that size, and has had a moment to lay out at it (0.3 s at most).
            let size = CGSize(width: min(nw.frame.width, box.width), height: min(nw.frame.height, box.height))
            if let f = try? await Run.resized(to: size, floor: 0.05, frame: { Windows.info(nw.id)?.frame }) {
                note += ", sized to \(Int(f.width))x\(Int(f.height)) pt"
            }
        }
        notes.append(note)
        if arrange.place, !existedBefore.contains(nw.id), let to = Run.placeOnScreen(nw) {
            try? await Run.placed(nw.id, at: to)
        }
        return (Windows.info(nw.id) ?? nw, true)
    }

    /// macOS's own bits shown in the app's name, not the app's: the dictation orb is an untitled "dialog"
    /// holding one control. An app's alert has its text and buttons, or is modal. `el`, the window's
    /// accessibility element, is only looked up for an untitled window.
    static func systemWindow(_ w: WinInfo, _ el: @autoclosure () -> AXUIElement?) -> Bool {
        systemWindow(w, facts: {
            el().map { (AX.value($0, kAXSubroleAttribute) as? String, AX.value($0, "AXModal") as? Bool == true, AX.children($0).count) }
        })
    }

    /// The same, given an untitled window's subrole, modal flag and number of children (`facts`; nil: it has
    /// no accessibility element).
    static func systemWindow(_ w: WinInfo, facts: () -> (subrole: String?, modal: Bool, children: Int)?) -> Bool {
        guard w.title.isEmpty, let f = facts() else { return false }
        return systemWindow(subrole: f.subrole, modal: f.modal, children: f.children)
    }

    nonisolated static func systemWindow(subrole: String?, modal: Bool, children: Int) -> Bool {
        subrole != "AXStandardWindow" && !modal && children <= 1
    }
}

/// The target app stays AppKit-active between act calls, so a menu or popover opened by one call is still
/// open for the next, and its window chrome doesn't flip between active and inactive looks (which would
/// read as a visible change). Released on `release`, when the session moves to another app (unless
/// another session is using it), or when idle.
///
/// Once the user brings the held app to the front it is really active, so the hold is dropped and the
/// app is never told it's inactive: AppKit would then believe that while the WindowServer keeps it
/// frontmost, and Firefox drops every click and drag-select in that state until the user switches apps.
/// puter-use's own moment of bringing it forward to redraw a window (`Handlers.flash`) keeps the hold: it's
/// sent again once the user's app is back in front (`restore`).
@MainActor
enum Hold {
    static var held: [pid_t: CGWindowID] = [:]
    static var lastUse: [pid_t: Date] = [:]
    /// Held since this batch, not before: the app's first click after it's told it's active is still an
    /// activation click (Firefox drops it), so the primer spends one even though its window is key.
    static var fresh = Set<pid_t>()
    static let idle: TimeInterval = 120
    private static var timer: Timer?
    private static var observer: NSObjectProtocol?

    /// Really frontmost (WindowServer), not just AppKit-active.
    static func isFront(_ pid: pid_t) -> Bool {
        SkyLight.isFrontProcess(pid) ?? (NSRunningApplication(processIdentifier: pid)?.isActive == true)
    }

    /// Held on `wid` since an earlier call, so the app has long taken the activation record: `act` doesn't
    /// wait after sending it again. Not on a fresh hold (the app may have just been told it's active), nor
    /// when the hold is on another of its windows.
    static func heldSettled(pid: pid_t, wid: CGWindowID) -> Bool {
        held[pid] == wid && !fresh.contains(pid)
    }

    /// A request of the session came in: its apps aren't idle.
    static func touch() {
        for pid in Session.current.holding { lastUse[pid] = Date() }
    }

    /// Apps puter-use brings forward for a moment (`Handlers.flash`), with until when (system uptime) their notices of
    /// coming forward are its own rather than the user's: a hold on one isn't dropped for them (`restore` sends it
    /// again).
    static var flashing: [pid_t: TimeInterval] = [:]

    /// Whether `pid` coming forward now is puter-use's own doing (`flashing`).
    static func ownActivation(_ pid: pid_t) -> Bool {
        (flashing[pid] ?? 0) > ProcessInfo.processInfo.systemUptime
    }

    /// After `pid` was brought forward for a moment and the user's app brought back (`Handlers.flash`): really told
    /// it's inactive as that came back, so a hold on it is sent again, as a new one (its next click is an activation
    /// click again). Dropped if it can't be, or if `pid` is still in front (the user's app didn't come back): then
    /// it's as if the user had brought it forward.
    static func restore(_ pid: pid_t) {
        guard let wid = held[pid] else { return }
        if !isFront(pid), SkyLight.setAppKitActive(pid: pid, wid: wid, true) {
            fresh.insert(pid)
            lastUse[pid] = Date()
        } else {
            forget(pid)
        }
    }

    static func activate(pid: pid_t, wid: CGWindowID) -> Bool {
        let me = Session.current
        for other in me.holding where other != pid { drop(other, from: me) }
        guard SkyLight.setAppKitActive(pid: pid, wid: wid, true) else { return false }
        if held[pid] == nil { fresh.insert(pid) }
        held[pid] = wid
        me.holding.insert(pid)
        lastUse[pid] = Date()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                MainActor.assumeIsolated {
                    for (pid, t) in lastUse where Date().timeIntervalSince(t) > idle { release(pid) }
                    Session.sweep()
                }
            }
        }
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid, held[pid] != nil, !ownActivation(pid) { forget(pid) } }
            }
        }
        return true
    }

    /// The session is done with `pid`: let it go unless another session still uses it.
    private static func drop(_ pid: pid_t, from s: Session) {
        s.holding.remove(pid)
        if !Session.all.values.contains(where: { $0.holding.contains(pid) }) { release(pid) }
    }

    static func release(for s: Session) {
        for pid in s.holding { drop(pid, from: s) }
    }

    static func release(_ pid: pid_t) {
        if let wid = held[pid], !isFront(pid) { SkyLight.setAppKitActive(pid: pid, wid: wid, false) }
        forget(pid)
    }

    /// No longer ours to release (the user brought it forward, or it's released).
    private static func forget(_ pid: pid_t) {
        held[pid] = nil
        fresh.remove(pid)
        lastUse[pid] = nil
        for s in Session.all.values { s.holding.remove(pid) }
    }

    static func releaseAll() {
        for pid in Array(held.keys) { release(pid) }
    }
}
