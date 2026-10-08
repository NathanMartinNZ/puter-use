import AppKit

/// One agent's state: the window it's working on, what it last saw, its own pointer. Each MCP server
/// (one per agent) and each CLI shell names its session (PUTER_USE_SESSION); requests of different
/// sessions run side by side, and an app is driven by one session at a time (`AppLocks`).
final class Session: @unchecked Sendable {  // only touched on the main thread
    let id: String
    let ordinal: Int
    var current: CGWindowID?  // 0 = whole screen
    var meta: [CGWindowID: Meta] = [:]  // coordinate mapping from the last full screenshot of each window
    var seen: [CGWindowID: WindowSet] = [:]  // what was over each window then (`Run.staleCoordinates`)
    var outlines: [CGWindowID: (interactive: Bool, lines: [(Int, String)])] = [:]  // the last outline it was sent
    var notes: [String] = []  // remarks for the agent, per request
    var remarks: [String] = []  // from accessibility lookups, folded into notes
    var typist = Typist(wpm: 140)
    var pasteOver = 100
    var agentWindows = Set<CGWindowID>()  // windows this agent opened (navigate uses them)
    var carded = Set<String>()  // apps it has had an app card for
    var cards = true
    var held: CGEventFlags = []  // modifiers held by key_down: its events carry them
    var clickGroup: Int64 = 0
    var holding = Set<pid_t>()  // apps kept AppKit-active for it (`Hold`)
    var lastUse = Date()
    private var _pointer: Pointer?

    init(id: String, ordinal: Int) {
        self.id = id
        self.ordinal = ordinal
    }

    /// Its pointer, made on first use. Sessions side by side get different colours.
    @MainActor var pointer: Pointer {
        if let p = _pointer { return p }
        let p = Pointer(tint: Session.tints[ordinal % Session.tints.count])
        p.setup()
        _pointer = p
        return p
    }

    @MainActor var hasPointer: Bool { _pointer != nil }

    static let tints: [NSColor] = [
        NSColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1),  // purple
        NSColor(red: 0.05, green: 0.6, blue: 0.55, alpha: 1),  // teal
        NSColor(red: 0.93, green: 0.45, blue: 0.1, alpha: 1),  // orange
        NSColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1),  // blue
        NSColor(red: 0.85, green: 0.15, blue: 0.5, alpha: 1),  // pink
    ]

    /// The session of the request being handled (set per request; the default one otherwise).
    @TaskLocal static var current: Session = fallback
    static let fallback = Session(id: "default", ordinal: 0)
    nonisolated(unsafe) static var all: [String: Session] = ["default": fallback]
    static let idle: TimeInterval = 30 * 60

    static func named(_ id: String) -> Session {
        if let s = all[id] { return s }
        let busy = all.values.filter { Date().timeIntervalSince($0.lastUse) < idle }.map(\.ordinal)
        let s = Session(id: id, ordinal: (0...).first { !busy.contains($0) }!)  // the first colour not in use
        all[id] = s
        return s
    }

    /// Let go of what an idle session holds: its pointer, its apps.
    @MainActor static func sweep() {
        for (id, s) in all where Date().timeIntervalSince(s.lastUse) > idle {
            s.end()
            if id != "default" { all[id] = nil }
        }
    }

    @MainActor func end() {
        Hold.release(for: self)
        if hasPointer { pointer.hide() }
        current = nil
    }
}

/// One session drives an app at a time: another session's act on the same app waits its turn (two
/// agents typing into one app would interleave their keys). A wait gives up after `patience`, so two
/// sessions that each hold the app the other wants can't stall for ever.
@MainActor
enum AppLocks {
    private static var owner: [pid_t: String] = [:]
    private static var queue: [pid_t: [(id: Int, session: String, wake: CheckedContinuation<Bool, Never>)]] = [:]
    private static var tickets = 0
    static var patience: TimeInterval = 60

    static func acquire(_ pid: pid_t) async throws {
        let me = Session.current.id
        if owner[pid] == nil || owner[pid] == me {
            owner[pid] = me
            return
        }
        let holder = owner[pid] ?? "?"
        tickets += 1
        let ticket = tickets
        let got = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue[pid, default: []].append((ticket, me, c))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(patience * 1e9))
                if let i = queue[pid]?.firstIndex(where: { $0.id == ticket }) {  // still waiting: give up
                    queue[pid]!.remove(at: i).wake.resume(returning: false)
                }
            }
        }
        if !got {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            throw HelperError("\(name) is being driven by another agent (session \(holder)) and stayed busy for "
                + "\(Int(patience)) s; try again later")
        }
    }

    static func release(_ pid: pid_t) {
        guard owner[pid] == Session.current.id else { return }
        if var waiting = queue[pid], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queue[pid] = waiting
            owner[pid] = next.session  // handed over before it runs, so no one slips in between
            next.wake.resume(returning: true)
        } else {
            owner[pid] = nil
        }
    }
}
