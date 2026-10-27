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
    static var meta: [CGWindowID: Meta] {
        get { Session.current.meta }
        set { Session.current.meta = newValue }
    }
    static var pointer: Pointer { Session.current.pointer }

    static func dispatch(_ line: Data) async -> Data {
        guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return encode(["id": NSNull(), "ok": false, "error": "request must be a JSON object"])
        }
        let p = req["params"] as? [String: Any] ?? [:]
        let session = Session.named((req["session"] ?? p["session"]) as? String ?? "default")
        session.lastUse = Date()
        return await Session.$current.withValue(session) { await handle(req, p) }
    }

    static func handle(_ req: [String: Any], _ p: [String: Any]) async -> Data {
        let id: Any = req["id"] ?? NSNull()
        do {
            Hold.touch()
            let result: [String: Any]
            switch req["cmd"] as? String ?? "" {
            case "status": result = ["version": version, "pid": Int(Windows.ownPID), "permissions": Permissions.status()]
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
                Hold.releaseAll()
                await Clipboard.finish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
                result = [:]
            case let other: throw HelperError("unknown command \(other)")
            }
            return encode(["id": id, "ok": true, "result": result])
        } catch {
            return encode(["id": id, "ok": false, "error": "\(error)"])
        }
    }

    static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{\"ok\":false}".utf8)
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
            guard let w = Windows.info(cur) else { throw HelperError("window \(cur) no longer exists") }
            return .window(w)
        }
        if let n = num(v), !(v is String && Int(v as! String) == nil) {
            // An id no window can have (negative, fractional, past UInt32) is not found either.
            guard let id = CGWindowID(exactly: n), let w = Windows.info(id) else {
                throw HelperError("window \(Int(exactly: n).map(String.init) ?? "\(n)") not found")
            }
            return .window(w)
        }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else {
            throw HelperError("bad window value")
        }
        if s.lowercased() == "screen" { return .screen }
        if let w = Windows.targetable(app: s).first(where: { $0.onScreen }) ?? Windows.targetable(app: s).first {
            return .window(w)
        }
        if Windows.runningApp(s) != nil { throw HelperError("\(s) is running but has no windows (use windows with launch=true)") }
        throw HelperError("no window for \"\(s)\" (not running? use windows with launch=true)")
    }

    // MARK: - commands

    static func windows(_ p: [String: Any]) async throws -> [String: Any] {
        let app = (p["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var wins: [WinInfo]
        if let app, p["launch"] as? Bool == true {
            let existed = Set(Windows.all().map(\.id))
            wins = try await Windows.launch(app)
            if let box = Opts(p).windowBox {
                var resized = false
                for w in wins where w.onScreen && !existed.contains(w.id) {
                    if AX.fit(pid: w.pid, wid: w.id, box: box) { resized = true }
                }
                if resized {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    wins = Windows.targetable(app: app)
                }
            }
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
        /// token cap. Off by default: they keep the size the app gave them.
        var windowBox: CGSize? = nil
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
        meta[t.key] = Meta(offset: CGPoint(x: shot.rect.minX - o.x, y: shot.rect.minY - o.y), size: shot.rect.size,
                           width: shot.image.width, height: shot.image.height, sig: sig)
        Run.look(t)
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
        return ["x", "y", "coordinate", "path", "from", "to", "start", "end", "start_coordinate"].contains { a[$0] != nil }
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

    nonisolated static let keyboardActions: Set<String> = [
        "type", "type_text", "keypress", "key", "press_key", "hotkey", "key_down", "keydown", "key_up", "keyup",
        "hold_key", "hold", "fill", "navigate", "goto", "go_to", "paste",
    ]

    /// Actions that act on the app's keyboard focus: keys (including the modifiers a click or drag holds)
    /// and menu commands, which act on the focused window. That window has to be the app's key one first.
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
        if within == nil, let pid = pid(t), let f = AX.focusedSummary(pid: pid) { out["focused"] = f }
        if case .window(let w) = t {
            let full = AX.outline(pid: w.pid, wid: w.id, within: within, maxChars: o.maxChars, interactive: o.interactive)
            out["text"] = full ?? "(no accessibility tree for this window)"
            if full != nil, within == nil, let lines = AX.registries[w.id]?.lines {
                let sent = Session.current.outlines[w.id]
                if diff, let sent, sent.interactive == o.interactive, let changes = outlineChanges(sent.lines, lines) {
                    out["text"] = changes
                }
                Session.current.outlines[w.id] = (o.interactive, lines)
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
            if !text || !o.interactive {  // number what can be acted on (this outline isn't sent)
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
    /// coordinates. Text with no accessibility element is looked for on screen.
    static func actionPoint(_ a: [String: Any], _ t: Target, required: Bool = true) async throws -> (CGPoint, AX.Node?)? {
        if let idx = num(a["element"]), case .window(let w) = t {
            let n = try AX.node(w.id, Int(idx))
            try reachable(n.element, "element \(Int(idx))")
            guard let c = AX.center(n) else { throw HelperError("element \(Int(idx)) has no position") }
            return (c, n)
        }
        if let v = a["target"] {
            // A macro step names what it pressed and where it was: see Macros.spot.
            let saved = a["units"] as? String == "pt" ? num(a["x"]).flatMap { x in num(a["y"]).map { (x, $0) } } : nil
            if let (x, y) = saved, a["spot"] as? Bool == true {
                if let (p, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a), strict: true) { return (p, n) }
                throw HelperError("\(try spec(v).description) isn't where it was when the macro was saved (others show the "
                    + "same), so nothing was pressed")
            }
            do {
                let (id, n) = try findOne(v, t)
                guard let c = AX.center(n) else { throw HelperError("element \(id) has no position") }
                return (c, n)
            } catch {
                if let (x, y) = saved, !(error is Behind) {
                    if let (p, n) = try Macros.spot(v, t, at: try toGlobal(t, x, y, a)) { return (p, n) }
                    throw HelperError("\(error) (a macro step: what it pressed isn't where it was, so nothing was pressed)")
                }
                guard error is NotFound else { throw error }
                return (try await readOffScreen(v, t), nil)
            }
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
            guard let (p, node) = try await actionPoint(a, t) else { return }
            let r = try route(t, at: p, foreground: foreground)
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
                let chose = try await AX.choose(popup, want) { try Policy.checkItem(a, $0) }
                if AX.menuKey(chose) != AX.menuKey(want) { notes.append("chose \"\(chose)\"") }
                return
            }
            // A menu to choose from is opened with a real click: one opened through accessibility doesn't
            // follow the pointer.
            let viaAX = node.map { AX.isPressable($0.element) } == true && count == 1 && allFlags.isEmpty && !foreground
                && (button == "left" || button == "right") && a["_pointer"] == nil && a["item"] == nil
            if foreground { prepareForeground(r) }
            if !viaAX { await Input.primer(r) }
            let mods = await Input.pressModifiers(flags, r, typist: clickTiming)  // keys held on the way, as a hand does
            await pointer.move(to: p, r)
            await Input.sleep(clickTiming.aim())
            if viaAX, let node, AX.perform(node, button == "right" ? "showmenu" : "press") {
                pointer.click()
                return
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
            if let (button, r) = run.heldButton {  // a button is down: this is a drag
                await pointer.move(to: p, r, button: button)
            } else {
                await pointer.move(to: p, try route(t, at: p, foreground: foreground))
            }
        case "mouse_down":
            let button = (a["button"] as? String)?.lowercased() ?? "left"
            var p: CGPoint
            var node: AX.Node?
            if let (q, n) = try await actionPoint(a, t, required: false) { (p, node) = (q, n) } else {
                guard let tip = pointer.tip else { throw HelperError("mouse_down needs x,y or element") }
                p = tip
            }
            let r = try route(t, at: p, foreground: foreground)
            if button == "left" { try Policy.checkPress(a, node: node, at: p, pid: r.pid) }
            if foreground { prepareForeground(r) }
            await Input.primer(r)
            await pointer.move(to: p, r)
            await Input.sleep(clickTiming.aim())
            // Its keys stay down with the button, as a hand holds shift through a shift-drag.
            if !Keys.splitCombo(a["keys"] ?? a["modifiers"]).isEmpty { try guardKeyboard(r) }
            for k in Keys.splitCombo(a["keys"] ?? a["modifiers"]) where !run.heldKeys.contains(where: { $0.name == Keys.normalize(k) }) {
                try run.keyDown(k, r)
                run.buttonKeys.append(k)
                await Input.sleep(clickTiming.modifierLead())
            }
            let (down, _, _, btn) = Input.buttonTypes(button)
            Input.newClickGroup()
            Input.mouse(down, p, r, button: btn)
            pointer.click()
            run.heldButton = (button, r)
        case "mouse_up":
            guard let (button, r) = run.heldButton else { throw HelperError("no mouse button is down (mouse_down first)") }
            if let (p, _) = try await actionPoint(a, t, required: false) {
                await pointer.move(to: p, r, button: button)
                await pointer.hold(clickTiming.clickHold(), r, button: button)
            }
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
            await pointer.move(to: pts[0], r)
            await Input.sleep(clickTiming.aim())
            Input.newClickGroup()
            Input.mouse(down, pts[0], r, button: btn, flags: flags)
            pointer.click()
            await pointer.hold(clickTiming.clickHold(), r, button: button, flags: flags)
            await pointer.stroke(pts, r, button: button, flags: flags)
            await pointer.hold(clickTiming.clickHold(), r, button: button, flags: flags)
            Input.mouse(up, pts[pts.count - 1], r, button: btn, flags: flags)
            await Input.releaseModifiers(mods, r, typist: clickTiming)
            if let textStart {
                await AX.settleDragSelection(textStart, before: selectedBefore, pid: r.pid, wid: r.wid, end: pts[pts.count - 1])
            }
        case "scroll":
            var p: CGPoint
            if let (q, _) = try await actionPoint(a, t, required: false) { p = q } else if case .window(let w) = t,
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
            await Input.scroll(p, dx: dx * ptPerPx, dy: dy * ptPerPx, r)
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
            for (i, k) in keys.enumerated() {
                if i > 0 { await Input.sleep(typist.modifierLead()) }
                try run.keyDown(k, r)
            }
            if type.hasPrefix("hold") {
                await Input.sleep(seconds)
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
            let (chosen, shortcut) = try AX.pressMenu(pid: pid, path: path) { try Policy.checkItem(a, $0) }
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
                Clipboard.set(text)
                notes.append("clipboard set (\(text.count) characters; what was there is replaced)")
            } else {
                run.clipboard = Clipboard.read()
            }
        case "paste":
            guard let text = a["text"] as? String, !text.isEmpty else { throw HelperError("paste needs text") }
            let r = try route(t, at: nil, foreground: foreground)
            try Policy.checkSecureFocus(r.pid)
            if foreground { prepareForeground(r) }
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
            if let c = AX.center(n) { await pointer.move(to: c, try route(t, at: c, foreground: false)) }
            if !AX.setValue(n, text) { throw HelperError("the \(n.name) did not accept a value") }
        case "focus":
            guard let n = try elementNode(a, t) else { throw HelperError("focus needs element or target") }
            if !AX.focus(n) { throw HelperError("the \(n.name) can't take focus") }
        case "ax", "secondary", "perform":
            guard let n = try elementNode(a, t) else { throw HelperError("\(type) needs element or target") }
            let name = a["name"] as? String ?? a["ax_action"] as? String ?? "press"
            let idx = num(a["element"]) ?? 0
            if ["press", "axpress", "confirm", "axconfirm", "pick", "axpick"].contains(name.lowercased()), let pid = pid(t) {
                try Policy.checkPress(a, node: n, at: nil, pid: pid)
            }
            if let c = AX.center(n) { await pointer.move(to: c, try route(t, at: c, foreground: false)) }
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
            if let (button, r) = run.heldButton {  // a hand holding a button down never quite stops
                await pointer.hold(ms / 1000, r, button: button)
            } else {
                await Input.sleep(ms / 1000)
            }
        case "activate", "raise", "focus_window":
            guard case .window(let w) = t else { return }
            AX.raise(pid: w.pid, wid: w.id)
            try await Task.sleep(nanoseconds: 250_000_000)
        case "close_window", "close":
            guard case .window(let w) = t else { throw HelperError("close_window needs a window target") }
            if !AX.closeWindow(pid: w.pid, wid: w.id) { throw HelperError("window has no close button") }
            try await Task.sleep(nanoseconds: 300_000_000)
            if Windows.info(w.id)?.onScreen == true {
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
        try guardKeyboard(r)
        if !r.foreground, Windows.isChromium(r.pid), NSRunningApplication(processIdentifier: r.pid)?.isActive != true,
           let title = AX.pressMenuShortcut(pid: r.pid, keys: keys) {
            notes.append("\(keys.joined(separator: "+")) → menu \"\(title)\"")
            return
        }
        try await Input.keyCombo(keys, r, typist: typist)
    }

    /// Type `text` like a person: up to about a sentence is typed; a longer stretch is pasted (as people
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
        if let f = focused, focusedHere, AX.isBrowserAddressBar(f, pid: r.pid),
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
            // The user may have taken the keyboard since the last stretch (a long text takes a while).
            try guardKeyboard(r)
            if i > 0 { await Input.sleep(typist.between()) }
            let end = s.end.map { String($0) } ?? ""
            if pasteOver > 0, s.text.count > pasteOver {
                await Input.sleep(typist.instant ? 0 : Double.random(in: 0.15...0.35))  // reach for the shortcut
                Clipboard.borrow(s.text)
                do { try await press(["cmd", "v"], r) } catch {
                    Clipboard.giveBack()
                    throw error
                }
                Clipboard.giveBack()
                await Input.sleep(typist.instant ? 0.03 : Double.random(in: 0.12...0.25))
                if !end.isEmpty,
                   !(await Input.type(end, r, typist: typist, stillSafe: { keysReachTarget(r) })) {
                    throw typingInterrupted(sent, r)
                }
            } else if !(await Input.type(s.text + end, r, typist: typist, stillSafe: { keysReachTarget(r) })) {
                throw typingInterrupted(sent, r)
            }
            sent += s.text.count + end.count
        }
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
        if firstLook && (wantShot || actions.contains(where: needsCoordinates)) {
            // Establish the coordinate mapping (for actions that need one, like a scroll in the middle).
            let shot = try await plan(t, region: nil, o).run()
            remember(t, shot, Signature(shot.image))
        }
        // A picture the agent hasn't seen isn't a "before": on a first look, the result shows the window.
        var before = firstLook ? nil : meta[t.key]?.sig
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
        typist = Typist(wpm: num(p["typing_wpm"]) ?? 140)
        pasteOver = max(0, int(p["paste_over"], 100))
        Trace.configure(p["trace"] as? String)
        AppCards.enabled = p["app_cards"] as? Bool != false
        var errors: [String] = []
        var done = 0
        notes = expanded
        // Background apps drop clicks (as "activation clicks") and key equivalents. Tell the target's AppKit
        // layer it is active (and keep it so between calls, see `Hold`); the user's real focus is untouched.
        if !foreground, case .window(let w) = t, !Hold.isFront(w.pid) {
            if Hold.activate(pid: w.pid, wid: w.id) { try await Task.sleep(nanoseconds: 30_000_000) }
            // Keyboard input (and key equivalents like cmd+a) only reach a window AppKit considers key.
            if actions.contains(where: { actsOnKeyboardFocus($0) }) {
                SkyLight.makeKeyWindow(pid: w.pid, wid: w.id)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        } else {
            Hold.release(for: Session.current)
        }
        var stopped: String?
        var confirm: [String: Any]?
        for (i, a) in actions.enumerated() {
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
                    let step = saveAs == nil ? nil : Macros.record(a, run.target)
                    // Keys pressed with a mouse button down: the hand on the mouse still trembles meanwhile.
                    let tremor: Task<Void, Never>? = run.heldButton.flatMap { held in
                        keyboardActions.contains(kind(a)) || kind(a) == "menu"
                            ? Task { await pointer.hold(30, held.route, button: held.button) } : nil
                    }
                    defer {
                        tremor?.cancel()
                        if tremor != nil { pointer.endHold() }
                    }
                    try await perform(a, run)
                    if let step { recorded.append(step) }
                    done += 1
                    if i < actions.count - 1 {
                        if let (button, r) = run.heldButton {  // a hand holding the button down never quite stops
                            await pointer.hold(0.06, r, button: button)
                        } else if mayOpen(a) {
                            await run.settle()
                            // A menu left open would take the next actions' keys (and the user's): closed now.
                            if !foreground, let pid = pid(run.target) { await closeLeftOpenMenu(pid: pid, wait: false) }
                        } else {
                            await Input.ms(60)
                        }
                    }
                }
            } catch let ok as Policy.NeedsOK {
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
                errors.append("action \(base + i + 1) (\(a["type"] ?? "?")): \(error)")
                break
            }
        }
        let released = await run.releaseAll(clickTiming)
        if !foreground, let pid = pid(run.target) {
            await closeLeftOpenMenu(pid: pid, wait: done > 0 && actions.indices.contains(done - 1) && mayOpen(actions[done - 1]))
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
                  let nw = await follow(w, visibleBefore: run.visibleBefore, existedBefore: run.existedBefore, box: o.windowBox)
            else { return false }
            target = .window(nw)
            agentWindows.insert(nw.id)
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
        // Nothing ran (the first action failed): the error alone is enough. A stop shows the window, though.
        if !wantShot || (done == 0 && !always && stopped == nil) {
            // No image: the agent still hasn't seen the window, so its coordinates stay unanchored.
            if firstLook { meta[t.key] = nil }
            try await Task.sleep(nanoseconds: 200_000_000)
            _ = await followNewWindow()
            if !notes.isEmpty { out["notes"] = notes }
            out["window"] = describe(target)
            if p["text"] as? Bool == true { out.merge(accessibility(target, o, diff: true)) { _, new in new } }
            return out
        }

        let settle = min(max(num(p["settle_ms"]) ?? 250, 0), 10000)
        await Input.sleep(settle / 1000)
        let followed = await followNewWindow()
        var shot: Shot, sig: Signature
        do {
            (shot, sig) = try await settledShot(target, o)
            if !followed, await followNewWindow() { (shot, sig) = try await settledShot(target, o) }  // slower apps
        } catch {
            if case .window(let w) = target, Windows.info(w.id) != nil { throw error }
            out["closed"] = "\(error)"
            current = nil
            return out
        }
        if !notes.isEmpty { out["notes"] = notes }
        let change = before.flatMap { sig.diff($0, outW: shot.image.width, outH: shot.image.height) }
            ?? (before == nil ? (CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height), 1) : nil)
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
        out["changed"] = change != nil
        if let c = change {
            out["change_box"] = [Int(c.box.minX), Int(c.box.minY), Int(c.box.maxX), Int(c.box.maxY)]
            out["change_fraction"] = c.fraction
        }
        return out
    }

    /// Capture `t` once the UI has settled: re-capture until two consecutive frames match (ignoring tiny
    /// blips like a caret), for at most ~0.9 s.
    static func settledShot(_ t: Target, _ o: Opts) async throws -> (Shot, Signature) {
        let plan = try await self.plan(t, region: nil, o)
        var shot = try await plan.run()
        var sig = Signature(shot.image)
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 150_000_000)
            guard let next = try? await plan.run() else { break }
            let nsig = Signature(next.image)
            let d = sig.diff(nsig, outW: next.image.width, outH: next.image.height)
            shot = next
            sig = nsig
            if d == nil || d!.fraction < 0.002 { break }
        }
        return (shot, sig)
    }

    /// A window that appeared in `w`'s app during a batch: a browser window from cmd+n, a dialog, a
    /// settings window. Sheets and popovers drawn over `w` don't count (they're captured with it). With a
    /// `box`, windows the batch created are shrunk to it (points), so the screenshot fits the token cap at a readable scale
    /// whatever the display's pixel density.
    static func follow(_ w: WinInfo, visibleBefore: Set<CGWindowID>, existedBefore: Set<CGWindowID>,
                       box: CGSize?) async -> WinInfo? {
        let parent = Windows.info(w.id)?.frame ?? w.frame
        let fresh = Windows.all(onScreenOnly: true).filter {
            $0.pid == w.pid && $0.layer == 0 && !visibleBefore.contains($0.id)
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }
        guard let nw = fresh.first(where: { c in
            let el = AX.window(pid: c.pid, wid: c.id)
            let subrole = el.flatMap { AX.value($0, kAXSubroleAttribute) as? String }
            guard parent.contains(c.frame) else {
                // Not macOS's own bits shown in the app's name: the dictation orb is an untitled "dialog"
                // holding one control. An app's alert has its text and buttons, or is modal.
                guard c.title.isEmpty, let el, subrole != "AXStandardWindow" else { return true }
                return AX.value(el, "AXModal") as? Bool == true || AX.children(el).count > 1
            }
            return subrole == "AXStandardWindow"
        }) else { return nil }
        var note = "now on new window #\(nw.id)"
        if let box, !existedBefore.contains(nw.id), AX.fit(pid: nw.pid, wid: nw.id, box: box) {
            try? await Task.sleep(nanoseconds: 300_000_000)  // let it lay out at the new size
            if let f = Windows.info(nw.id)?.frame { note += ", sized to \(Int(f.width))x\(Int(f.height)) pt" }
        }
        notes.append(note)
        return Windows.info(nw.id) ?? nw
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
    static let idle: TimeInterval = 120
    private static var timer: Timer?
    private static var observer: NSObjectProtocol?

    /// Really frontmost (WindowServer), not just AppKit-active.
    static func isFront(_ pid: pid_t) -> Bool {
        SkyLight.isFrontProcess(pid) ?? (NSRunningApplication(processIdentifier: pid)?.isActive == true)
    }

    /// A request of the session came in: its apps aren't idle.
    static func touch() {
        for pid in Session.current.holding { lastUse[pid] = Date() }
    }

    static func activate(pid: pid_t, wid: CGWindowID) -> Bool {
        let me = Session.current
        for other in me.holding where other != pid { drop(other, from: me) }
        guard SkyLight.setAppKitActive(pid: pid, wid: wid, true) else { return false }
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
        lastUse[pid] = nil
        for s in Session.all.values { s.holding.remove(pid) }
    }

    static func releaseAll() {
        for pid in Array(held.keys) { release(pid) }
    }
}
