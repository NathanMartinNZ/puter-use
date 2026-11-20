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

/// What the agent's coordinates mean for a target: the last full screenshot it was shown.
struct Meta {
    var offset: CGPoint  // capture origin relative to the window origin (points)
    var size: CGSize  // captured area (points)
    var width: Int  // screenshot pixels
    var height: Int
    var sig: Signature
    var caret: Caret? = nil  // the text cursor then: a later frame that differs only by its blinking hasn't changed
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
            return ["id": id, "ok": true, "result": result]
        } catch {
            if error is Cancelled || Connection.hungUp { return nil }
            return ["id": id, "ok": false, "error": "\(error)"]
        }
    }

    static func encode(_ obj: [String: Any]) -> Data {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: []) { return d }
        let id = (obj["id"] as? Int).map(String.init) ?? "null"
        return Data("{\"id\":\(id),\"ok\":false,\"error\":\"the reply couldn't be encoded\"}".utf8)
    }

    // MARK: - params

    nonisolated static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
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
            guard let w = Windows.info(cur) else { throw HelperError("window \(cur) no longer exists" + appWindows(cur)) }
            return used(w)
        }
        if let n = num(v), !(v is String && Int(v as! String) == nil) {
            // An id no window can have (negative, fractional, past UInt32) is not found either.
            guard let id = CGWindowID(exactly: n), let w = Windows.info(id) else {
                throw HelperError("window \(Int(exactly: n).map(String.init) ?? "\(n)") not found"
                    + (CGWindowID(exactly: n).map(appWindows) ?? ""))
            }
            return used(w)
        }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else {
            throw HelperError("bad window value")
        }
        if s.lowercased() == "screen" { return .screen }
        let wins = Windows.targetable(app: s)
        let system = { (w: WinInfo) in systemWindow(w, AX.window(pid: w.pid, wid: w.id)) }  // the dictation orb
        if let hit = appWindow(wins, query: s, current: current, own: Session.current.ownRecent,
                               noted: Session.current.pickNoted, system: system) {
            if let note = hit.note { Connection.current?.windowNote = note }
            return used(hit.window)
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
    static func appWindow(_ wins: [WinInfo], query: String, current: CGWindowID?, own: [CGWindowID],
                          noted: Set<[CGWindowID]>, system: (WinInfo) -> Bool = { _ in false })
        -> (window: WinInfo, note: (text: String, pair: [CGWindowID])?)? {
        guard case let (w, why)? = pick(wins, current: current, own: own, system: system) else { return nil }
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

    /// A window the session works on: its app is remembered, for when it's gone.
    static func used(_ w: WinInfo) -> Target {
        Session.current.windowApps[w.id] = (w.app, w.pid)
        if Session.current.agentWindows.contains(w.id) {  // its own: the one an app name means next
            Session.current.ownRecent.removeAll { $0 == w.id }
            Session.current.ownRecent.append(w.id)
        }
        return .window(w)
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
        let wins: [WinInfo]
        if let app, p["launch"] as? Bool == true {
            // Not shrunk to the window box: an app may restore the user's last session as it launches.
            wins = try await Windows.launch(app)
        } else {
            wins = Windows.targetable(app: app)
        }
        // Apps the policy keeps agents out of aren't listed (their window titles are theirs too).
        var kept: [String] = []
        let listed = wins.compactMap { w -> [String: Any]? in
            var j = w.json
            let l = Policy.level(w.pid)
            if l == .deny {
                if !kept.contains(w.app) { kept.append(w.app) }
                return nil
            }
            if systemWindow(w, AX.window(pid: w.pid, wid: w.id)) { return nil }  // macOS's dictation orb, not the app's
            if l != .full { j["policy"] = l.rawValue }
            return j
        }
        var out: [String: Any] = ["windows": listed, "permissions": Permissions.status()]
        var notes: [String] = []
        if !kept.isEmpty { notes.append("not listed: \(kept.joined(separator: ", ")) (puter-use's policy keeps agents out)") }
        if let problem = Policy.config.problem { notes.append("policy: \(problem)") }
        if !notes.isEmpty { out["notes"] = notes }
        return out
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
        init(_ p: [String: Any]) {
            interactive = p["interactive"] as? Bool == true
            maxChars = max(500, min(Handlers.int(p["max_chars"], maxChars), 40_000))
            marks = p["marks"] as? Bool == true
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
        guard x >= 0, y >= 0, x <= Double(m.width), y <= Double(m.height) else {
            throw HelperError("(\(Int(x)),\(Int(y))) is outside the \(m.width)x\(m.height) screenshot")
        }
        let o = origin(t)
        return CGPoint(x: o.x + m.offset.x + x * m.size.width / Double(m.width),
                       y: o.y + m.offset.y + y * m.size.height / Double(m.height))
    }

    static func toPixels(_ t: Target, _ p: CGPoint) -> [Int]? {
        guard let m = meta[t.key] else { return nil }
        let o = origin(t)
        return [Int(((p.x - o.x - m.offset.x) * Double(m.width) / m.size.width).rounded()),
                Int(((p.y - o.y - m.offset.y) * Double(m.height) / m.size.height).rounded())]
    }

    static func remember(_ t: Target, _ shot: Shot, _ sig: Signature) {
        let o = origin(t)
        let start = AX.uptime(), cursor = caret(t)
        if Trace.on, case .window = t {
            Trace.log(["k": "caret", "ms": ((AX.uptime() - start) * 10_000).rounded() / 10, "found": cursor != nil])
        }
        meta[t.key] = Meta(offset: CGPoint(x: shot.rect.minX - o.x, y: shot.rect.minY - o.y), size: shot.rect.size,
                           width: shot.image.width, height: shot.image.height, sig: sig, caret: cursor)
        Run.look(t)
    }

    /// How long one question about the cursor waits for the app: it's asked with every picture, and an app
    /// too slow to answer only loses the blink rule (its cursor blinking counts as a change, as it used to).
    static let caretTimeout: Float = 0.3

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

    static func describe(_ t: Target) -> [String: Any] {
        switch t {
        case .window(let w):
            let fresh = Windows.info(w.id) ?? w
            return ["id": Int(w.id), "app": fresh.app, "title": fresh.title, "on_screen": fresh.onScreen]
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
        if readRequested(p["read"]) { return try readText(t, p["read"]!, p) }  // one element's whole text: ReadText.swift
        let o = Opts(p)
        var region: CGRect?
        if let r = p["region"] as? [Any], r.count == 4, let x0 = num(r[0]), let y0 = num(r[1]),
           let x1 = num(r[2]), let y1 = num(r[3])
        {
            let a = try toGlobal(t, min(x0, x1), min(y0, y1)), b = try toGlobal(t, max(x0, x1), max(y0, y1))
            region = CGRect(x: a.x, y: a.y, width: max(1, b.x - a.x), height: max(1, b.y - a.y))
        }
        if p["image"] as? Bool == false {  // accessibility text only: the cheapest way to look
            var out: [String: Any] = ["window": describe(t)]
            if let region, case .window(let w) = t {  // just the words in that area
                var text = AX.text(pid: w.pid, wid: w.id, within: region)
                if text == nil || text == "(no text in that area)" {  // nothing exposed there: read the pixels
                    let lines = try await OCR.read(try await sharpShot(t, region: region))
                    if !lines.isEmpty { text = "(read off the screen)\n" + OCR.text(lines) }
                }
                out["text"] = text ?? "(no text in that area)"
                return out
            }
            AppCards.enabled = p["app_cards"] as? Bool != false
            if case .window(let w) = t, let card = AppCards.card(pid: w.pid) { out["card"] = card }
            return out.merging(accessibility(t, o)) { _, new in new }
        }
        let shot = try await plan(t, region: region, o).run()
        var out = try await result(t, shot, o, zoom: region != nil, text: p["text"] as? Bool == true)
        if region == nil, let note = partShown(t, shot) { out["notes"] = [note] }
        out["changed"] = true
        AppCards.enabled = p["app_cards"] as? Bool != false
        if case .window(let w) = t, let card = AppCards.card(pid: w.pid) { out["card"] = card }
        return out
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
             "mouse_down", "focus", "set_value", "screenshot", "clipboard", "paste":
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

    enum Ending { case status, firstLook, settled }

    /// What an act returns at its end: no image with screenshot "never", or when nothing ran (the error
    /// alone; a stop shows the window, though). But on a first look whose first action failed, the window
    /// it was going to be shown anyway, so the agent can aim from it. Else a settled screenshot if it changed,
    /// as when the batch moved to a new window (`moved`, then failed): that one is the agent's now.
    nonisolated static func ending(wantShot: Bool, always: Bool, done: Int, stopped: Bool, failed: Bool,
                                   firstLook: Bool, moved: Bool = false) -> Ending {
        guard wantShot else { return .status }
        if done > 0 || always || stopped || moved { return .settled }
        return firstLook && failed ? .firstLook : .status
    }

    nonisolated static let keyboardActions: Set<String> = [
        "type", "type_text", "keypress", "key", "press_key", "hotkey", "key_down", "keydown", "key_up", "keyup",
        "hold_key", "hold", "fill", "navigate", "goto", "go_to", "paste",
    ]

    /// Actions that act on the app's keyboard focus: keys (including the modifiers a click or drag holds)
    /// and menu commands, which act on the focused window. That window has to be the app's key one first.
    enum KeyPrimer: Equatable { case none, fromAgentWindow, freshHold }

    /// Whether a keyboard act on a held background app spends a click on its window, given the window AX
    /// says has the app's keyboard. Another of the agent's own windows: forced, at the start, to move it here.
    /// None, or this one, on a new hold (`Hold.fresh`): AX still names the window, but AppKit has no key
    /// window, so key equivalents go nowhere; that click waits for the first key (`primeKeys`). A window of
    /// the user's: never (guardKeyboard stops the keys instead).
    nonisolated static func keyPrimer(focused: CGWindowID?, wid: CGWindowID, fresh: Bool,
                                      agentWindows: Set<CGWindowID>) -> KeyPrimer {
        if let focused, focused != wid { return agentWindows.contains(focused) ? .fromAgentWindow : .none }
        return fresh ? .freshHold : .none
    }

    /// Whether keys or a menu command going to `r` now need a new hold's click first (see `primeKeys`).
    static func keysNeedPrimer(_ r: Route) -> Bool {
        guard !r.foreground, r.primer, r.wid != 0, Hold.held[r.pid] == r.wid, Hold.fresh.contains(r.pid) else { return false }
        return keyPrimer(focused: AX.focusedWindow(pid: r.pid), wid: r.wid, fresh: true, agentWindows: agentWindows) == .freshHold
    }

    /// On a new hold, the primer's click makes the window key, just before the first key or menu command
    /// goes out: after that action's checks (policy, confirm, guardKeyboard), so a batch that stops before
    /// any key clicks nothing. Once per hold: the click ends `Hold.fresh`.
    static func primeKeys(_ r: Route) async {
        guard keysNeedPrimer(r) else { return }
        await Input.primer(r)
        await Input.afterPrimer()
    }

    /// Thrown by a menu command's check on a new hold, so its click goes after the check and before the press.
    struct PrimeFirst: Error {}

    nonisolated static func actsOnKeyboardFocus(_ a: [String: Any]) -> Bool {
        if keyboardActions.contains(kind(a)) || kind(a) == "menu" || kind(a) == "menu_item" { return true }
        guard a["keys"] != nil || a["modifiers"] != nil else { return false }
        return ["click", "double_click", "triple_click", "right_click", "middle_click", "mouse_down", "drag"].contains(kind(a))
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
    /// an earlier outline of this window that this session was sent (of the same kind: interactive or
    /// not), just what changed since (when that's shorter).
    static func accessibility(_ t: Target, _ o: Opts = Opts([:]), within: CGRect? = nil, diff: Bool = false) -> [String: Any] {
        var out: [String: Any] = [:]
        if within == nil, let pid = pid(t), let f = AX.focusedSummary(pid: pid, wid: t.key) { out["focused"] = f }
        if case .window(let w) = t {
            let full = AX.outline(pid: w.pid, wid: w.id, within: within, maxChars: o.maxChars, interactive: o.interactive)
            out["text"] = full.map { $0.isEmpty ? (o.interactive
                ? "(no interactive elements in this window; try text: true, or find)"
                : "(no accessibility elements in this window)") : $0 } ?? "(no accessibility tree for this window)"
            if full != nil, within == nil, let reg = AX.registries[w.id] {
                if reg.cutShort {
                    // Only part of the window: sent whole (a diff would list the rest as gone), and not kept to
                    // diff the next one against (it would list the rest as new).
                    Session.current.outlines[w.id] = nil
                } else {
                    if diff, let sent = Session.current.outlines[w.id], sent.interactive == o.interactive,
                       let changes = outlineChanges(sent.lines, reg.lines) {
                        out["text"] = changes
                    }
                    Session.current.outlines[w.id] = (o.interactive, reg.lines)
                }
            }
        }
        return out
    }

    /// What changed between an outline the agent was sent and the window's latest, or nil if the change
    /// is most of it (then the whole outline reads better).
    static func outlineChanges(_ old: [(Int, String)], _ lines: [(Int, String)]) -> String? {
        let before = Dictionary(old, uniquingKeysWith: { a, _ in a })
        let now = Dictionary(lines, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for (id, line) in lines where before[id] != line { out.append((before[id] == nil ? "+ " : "~ ") + line) }
        for (id, line) in old where now[id] == nil { out.append("- " + line) }
        if out.isEmpty { return "outline: nothing changed since your last outline (\(now.count) elements)" }
        guard out.count * 2 <= max(now.count, 4) else { return nil }
        let same = lines.filter { before[$0.0] == $0.1 }.count
        return "outline changes since your last outline (+ new, ~ changed, - gone; the \(same) unchanged elements keep their numbers):\n"
            + out.joined(separator: "\n")
    }

    static func result(_ t: Target, _ shot: Shot, _ o: Opts, zoom: Bool, text: Bool, diff: Bool = false) async throws -> [String: Any] {
        let sig = Signature(shot.image)
        if !zoom { remember(t, shot, sig) }
        var acc: [String: Any] = [:]
        if text { acc = accessibility(t, o, within: zoom ? shot.rect : nil, diff: diff) }
        var image = shot.image
        if o.marks, case .window(let w) = t {
            // Number what can be acted on (this outline isn't sent). Not when the outline just sent ran out of
            // time: this would too; its numbers are marked.
            if !text || !o.interactive, !(text && AX.registry(w.id).cutShort) {
                _ = AX.outline(pid: w.pid, wid: w.id, within: zoom ? shot.rect : nil, maxChars: 40_000, interactive: true)
            }
            let reg = AX.registry(w.id)
            let marks = reg.lines.compactMap { entry -> Marks.Mark? in
                guard let n = reg.nodes[entry.0], let f = n.frame, AX.actionable.contains(n.role) else { return nil }
                return Marks.Mark(id: entry.0, rect: f)
            }
            image = Marks.draw(shot, marks)
        }
        let (data, mime) = Capture.encode(image, format: o.format, quality: o.quality, maxBytes: o.maxBytes)
        var out: [String: Any] = [
            "image": data.base64EncodedString(), "mime": mime, "width": shot.image.width,
            "height": shot.image.height, "zoom": zoom, "window": describe(t),
        ]
        out.merge(acc) { _, new in new }
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
    /// the element, run before it's scrolled into view (a stop for the user's OK leaves everything as it was).
    static func actionPoint(_ a: [String: Any], _ t: Target, required: Bool = true,
                            vet: ((AX.Node) throws -> Void)? = nil) async throws -> (CGPoint, AX.Node?)? {
        // The element a compound action (type, fill) has just looked up and checked (internal `_node`): that
        // one, not a second search that could find another on a page that re-rendered.
        if let n = a["_node"] as? AX.Node {
            try reachable(n.element, aimName(a))
            return try await aimAt(n, aimName(a), vet: vet)
        }
        if let idx = num(a["element"]), case .window(let w) = t {
            let n = try numbered(w, Int(idx), t)
            try reachable(n.element, "element \(Int(idx))")
            return try await aimAt(n, "element \(Int(idx))", vet: vet)
        }
        if let v = a["target"] {
            // A macro step names what it pressed and where it was: see Macros.spot.
            let saved = a["units"] as? String == "pt" ? num(a["x"]).flatMap { x in num(a["y"]).map { (x, $0) } } : nil
            if let (x, y) = saved, a["spot"] as? Bool == true {
                if let (p, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a), strict: true) { return (p, n) }
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
                    if let (p, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a)) { return (p, n) }
                    throw HelperError("\(error) (a macro step: what it pressed isn't where it was, so nothing was pressed)")
                }
                guard let miss = error as? NotFound else { throw error }
                do { return (try await readOffScreen(v, t), nil) } catch let e as HelperError where !miss.hint.isEmpty {
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
        let flags = modifierFlags(a["keys"] ?? a["modifiers"])
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
            guard let (aimed, node) = try await actionPoint(a, t, vet: { try clickChecks(a, $0, button: pressed) }) else { return }
            var p = aimed
            var r = try route(t, at: p, foreground: foreground)
            if !flags.isEmpty { try guardKeyboard(r) }  // its modifiers go to whichever window has the keyboard
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
            // A pop-up's item is chosen through accessibility (see popUpButton).
            if let item = a["item"], AX.menuPath(item).count == 1, button == "left", count == 1, allFlags.isEmpty,
               !foreground, let popup = popUpButton(node?.element ?? AX.element(pid: r.pid, at: p)) {
                let want = AX.menuPath(item)[0]
                if let match = AX.optionTitle(popup, want) { try Policy.checkItem(a, match) }
                await pointer.move(to: p, r)
                await Input.sleep(clickTiming.aim())
                pointer.click()
                let chose = try await AX.choose(popup, want, menuLater: a["_last"] as? Bool == true) { try Policy.checkItem(a, $0) }
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
            if let (button, r, _) = run.heldButton {  // a button is down: this is a drag
                await pointer.move(to: p, r, button: button)
            } else {
                await pointer.move(to: p, try route(t, at: p, foreground: foreground))
            }
        case "mouse_down":
            let button = (a["button"] as? String)?.lowercased() ?? "left"
            var p: CGPoint
            var node: AX.Node?
            let vet: (AX.Node) throws -> Void = { n in
                if button == "left" { try Policy.checkPress(a, node: n, at: nil, pid: AX.pidOf(n.element) ?? 0) }
            }
            if let (q, n) = try await actionPoint(a, t, required: false, vet: vet) { (p, node) = (q, n) } else {
                guard let tip = pointer.tip else { throw HelperError("mouse_down needs x,y or element") }
                p = tip
            }
            let r = try route(t, at: p, foreground: foreground)
            if button == "left" { try Policy.checkPress(a, node: node, at: p, pid: r.pid) }
            if foreground { prepareForeground(r) }
            await Input.primer(r)
            await pointer.move(to: p, r)
            await Input.sleep(clickTiming.aim())
            await Input.afterPrimer()  // its keys and button go down next
            // Its keys stay down with the button, as a hand holds shift through a shift-drag.
            if !Keys.splitCombo(a["keys"] ?? a["modifiers"]).isEmpty { try guardKeyboard(r) }
            for k in Keys.splitCombo(a["keys"] ?? a["modifiers"]) where !run.heldKeys.contains(where: { $0.name == Keys.normalize(k) }) {
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
            if !flags.isEmpty { try guardKeyboard(r) }  // its modifiers go to whichever window has the keyboard
            let button = (a["button"] as? String) ?? "left"
            // Down and up on a button presses it, as a click would.
            if button == "left" { try Policy.checkPress(a, node: nil, at: pts[0], pid: r.pid) }
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
            } else if case .window(let w) = t,
                meta[t.key] == nil || a["units"] as? String == "pt" {  // the middle of the window
                let f = Windows.info(w.id)?.frame ?? w.frame
                p = CGPoint(x: f.midX, y: f.midY)
            } else {
                guard let m = meta[t.key] else { throw HelperError("take a screenshot first") }
                p = try toGlobal(t, Double(m.width) / 2, Double(m.height) / 2)
            }
            let m = meta[t.key]
            let ptPerPx = a["units"] as? String == "pt" ? 1 : m.map { $0.size.width / Double($0.width) } ?? 1
            var dx = num(a["scroll_x"] ?? a["dx"]) ?? 0, dy = num(a["scroll_y"] ?? a["dy"]) ?? 0
            if let dir = a["direction"] as? String ?? a["scroll_direction"] as? String {  // Anthropic-style
                let amt = (num(a["amount"] ?? a["scroll_amount"]) ?? 3) * 100
                switch dir { case "up": dy = -amt; case "down": dy = amt; case "left": dx = -amt; default: dx = amt }
            }
            let r = try route(t, at: p, foreground: foreground)
            await pointer.move(to: p, r)
            // A scroll that runs into the end stops there (see ScrollWatch), and says so.
            let watch = ScrollWatch(pid: r.pid, at: p, within: r.frame, dx: dx * ptPerPx, dy: dy * ptPerPx)
            let sent = await Input.scroll(p, dx: dx * ptPerPx, dy: dy * ptPerPx, r, watch: watch)
            if watch.stopped {
                let (asked, went) = watch.vertical ? (abs(dy), abs(sent.y) / ptPerPx) : (abs(dx), abs(sent.x) / ptPerPx)
                notes.append("the scroll reached the end after about \(Int(went.rounded())) of \(Int(asked.rounded())); "
                    + "the rest wasn't sent")
            }
        case "type", "type_text":
            guard let text = a["text"] as? String ?? a["value"] as? String else { throw HelperError("type needs text") }
            if a["element"] != nil || a["target"] != nil || a["x"] != nil || a["coordinate"] != nil || a["clear"] != nil
                || a["submit"] != nil {
                try await typeInto(a, text, run)
                return
            }
            let r = try route(t, at: nil, foreground: foreground)
            if foreground { prepareForeground(r) }
            try await typeText(text, r)
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
            if foreground { prepareForeground(r) }
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
            if foreground { prepareForeground(r) }
            if type.hasPrefix("key_up") || type == "keyup" {
                let names = keys.isEmpty ? run.heldKeys.map(\.name) : keys
                for (i, k) in names.reversed().enumerated() {
                    if i > 0 { await Input.sleep(typist.modifierTrail()) }
                    try run.keyUp(k, r)
                }
                return
            }
            guard !keys.isEmpty else { throw HelperError("\(type) needs keys, e.g. \"shift\" or \"cmd+option\"") }
            try guardKeyboard(r)  // a held key would be pressed in whichever window has the keyboard
            // What they do with the keys already held: a shortcut, Return or Space on a button, a character.
            let combo = run.heldKeys.map(\.name) + keys
            try Policy.checkShortcuts(a, [combo], r.pid)
            try checkKey(combo, r, after: 0)
            let seconds = num(a["ms"]).map { $0 / 1000 } ?? num(a["duration"] ?? a["seconds"]) ?? 1
            if type.hasPrefix("hold"), !(0...10).contains(seconds) {
                throw HelperError("hold_key holds for at most 10 s (ms 0-10000)")
            }
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
            try guardKeyboard(menuRoute)
            let path = AX.menuPath(a["item"] ?? a["path"] ?? a["text"])
            // On a new hold, the window's click (see primeKeys) goes once the item has passed its check.
            let prime = keysNeedPrimer(menuRoute)
            let (chosen, shortcut): (String, String?)
            do {
                (chosen, shortcut) = try AX.pressMenu(pid: pid, path: path) { title in
                    try Policy.checkItem(a, title)
                    if prime { throw PrimeFirst() }
                }
            } catch is PrimeFirst {
                await primeKeys(menuRoute)
                (chosen, shortcut) = try AX.pressMenu(pid: pid, path: path) { try Policy.checkItem(a, $0) }
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
            try await open(a, run)
        case "wait_for", "waitfor":
            try await waitFor(a, run)
        case "clipboard":
            if let text = a["text"] as? String {
                try Connection.check()
                Clipboard.set(text)
                notes.append("clipboard set (\(text.count) characters; what was there is replaced)")
            } else {
                let limit = min(max(1, int(a["limit"], Clipboard.readLimit)), Clipboard.maxRead)
                let (text, note) = Clipboard.read(offset: max(0, int(a["offset"], 0)), limit: limit)
                run.clipboard = text
                if let note { notes.append(note) }
            }
        case "paste":
            guard let text = a["text"] as? String, !text.isEmpty else { throw HelperError("paste needs text") }
            let r = try route(t, at: nil, foreground: foreground)
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
            guard let n = try elementNode(a, t) else { throw HelperError("set_value needs element or target") }
            if Policy.isSecure(n.element), !Policy.config.allowSecureFields { throw Policy.secureRefusal() }
            let text = a["value"] as? String ?? a["text"] as? String ?? ""
            let shown = try await reveal(n, aimName(a))  // scrolled to first if it's out of view, as for every action
            if let c = shown.map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? AX.center(n) {
                await pointer.move(to: c, try route(t, at: c, foreground: false))
            }
            if !AX.setValue(n, text) { throw HelperError("the \(n.name) did not accept a value") }
        case "focus":
            guard let n = try elementNode(a, t) else { throw HelperError("focus needs element or target") }
            _ = try await reveal(n, aimName(a))
            if !AX.focus(n) { throw HelperError("the \(n.name) can't take focus") }
        case "ax", "secondary", "perform":
            guard let n = try elementNode(a, t) else { throw HelperError("\(type) needs element or target") }
            let name = a["name"] as? String ?? a["ax_action"] as? String ?? "press"
            let idx = num(a["element"]) ?? 0
            if ["press", "axpress", "confirm", "axconfirm", "pick", "axpick"].contains(name.lowercased()), let pid = pid(t) {
                try Policy.checkPress(a, node: n, at: nil, pid: pid)
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
            AX.raise(pid: w.pid, wid: w.id)
            try await Run.pause(0.25)
            // Keys after it go to the app's key window: check it's this one (when the app says), and try
            // again twice before saying it isn't.
            for _ in 0..<2 {
                guard let key = AX.focusedWindow(pid: w.pid), key != w.id else { break }
                SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
                AX.raise(pid: w.pid, wid: w.id)
                try await Run.pause(0.25)
            }
            if let key = AX.focusedWindow(pid: w.pid), key != w.id {
                throw HelperError("\(w.app) didn't bring window #\(w.id) forward: its keyboard is still in #\(key), so "
                    + "keys would go there. Look at the screen before going on")
            }
        case "close_window", "close":
            guard case .window(let w) = t else { throw HelperError("close_window needs a window target") }
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
    /// ever typed into the user's window: if their window has the keyboard, the action stops and says so.
    static func guardKeyboard(_ r: Route) throws {
        guard !keysReachTarget(r) else { return }
        let app = Policy.appName(r.pid)
        if let key = AX.focusedWindow(pid: r.pid), let w = Windows.info(key) {
            let what = w.title.isEmpty ? "window #\(key)" : "window #\(key) \"\(AX.clip(w.title, 40))\""
            if agentWindows.contains(key) {
                // In the user's front app, it's moved at the start of a call (act), and only while they leave the
                // keyboard and mouse alone: they may be typing into that window.
                if Hold.isFront(r.pid) {
                    if !Input.userQuiet() {
                        throw HelperError("your other \(what) has \(app)'s keyboard, and \(app) is the user's front app: "
                            + "they're using the keyboard or mouse, maybe typing there, so puter-use didn't move it. The "
                            + "action didn't run. Try again in a few seconds, or work in #\(key)")
                    }
                    throw HelperError("your other \(what) has \(app)'s keyboard, and it wasn't moved to #\(r.wid): the "
                        + "action didn't run. Run it again in a new call (that moves it when it can), or click inside "
                        + "#\(r.wid) first; or work in #\(key)")
                }
                throw HelperError("your other \(what) has \(app)'s keyboard, and it couldn't be moved to #\(r.wid): the "
                    + "action didn't run. Work in #\(key), or close it if you're done with it")
            }
            throw HelperError("another window of \(app) has the keyboard (\(what), not the agent's #\(r.wid)): "
                + "it would act on that one instead, so the action didn't run. Wait until the keyboard is back in "
                + "#\(r.wid) (the user may be using \(app)), then try again")
        }
        throw HelperError("\(app)'s keyboard may be in a window other than the agent's #\(r.wid): the action didn't "
            + "run, since it would act there. Wait until the user is out of \(app), then try again")
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
                   !(await Input.type(end, r, typist: typist, stillSafe: { keysReachTarget(r) })) {
                    throw try interruption(sent, r)
                }
            } else if !(await Input.type(s.text + end, r, typist: typist, stillSafe: { keysReachTarget(r) })) {
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
            return "filled \((a["fields"] as? [Any])?.count ?? 0) fields" + (a["submit"] != nil ? " and submitted" : "")
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

    /// Another window of the app took the keyboard partway through the text.
    private static func typingInterrupted(_ sent: Int, _ r: Route) -> HelperError {
        let sofar = sent == 0 ? "only part of it had gone out" : "the first \(sent) characters had gone out"
        return HelperError("stopped partway through the text: another window of \(Policy.appName(r.pid)) took the "
            + "keyboard (not the agent's #\(r.wid)); \(sofar), and nothing more was typed. Wait until the keyboard "
            + "is back, then type the rest")
    }

    /// Button holds are a hand's, whatever the typing speed; instant only when the pointer jumps (speed 0).
    static var clickTiming: Typist { Typist(wpm: pointer.speed <= 0 ? 0 : 140) }

    static func prepareForeground(_ r: Route) {
        AX.raise(pid: r.pid, wid: r.wid)
        usleep(150_000)
    }

    static func act(_ p: [String: Any]) async throws -> [String: Any] {
        let t = try resolve(p["window"])
        current = t.key
        let o = Opts(p)
        guard AXIsProcessTrusted() else {
            throw HelperError("Accessibility permission missing for PuterUse (run: puter-use setup)")
        }
        // A macro step runs as the steps it saved.
        let (actions, expanded) = try Macros.expand(p["actions"] as? [[String: Any]] ?? [], pid: pid(t))
        let saveAs = p["save_as"].flatMap { $0 is NSNull ? nil : $0 }
        if let saveAs { _ = try Macros.check(saveAs) }
        let base = max(int(p["first"], 1), 1) - 1  // a batch continued after the user's OK numbers on from there
        // The policy first: an app the agent may not act in isn't activated, captured or described on the
        // way to a refusal, and a batch with a refused action doesn't half run.
        try Policy.checkLook(pid(t))
        for (i, a) in actions.enumerated() {
            do { try Policy.checkAction(a, pid: pid(t)) } catch {
                throw HelperError("nothing was run: action \(base + i + 1) (\(kind(a))) is \(error)")
            }
            if let why = unknownKeys(a) { throw HelperError("nothing was run: action \(base + i + 1) (\(kind(a))) \(why)") }
        }
        // Continuing after the user's OK: the steps recorded before the stop (never with a confirm).
        var recorded: [[String: Any]] = (p["recorded"] as? [[String: Any]] ?? []).map { step in
            var s = step
            s["confirm"] = nil
            return s
        }
        let wantShot = p["screenshot"] as? Bool != false
        let always = wantShot && p["always_image"] as? Bool == true
        // Coordinates with no screenshot of this window to refer to (none yet in this session, or the helper
        // restarted since): they were read off a picture that may be out of date, so the batch stops
        // before them.
        let firstLook = meta[t.key] == nil
        var shownAtStart = false
        if case .window(let w) = t { shownAtStart = Windows.info(w.id)?.onScreen == true }
        let blind = firstLook && p["guard"] as? Bool != false && actions.contains(where: aimsByCoordinates)
        var firstShot: (plan: CapturePlan, basis: PlanBasis?, shot: Shot)?  // shown if the first action fails (`ending`)
        if firstLook && (wantShot || actions.contains(where: needsCoordinates)) {
            // Establish the coordinate mapping (for actions that need one, like a scroll in the middle).
            let basis = PlanBasis.of(t)  // read before planning, as `settle` does
            let start = try await plan(t, region: nil, o)
            let shot = try await start.run()
            remember(t, shot, Signature(shot.image))
            firstShot = (start, basis, shot)
        }
        // A picture the agent hasn't seen isn't a "before": on a first look, the result shows the window.
        var before = firstLook ? nil : meta[t.key]?.sig
        let caretThen = firstLook ? nil : meta[t.key]?.caret  // the text cursor in that picture
        let foreground = p["foreground"] as? Bool == true
        let run = Run(target: t, foreground: foreground, guarded: p["guard"] as? Bool != false, box: o.windowBox)
        Run.active[ObjectIdentifier(run)] = (run, Session.current)
        defer { Run.active[ObjectIdentifier(run)] = nil }
        // One session drives an app at a time; another's act on it waits for this one to finish.
        if let pid = pid(t) {
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
        // Background apps drop clicks (as "activation clicks") and key equivalents. Tell the target's AppKit
        // layer it is active (and keep it so between calls, see `Hold`); the user's real focus is untouched.
        try Connection.check()
        if !foreground, case .window(let w) = t, !Hold.isFront(w.pid) {
            // Held on this window since an earlier call: the app has taken the record already, so it's sent
            // again (it's cheap) without waiting for it.
            let wasHeld = Hold.heldSettled(pid: w.pid, wid: w.id)
            if Hold.activate(pid: w.pid, wid: w.id), !wasHeld { try await Task.sleep(nanoseconds: 30_000_000) }
            // Keyboard input (and key equivalents like cmd+a) only reach a window AppKit considers key.
            if actions.contains(where: { actsOnKeyboardFocus($0) }) {
                // Held here and key already: sent again too, with no wait (and nothing to move).
                let wasKey = wasHeld && AX.focusedWindow(pid: w.pid) == w.id
                SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
                if !wasKey {
                    try await Task.sleep(nanoseconds: 30_000_000)
                    switch keyPrimer(focused: AX.focusedWindow(pid: w.pid), wid: w.id, fresh: Hold.fresh.contains(w.pid),
                                     agentWindows: agentWindows) {
                    case .fromAgentWindow:
                        // Not taken (Firefox ignores it) while another of the agent's own windows has the keyboard: a
                        // click just outside this one's content moves it, as a click on the window would. Never from
                        // a window of the user's: their keyboard stays where they left it (guardKeyboard says so).
                        await Input.primer(try route(t, at: nil, foreground: false), force: true)
                        await Input.afterPrimer()  // the keyboard gets the primer's whole gap and the pause to move
                        try await Run.pause(0.1)
                    case .freshHold, .none:
                        break  // a new hold's click waits for the first key or menu command (`primeKeys`)
                    }
                }
            }
        } else {
            Hold.release(for: Session.current)
            // The app is the user's front app, but its keyboard is on another of the agent's own windows, so
            // what they'd type goes there already, not to a window of theirs. It's moved here the same way
            // (as a click here would), only while they're leaving the keyboard and mouse alone: they may be
            // typing into that window.
            if !foreground, case .window(let w) = t, actions.contains(where: { actsOnKeyboardFocus($0) }),
               let key = AX.focusedWindow(pid: w.pid), key != w.id, agentWindows.contains(key), Input.userQuiet() {
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
        var stopped: String?
        var confirm: [String: Any]?
        for (i, a) in actions.enumerated() {
            if Connection.hungUp {  // the client gave up: nothing more runs
                cancelled = true
                break
            }
            Connection.current?.work.typed = 0
            Connection.current?.work.did = []
            Connection.current?.work.fields = nil
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
            if aimsByCoordinates(a), let why = blind && !run.moved ? "there's no earlier screenshot of this window to read them from"
                + " (puter-use may have restarted)" : run.staleCoordinates() {
                let rest = i + 1 == actions.count ? "it was" : "actions \(base + i + 1)-\(base + actions.count) were"
                stopped = "stopped before action \(base + i + 1) (\(kind(a)) by coordinates): \(why); \(rest) not run. "
                    + (wantShot ? "Look at the new screenshot, then continue." : "Take a screenshot, then continue.")
                break
            }
            defer { notes += AX.remarks; AX.remarks.removeAll() }
            do {
                try Policy.checkAction(a, pid: pid(run.target))
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
                    try await perform(marked(a, last: i == actions.count - 1, menuLook: !foreground && pid(run.target) != nil), run)
                    try Connection.check()  // given up partway: whether this one took effect isn't known
                    if let step { recorded.append(Macros.ran(step, menu: run.ranMenu)) }
                    done += 1
                    Connection.current?.work.done = done
                    Connection.current?.work.steps.append(brief(a))
                    if i < actions.count - 1 {
                        if let (button, r, _) = run.heldButton {  // a hand holding the button down never quite stops
                            await pointer.hold(0.06, r, button: button)
                        } else if mayOpen(a) {
                            try await run.settle(since: overBefore)
                            // A menu left open would take the next actions' keys (and the user's): closed now.
                            if !foreground, let pid = pid(run.target) {
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
            } catch {
                if error is Cancelled || Connection.hungUp {
                    cancelled = true
                    // (A wait or look that was cut short did nothing.)
                    if done == i, !["wait", "sleep", "wait_for", "waitfor", "screenshot"].contains(kind(a)) {
                        Connection.current?.work.partial = partway(base + i + 1, a)
                    }
                    break
                }
                errors.append("action \(base + i + 1) (\(a["type"] ?? "?")): \(error)")
                break
            }
        }
        if cancelled || Connection.hungUp {
            // The client gave up: let go of what's held and close a menu left open (cleanup always runs),
            // then stop. No settle, screenshot or record of what was shown: no one would see it.
            if let w = Connection.current?.work { Connection.current?.work.opened += openedBy(run).filter { !w.opened.contains($0) } }
            await Connection.ungated {
                _ = await run.releaseAll(clickTiming, cancelled: true)
                if !foreground, let pid = pid(run.target) {  // not remembered: the agent never hears of it
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
        if !foreground, let pid = pid(run.target) {
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
        if run.moved { before = nil }
        func followNewWindow() async -> Bool {
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
            Connection.current?.work.opened.append(nw.id)
            current = nw.id
            before = nil
            return true
        }
        var out: [String: Any] = ["done": done, "total": actions.count]
        if !errors.isEmpty { out["errors"] = errors }
        if let c = run.clipboard { out["clipboard"] = c }
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
        let end = ending(wantShot: wantShot, always: always, done: done, stopped: stopped != nil,
                         failed: !errors.isEmpty, firstLook: firstLook, moved: run.moved)
        if end == .firstLook, let first = firstShot {
            // Taken again (one capture): the failed action, or a wait_for that timed out, may have changed the
            // window since. With the start's plan, unless something opened over the window or it moved: then
            // a new plan, which the mapping (`result`) follows.
            let again = PlanBasis.of(t) == first.basis ? first.plan : try? await plan(t, region: nil, o)
            let shot = (try? await again?.run()) ?? first.shot
            if let res = try? await result(t, shot, o, zoom: false, text: p["text"] as? Bool == true, diff: true) {
                if !notes.isEmpty { out["notes"] = notes }
                out.merge(res) { _, new in new }
                if let note = partShown(t, shot) { out["notes"] = (out["notes"] as? [String] ?? []) + [note] }
                out["changed"] = true
                return out
            }
        }
        if end != .settled {
            // No image: the agent still hasn't seen the window, so its coordinates stay unanchored.
            if firstLook { meta[t.key] = nil }
            do { try await Run.pause(followWait(actions, done: done, failed: !errors.isEmpty)) } catch {
                // The client gave up meanwhile: as above, the note for its lost result names what opened.
                if let w = Connection.current?.work { Connection.current?.work.opened += openedBy(run).filter { !w.opened.contains($0) } }
                throw error
            }
            _ = await followNewWindow()
            if !notes.isEmpty { out["notes"] = notes }
            out["window"] = describe(target)
            if p["text"] as? Bool == true { out.merge(accessibility(target, o, diff: true)) { _, new in new } }
            return out
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
        var watched: Double?  // how long it went on looking for a new window after an early end (trace)
        do {
            let e = early()
            (shot, sig) = try await settledShot(target, o, early: e)
            if !followed {  // slower apps
                var found = await followNewWindow()
                // An early end comes before the wait used to look again: after an action that may open a window
                // a moment later, keep looking until then.
                if !found, let e, opensWindow(done > 0 ? actions[done - 1] : nil) {
                    let began = ProcessInfo.processInfo.systemUptime
                    found = try await watchForWindow(until: e.lookedAgain, look: followNewWindow, pause: { try await Run.pause(0.05) })
                    watched = ProcessInfo.processInfo.systemUptime - began
                }
                if found { (shot, sig) = try await settledShot(target, o, early: early()) }
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
        var change = before.flatMap { sig.diff($0, outW: shot.image.width, outH: shot.image.height) }
            ?? (before == nil ? (CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height), 1) : nil)
        let caretNow = caretThen != nil && target.key == t.key ? caret(target) : nil
        // The text cursor blinked, and that's all: nothing the agent needs to see.
        if change != nil, let b = before, let then = caretThen, let now = caretNow, blinked(sig, from: b, then: then, now: now, shot, target) {
            change = nil
            Trace.log(["k": "blink"])
        }
        // The cursor moved (a click in the text, an arrow key) but shows in neither picture, being between
        // blinks: say so rather than drop it. (When it shows, that's a change, with the picture.)
        if change == nil, let then = caretThen, let now = caretNow, now.moved(from: then) {
            out["notes"] = (out["notes"] as? [String] ?? []) + ["the text cursor moved: it's now \(now.at) characters into the text"]
            meta[t.key]?.caret = now  // the agent knows: its blinking there isn't a change
        }
        if change == nil && !always && stopped == nil {
            Run.look(target)  // what the agent last saw still holds
            out["changed"] = false
            out["window"] = describe(target)
            if p["text"] as? Bool == true { out.merge(accessibility(target, o, diff: true)) { _, new in new } }
            return out
        }
        let res = try await result(target, shot, o, zoom: false, text: p["text"] as? Bool == true, diff: true)
        if firstLook, target.key != t.key { meta[t.key] = nil }  // it was shown the window it moved to instead
        out.merge(res) { _, new in new }
        if let note = partShown(target, shot) { out["notes"] = (out["notes"] as? [String] ?? []) + [note] }
        out["changed"] = change != nil
        if let c = change {
            out["change_box"] = [Int(c.box.minX), Int(c.box.minY), Int(c.box.maxX), Int(c.box.maxY)]
            out["change_fraction"] = c.fraction
        }
        return out
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
    static func settledShot(_ t: Target, _ o: Opts, early: Early? = nil) async throws -> (Shot, Signature) {
        try await settle(basis: { PlanBasis.of(t) }, makePlan: { try await plan(t, region: nil, o) },
                         capture: { try await $0.run() }, pause: { try await Task.sleep(nanoseconds: 150_000_000) },
                         early: early)
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
    /// `before`, comes no sooner than it did.
    static func settle<Plan, Basis: Equatable>(
        basis: () -> Basis, makePlan: () async throws -> Plan, capture: (Plan) async throws -> Shot,
        pause: () async throws -> Void, early: Early? = nil,
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
                MainActor.assumeIsolated { if let pid, held[pid] != nil { forget(pid) } }
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
