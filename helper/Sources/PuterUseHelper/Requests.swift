import AppKit

// A client that gives up on a request (its agent was interrupted, or the call timed out) hangs up. The
// request stops at its next step: nothing more is pressed or typed, and no reply is written. Clients
// also report which replies reached their agent (`done`) and which didn't (`lost`), so what the session
// records as shown to the agent stays true, and the agent hears what a lost call had already done.

/// A request in the delivery bookkeeping: which client sent it, and its id there.
struct RequestKey: Hashable, CustomStringConvertible {
    let client: String
    let id: Int
    var description: String { "\(client.prefix(8))#\(id)" }
}

/// The client gave up on the request: it stops, and no reply is written.
struct Cancelled: Error, CustomStringConvertible {
    var description: String { "cancelled: the client hung up" }
}

/// The request being handled: the connection it came on and who sent it (set per request by
/// `Handlers.dispatch`; nil outside one, as in timers, and for cleanup that must run after a cancel).
final class Connection: @unchecked Sendable {  // only touched on the main thread
    let fd: Int32
    let key: RequestKey?  // nil for a client that doesn't say who it is (an older one): not tracked
    let reports: Bool  // the client reports done/lost; else a reply written counts as delivered
    var work = Work()  // what it has done so far, for a note if its result never reaches the agent
    var windowNote: (text: String, pair: [CGWindowID])?  // the app name it passed meant a window other than the front one
    private var gone = false

    init(fd: Int32, key: RequestKey?, reports: Bool = true) {
        self.fd = fd
        self.key = key
        self.reports = reports
    }

    @TaskLocal static var current: Connection?

    /// The helper is quitting (`Run.stopAll`): every request counts as given up, so it stops at its next step.
    nonisolated(unsafe) static var quitting = false

    /// Whether the client has hung up. poll() reports POLLHUP even with unread bytes waiting, and nothing
    /// else reads the socket while its request runs (`Server.serve` waits for the reply).
    func hungUp() -> Bool {
        if gone || Connection.quitting { return true }
        guard fd >= 0 else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        if poll(&p, 1, 0) > 0, p.revents & Int16(POLLHUP) != 0 { gone = true }
        return gone
    }

    /// Mark it hung up (tests).
    func hangUp() { gone = true }

    static var hungUp: Bool { current?.hungUp() == true }

    /// Stop here if the client has hung up.
    static func check() throws {
        if hungUp { throw Cancelled() }
    }

    /// Run cleanup that must happen even after a cancel (closing a menu, letting go of a button, an
    /// Escape to end a drag): with no connection, nothing in it is held back.
    @MainActor static func ungated<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        try await $current.withValue(nil) { try await body() }
    }
}

/// What a request has done, in short: the note the agent gets if the result never reaches it.
struct Work {
    var window = ""  // e.g. Firefox #144
    var total = 0  // actions in the batch (0: not an act)
    var first = 0  // actions before it (a batch carried on after the user's OK numbers on)
    var done = 0
    var steps: [String] = []  // what each finished action did
    var partial: String?  // the action under way when it was cancelled, and how far it got
    var typed = 0  // characters the action under way has sent
    var did: [String] = []  // what else the action under way has done ("emptied the field", "pressed Return")
    var fields: (done: Int, of: Int)?  // a fill under way: the fields it has filled
    var opened: [CGWindowID] = []

    /// The note, or nil if it did nothing an agent would need to know about.
    func summary() -> String? {
        guard total > 0, done > 0 || partial != nil || !opened.isEmpty else { return nil }
        var parts: [String] = []
        let did = steps.isEmpty ? "" : " (" + steps.joined(separator: "; ") + ")"
        if done > 0 {
            parts.append(done == total ? (total == 1 ? "it ran its action\(did)" : "it ran all \(total) actions\(did)")
                                       : "it ran \(done) of \(total) actions\(did)")
        }
        if let partial { parts.append(partial) }
        let next = first + done + (partial == nil ? 1 : 2), last = first + total
        if next <= last { parts.append(next == last ? "action \(next) didn't run" : "actions \(next)-\(last) didn't run") }
        if !opened.isEmpty { parts.append("opened " + opened.map { "window #\($0)" }.joined(separator: ", ")) }
        // Agents sharing a connection (subagents of one MCP server) share a session: it may not be theirs.
        return "an earlier puter-use call in this session never returned its result (cancelled or timed out), "
            + "after acting" + (window.isEmpty ? "" : " on \(window)") + ": " + parts.joined(separator: "; ")
            + ". Look before redoing any of it"
    }
}

/// A map that knows which request wrote each entry and, per request, what its first write replaced, so
/// the writes of a request whose result never reached the agent can be taken back. Writes outside a
/// tracked request (a timer) have no writer and are never taken back.
final class Store<K: Hashable, V>: @unchecked Sendable {  // only touched on the main thread
    private var values: [K: V] = [:]
    private var writers: [K: RequestKey] = [:]
    private var logs: [RequestKey: [K: (value: V?, writer: RequestKey?)]] = [:]

    subscript(k: K) -> V? {
        get { values[k] }
        set {
            let w = Connection.current?.key
            if let w, logs[w]?.keys.contains(k) != true {  // only its first write: that's what it replaced
                logs[w, default: [:]][k] = (values[k], writers[k])
            }
            writers[k] = w
            values[k] = newValue
        }
    }

    /// `r`'s result reached the agent: its writes stand.
    func forget(_ r: RequestKey) { logs[r] = nil }

    /// Take back what `r` wrote, where no later request has written since. Where one has, that request's
    /// own undo now goes back past `r`. `keep` may refuse a value to go back to (a window that's gone);
    /// returns the keys it refused.
    @discardableResult
    func rollback(_ r: RequestKey, keep: (V?) -> Bool = { _ in true }) -> [K] {
        guard let log = logs.removeValue(forKey: r) else { return [] }
        var refused: [K] = []
        for (k, before) in log {
            if writers[k] == r {
                if keep(before.value) {
                    values[k] = before.value
                    writers[k] = before.writer
                } else {
                    refused.append(k)
                }
            } else if let later = logs.first(where: { $0.value[k]?.writer == r })?.key {
                logs[later]![k] = before
            }
        }
        return refused
    }

    func removeAll() {
        values = [:]
        writers = [:]
        logs = [:]
    }
}

/// One request of a session at a time, in the order they came. A request whose client hangs up while
/// it waits is dropped without running.
final class Turns: @unchecked Sendable {  // only touched on the main thread
    private var line: [Int] = []
    private var tickets = 0

    @MainActor func take() async throws {
        let t = tickets
        tickets += 1
        line.append(t)
        while line.first != t {
            if Connection.hungUp {
                line.removeAll { $0 == t }
                throw Cancelled()
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @MainActor func done() {
        if !line.isEmpty { line.removeFirst() }
    }

    var waiting: Int { max(0, line.count - 1) }
}

/// The session's delivery bookkeeping: requests whose delivery isn't known yet, and notes about lost
/// calls waiting to reach the agent.
extension Session {
    static let ledgerCap = 32

    /// A tracked request is starting.
    @MainActor func enter(_ k: RequestKey) {
        ledger.append((k, Work()))
        while ledger.count > Session.ledgerCap {  // the oldest: its writes stand (its notes wait on)
            let old = ledger.removeFirst().key
            forgetWrites(old)
        }
    }

    /// What `k` did, once it's finished (or stopped).
    @MainActor func record(_ k: RequestKey, _ w: Work) {
        if let i = ledger.firstIndex(where: { $0.key == k }) { ledger[i].work = w }
    }

    /// `k`'s result reached the agent: what it wrote stands, and the notes it carried are delivered.
    @MainActor func delivered(_ k: RequestKey) {
        ledger.removeAll { $0.key == k }
        forgetWrites(k)
        pending.removeAll { $0.carriers.contains(k) }
    }

    /// `k`'s result never reached the agent: take back what it recorded as shown, and tell the agent
    /// (with a later reply) what it did. Once per request; unknown ones (aged out, or already handled)
    /// are ignored.
    @MainActor func lost(_ k: RequestKey) {
        guard let i = ledger.firstIndex(where: { $0.key == k }) else { return }
        var w = ledger.remove(at: i).work
        let live = current
        let stayed = rollbackWrites(k)
        // A batch carried on after the user's OK is two requests (the second numbers on from where the
        // first stopped): one note for both.
        if let j = pending.firstIndex(where: { $0.client == k.client && $0.work.total > 0 && w.total > 0
            && ($0.work.first > 0 && $0.work.first == w.first + w.done || w.first > 0 && w.first == $0.work.first + $0.work.done) }) {
            let other = pending.remove(at: j).work
            let (a, b) = w.first < other.first ? (w, other) : (other, w)
            w = a
            w.done += b.done
            w.steps += b.steps
            w.partial = b.partial
            w.opened += b.opened.filter { !a.opened.contains($0) }
        }
        guard var note = w.summary() else { return }
        if stayed, let live { note += " (window #\(live) stays the current one: the one before it is gone)" }
        notesSeq += 1
        pending.append((notesSeq, k.client, w, note, []))
    }

    /// The reports a request brings: its client's earlier requests that did and didn't reach the agent.
    @MainActor func account(client: String, done: [Int], lost: [Int]) {
        for id in done { delivered(RequestKey(client: client, id: id)) }
        for id in lost.sorted(by: >) { self.lost(RequestKey(client: client, id: id)) }  // latest first
    }

    /// The pending notes, to go with the reply to `k` (which now carries them until it's reported done).
    @MainActor func carry(_ k: RequestKey?) -> (ids: [Int], notes: [String]) {
        guard !pending.isEmpty else { return ([], []) }
        if let k { for i in pending.indices { pending[i].carriers.insert(k) } }
        return (pending.map(\.id), pending.map(\.note))
    }

    /// The reply carrying these notes was written to a client that doesn't report delivery: they're
    /// delivered.
    @MainActor func written(_ k: RequestKey?, notes: [Int]) {
        if let k { delivered(k) }
        pending.removeAll { notes.contains($0.id) }
    }

    private func forgetWrites(_ k: RequestKey) {
        view.current.forget(k)
        view.meta.forget(k)
        view.seen.forget(k)
        view.sentOutlines.forget(k)
        view.carded.forget(k)
        view.told.forget(k)
    }

    /// Returns whether the current window was kept because the one to go back to is gone.
    @MainActor private func rollbackWrites(_ k: RequestKey) -> Bool {
        let stayed = !view.current.rollback(k, keep: { $0 == nil || $0 == 0 || Windows.info($0!) != nil }).isEmpty
        view.meta.rollback(k)
        view.seen.rollback(k)
        view.sentOutlines.rollback(k)
        view.carded.rollback(k)
        view.told.rollback(k)
        return stayed
    }
}

/// Every accessibility call that changes something goes through `act` or `write`, which do nothing once
/// the client has hung up. Cleanup that must still happen after a cancel (closing a menu, collapsing a
/// list) uses `cleanup`. Reads, and switching an app's accessibility on, aren't changes.
extension AX {
    @discardableResult
    static func act(_ el: AXUIElement, _ action: String) -> AXError {
        Connection.hungUp ? .cannotComplete : AXUIElementPerformAction(el, action as CFString)
    }

    @discardableResult
    static func write(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        Connection.hungUp ? .cannotComplete : AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    @discardableResult
    static func cleanup(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    @discardableResult
    static func cleanup(_ el: AXUIElement, set attr: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, value)
    }
}

/// What the session has shown its agent: what coordinates and outline diffs refer to, and which window
/// it's on. Each entry knows the request that wrote it (see `Store`).
final class View: @unchecked Sendable {
    let current = Store<Int, CGWindowID>()  // key 0: the window it's on (0 = whole screen)
    let meta = Store<CGWindowID, Meta>()  // coordinate mapping from the last full screenshot of each window
    let seen = Store<CGWindowID, WindowSet>()  // what was over each window then (`Run.staleCoordinates`)
    /// What each window's next outline changes are against (`OutlineDiff`): the last outline it was sent, with
    /// its lines of no number, its kind and where it was cut; and, past where a cut one stopped, what the agent
    /// still has of the one before.
    let sentOutlines = Store<CGWindowID, OutlineDiff.Outline>()
    let carded = Store<String, Bool>()  // apps it has had an app card for
    /// Where it was last told it is in each window, beside the picture (`Handlers.orient`): a reply that never
    /// reached it takes its news back, so the next one says it again.
    let told = Store<CGWindowID, Orientation>()
}
