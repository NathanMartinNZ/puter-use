import AppKit

/// One agent's state: the window it's working on, what it last saw, its own pointer. Each MCP server
/// (one per agent) and each CLI shell names its session (PUTER_USE_SESSION); requests of different
/// sessions run side by side, and an app is driven by one session at a time (`AppLocks`).
final class Session: @unchecked Sendable {  // only touched on the main thread
    let id: String
    let ordinal: Int
    let view = View()  // what it has shown its agent (each entry knows the request that wrote it)
    var current: CGWindowID? {  // the window it's on; 0 = whole screen
        get { view.current[0] }
        set { view.current[0] = newValue }
    }
    var meta: Store<CGWindowID, Meta> { view.meta }
    var seen: Store<CGWindowID, WindowSet> { view.seen }
    var outlines: Store<CGWindowID, (interactive: Bool, lines: [(Int, String)])> { view.outlines }
    var carded: Store<String, Bool> { view.carded }
    let turns = Turns()  // its requests run one at a time
    var ledger: [(key: RequestKey, work: Work)] = []  // requests whose delivery isn't known yet, oldest first
    // Notes about lost calls, until a reply carrying them is delivered.
    var pending: [(id: Int, client: String, work: Work, note: String, carriers: Set<RequestKey>)] = []
    var notesSeq = 0
    var notes: [String] = []  // remarks for the agent, per request
    var remarks: [String] = []  // from accessibility lookups, folded into notes
    var typist = Typist(wpm: 140)
    var pasteOver = 100
    var agentWindows = Set<CGWindowID>()  // windows this agent opened (navigate uses them)
    var windowApps: [CGWindowID: (app: String, pid: pid_t)] = [:]  // each window it used: "not found" lists its app's others
    var acts = 0  // act requests so far
    var lastClosedMenu: (titles: [String], wid: CGWindowID, act: Int)?  // the last menu it closed, where, and in which act
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
    private enum Wake { case got, timedOut, cancelled }
    private static var owner: [pid_t: String] = [:]
    private static var queue: [pid_t: [(id: Int, session: String, wake: CheckedContinuation<Wake, Never>)]] = [:]
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
        let conn = Connection.current
        let wake = await withCheckedContinuation { (c: CheckedContinuation<Wake, Never>) in
            queue[pid, default: []].append((ticket, me, c))
            Task { @MainActor in  // gives up when the client hangs up, or after `patience`
                let start = Date()
                while let i = queue[pid]?.firstIndex(where: { $0.id == ticket }) {
                    if conn?.hungUp() == true {
                        queue[pid]!.remove(at: i).wake.resume(returning: .cancelled)
                    } else if Date().timeIntervalSince(start) >= patience {
                        queue[pid]!.remove(at: i).wake.resume(returning: .timedOut)
                    } else {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }
        switch wake {
        case .got:
            // Handed over (`release`), but the client may have hung up meanwhile: pass it straight on, as
            // the caller won't hold it.
            if conn?.hungUp() == true {
                release(pid)
                throw Cancelled()
            }
        case .cancelled:
            throw Cancelled()
        case .timedOut:
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            throw HelperError("\(name) is being driven by another agent (session \(holder)) and stayed busy for "
                + "\(Int(patience)) s; try again later")
        }
    }

    /// The session driving `pid`, if any.
    static func holder(_ pid: pid_t) -> String? { owner[pid] }

    static func release(_ pid: pid_t) {
        guard owner[pid] == Session.current.id else { return }
        if var waiting = queue[pid], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queue[pid] = waiting
            owner[pid] = next.session  // handed over before it runs, so no one slips in between
            next.wake.resume(returning: .got)
        } else {
            owner[pid] = nil
        }
    }
}
