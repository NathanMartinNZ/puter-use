import XCTest

@testable import PuterUseHelper

/// The cancel and delivery bookkeeping (Requests.swift). There are no Accessibility or Screen Recording
/// permissions under `swift test`, so these drive the bookkeeping directly.
@MainActor
final class RequestsTests: XCTestCase {
    let r1 = RequestKey(client: "c", id: 1), r2 = RequestKey(client: "c", id: 2), r3 = RequestKey(client: "c", id: 3)

    func with<T>(_ k: RequestKey?, _ body: () throws -> T) rethrows -> T {
        try Connection.$current.withValue(Connection(fd: -1, key: k)) { try body() }
    }

    // MARK: hang-up

    /// poll() sees the client hang up even with bytes it sent still unread.
    func testHangUpIsSeenWithUnreadBytes() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }
        let c = Connection(fd: fds[0], key: nil)
        let bytes = Array("{\"id\":2}\n".utf8)
        XCTAssertEqual(write(fds[1], bytes, bytes.count), bytes.count)
        XCTAssertFalse(c.hungUp())
        close(fds[1])
        XCTAssertTrue(c.hungUp())
        XCTAssertTrue(c.hungUp(), "stays hung up")
    }

    func testNoConnectionIsNeverHungUp() throws {
        XCTAssertFalse(Connection.hungUp)
        try Connection.check()
        let gone = Connection(fd: -1, key: nil)
        gone.hangUp()
        try Connection.$current.withValue(gone) {
            XCTAssertThrowsError(try Connection.check()) { XCTAssertTrue($0 is Cancelled) }
        }
    }

    // MARK: turns

    /// A session's requests take turns in order; one whose client left while it waited never runs.
    func testTurnsGoInOrderAndALeaverIsDropped() async throws {
        let turns = Turns()
        try await turns.take()  // the first runs at once
        let gone = Connection(fd: -1, key: nil)
        gone.hangUp()
        let dropped = Task { @MainActor in
            await Connection.$current.withValue(gone) {
                do { try await turns.take(); return false } catch { return error is Cancelled }
            }
        }
        var order: [String] = []
        let second = Task { @MainActor in
            try await turns.take()
            order.append("second")
            turns.done()
        }
        let wasDropped = await dropped.value
        XCTAssertTrue(wasDropped)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(order, [], "waits for the first to finish")
        order.append("first")
        turns.done()
        try await second.value
        XCTAssertEqual(order, ["first", "second"])
        XCTAssertEqual(turns.waiting, 0)
    }

    // MARK: undo logs

    /// A lost request's writes are taken back, back to what its first write replaced; entries a later
    /// request rewrote keep their newer value; writes outside a request are never taken back.
    func testRollbackTakesBackOnlyWhatTheLostRequestStillOwns() {
        let s = Store<Int, String>()
        s[1] = "base"  // no request (a timer)
        with(r1) {
            s[1] = "a"
            s[2] = "x"
            s[1] = "a2"  // its second write: the log keeps the first's "before"
        }
        with(r2) { s[2] = "y" }
        s.rollback(r1)
        XCTAssertEqual(s[1], "base")
        XCTAssertEqual(s[2], "y")
        s.rollback(r1)  // again: nothing left to take back
        XCTAssertEqual(s[1], "base")
    }

    /// Two lost requests in a row on one entry (the consent flow's two acts), taken back latest first or
    /// not, end where the entry was before both.
    func testChainedLostRequestsGoBackPastBoth() {
        for order in [[r2, r1], [r1, r2]] {
            let s = Store<Int, String>()
            with(r3) { s[1] = "seen" }
            s.forget(r3)  // delivered
            with(r1) { s[1] = "one" }
            with(r2) { s[1] = "two" }
            s.rollback(order[0])
            if order[0] == r2 { XCTAssertEqual(s[1], "one") }
            s.rollback(order[1])
            XCTAssertEqual(s[1], "seen", "\(order)")
        }
    }

    func testADeliveredLaterWriteStands() {
        let s = Store<Int, String>()
        with(r1) { s[1] = "one" }
        with(r2) { s[1] = "two" }
        s.forget(r2)
        s.rollback(r1)
        XCTAssertEqual(s[1], "two")
    }

    // MARK: ledger and notes

    func testALostCallsNoteWaitsUntilAReplyCarryingItArrives() {
        let s = Session(id: "t-ledger", ordinal: 7)
        s.enter(r1)
        with(r1) { s.current = 0 }  // the act moved the session to the screen
        var w = Work()
        w.total = 3
        w.done = 1
        w.steps = ["typed 5 characters into \"Name\""]
        w.partial = "action 2 (type) stopped partway: 3 of 6 characters had gone out"
        s.record(r1, w)
        s.lost(r1)
        XCTAssertNil(s.current, "taken back")
        s.lost(r1)  // reported again (it was also seen to hang up): one note
        XCTAssertEqual(s.pending.count, 1)
        let note = s.pending[0].note
        XCTAssertTrue(note.contains("it ran 1 of 3 actions (typed 5 characters into \"Name\")"), note)
        XCTAssertTrue(note.contains("action 2 (type) stopped partway: 3 of 6"), note)
        XCTAssertTrue(note.contains("action 3 didn't run"), note)

        s.enter(r2)
        XCTAssertEqual(s.carry(r2).notes, [note])
        s.account(client: "c", done: [], lost: [2])  // the reply carrying it was lost too
        XCTAssertEqual(s.pending.count, 1, "still waiting")
        s.enter(r3)
        _ = s.carry(r3)
        s.account(client: "c", done: [3], lost: [])
        XCTAssertTrue(s.pending.isEmpty)
    }

    /// The consent flow: an act stops before a press for the user's OK, and the act after it carries on.
    /// Both lost (the second seen to hang up, the first reported later): one note for the whole batch.
    func testABatchCarriedOnAfterAnOKGetsOneNote() {
        let s = Session(id: "t-consent", ordinal: 7)
        s.enter(r1)
        var first = Work()
        first.total = 3
        first.done = 1
        first.steps = ["typed 1 character into \"Name\""]
        s.record(r1, first)
        s.enter(r2)
        var rest = Work()
        rest.first = 1
        rest.total = 2
        rest.done = 1
        rest.steps = ["click \"Delete\""]
        rest.partial = "action 3 (wait) was under way: it may or may not have taken effect"
        s.record(r2, rest)
        s.lost(r2)
        s.lost(r1)
        XCTAssertEqual(s.pending.count, 1)
        let note = s.pending[0].note
        XCTAssertTrue(note.contains("it ran 2 of 3 actions (typed 1 character into \"Name\"; click \"Delete\")"), note)
        XCTAssertTrue(note.contains("action 3 (wait) was under way"), note)
        XCTAssertFalse(note.contains("didn't run"), note)
    }

    func testAReadOnlyCallLeavesNoNote() {
        let s = Session(id: "t-quiet", ordinal: 7)
        s.enter(r1)
        with(r1) { s.meta[5] = nil }
        s.lost(r1)
        XCTAssertTrue(s.pending.isEmpty)
    }

    func testTheLedgerKeepsTheLatest32() {
        let s = Session(id: "t-cap", ordinal: 7)
        for i in 1...40 {
            let k = RequestKey(client: "c", id: i)
            s.enter(k)
            with(k) { s.sentOutlines[CGWindowID(i)] = OutlineDiff.Outline([], interactive: true) }
        }
        XCTAssertEqual(s.ledger.count, Session.ledgerCap)
        XCTAssertEqual(s.ledger.first?.key.id, 9)
        s.lost(RequestKey(client: "c", id: 1))  // aged out: counted as delivered
        XCTAssertNotNil(s.sentOutlines[1])
        s.lost(RequestKey(client: "c", id: 40))
        XCTAssertNil(s.sentOutlines[40])
    }

    /// A request that ages out of the ledger can't be known to have arrived: the notes it carried wait on.
    func testANoteCarriedByAnAgedOutRequestStays() {
        let s = Session(id: "t-cap-notes", ordinal: 7)
        s.enter(r1)
        var w = Work()
        w.total = 1
        w.done = 1
        s.record(r1, w)
        s.lost(r1)
        s.enter(r2)
        _ = s.carry(r2)
        for i in 10..<50 { s.enter(RequestKey(client: "c", id: i)) }
        XCTAssertFalse(s.ledger.contains { $0.key == r2 })
        XCTAssertEqual(s.pending.count, 1)
    }

    /// Going back to a window that's gone would leave the session on nothing: it stays where it is.
    func testTheCurrentWindowStaysIfTheOneBeforeIsGone() {
        let s = Session(id: "t-gone", ordinal: 7)
        with(r1) { s.current = 4_000_000_000 }  // no such window
        s.view.current.forget(r1)
        s.enter(r2)
        with(r2) { s.current = 0 }
        var w = Work()
        w.total = 1
        w.done = 1
        s.record(r2, w)
        s.lost(r2)
        XCTAssertEqual(s.current, 0)
        XCTAssertTrue(s.pending[0].note.contains("window #0 stays the current one"), s.pending[0].note)
    }

    /// The notes go out with a reply to any command, and clear once that reply is reported delivered.
    func testNotesRideOnAWindowsReplyUntilDelivered() async throws {
        let s = Session.named("t-dispatch")
        s.enter(r1)
        var w = Work()
        w.total = 1
        w.done = 1
        w.steps = ["click \"Save\""]
        s.record(r1, w)
        s.lost(r1)
        func windows(_ id: Int, done: [Int] = []) async throws -> [String] {
            let req: [String: Any] = ["id": id, "client": "c", "cmd": "windows", "session": "t-dispatch", "params": [:],
                                      "done": done, "lost": []]
            let reply = await Handlers.dispatch(try JSONSerialization.data(withJSONObject: req))
            let obj = try JSONSerialization.jsonObject(with: try XCTUnwrap(reply).data) as! [String: Any]
            XCTAssertEqual(obj["id"] as? Int, id)
            XCTAssertNil(try XCTUnwrap(reply).written, "this client reports delivery itself")
            return (obj["result"] as? [String: Any])?["notes"] as? [String] ?? []
        }
        let first = try await windows(5)
        XCTAssertTrue(first.contains { $0.contains("click \"Save\"") }, "\(first)")
        let again = try await windows(6)  // 5 not reported yet
        XCTAssertTrue(again.contains { $0.contains("click \"Save\"") })
        let after = try await windows(7, done: [5, 6])
        XCTAssertFalse(after.contains { $0.contains("click \"Save\"") }, "\(after)")
    }

    /// A client that doesn't report delivery (the CLI): a reply written counts as delivered.
    func testAWrittenReplyIsDeliveredForClientsThatDontReport() async throws {
        let s = Session.named("t-cli")
        s.enter(r1)
        var w = Work()
        w.total = 1
        w.done = 1
        s.record(r1, w)
        s.lost(r1)
        let req: [String: Any] = ["id": 9, "client": "cli", "cmd": "windows", "session": "t-cli", "params": [:], "reports": false]
        let sent = await Handlers.dispatch(try JSONSerialization.data(withJSONObject: req))
        let reply = try XCTUnwrap(sent)
        XCTAssertEqual(s.pending.count, 1)
        try XCTUnwrap(reply.written)()
        XCTAssertTrue(s.pending.isEmpty)
    }

    /// (Not through dispatch: the reply's `version` is a main.swift global, which isn't set up under tests.)
    func testStatusSaysItsProtocol() async throws {
        let reply = await Handlers.handle(["id": 1, "cmd": "status"], [:])
        XCTAssertEqual((reply?["result"] as? [String: Any])?["protocol"] as? Int, 2)
    }

    // MARK: app locks

    /// A waiter handed the app just as its client hangs up passes it on rather than keeping it.
    func testAnAppHandedToACancelledWaiterIsReleased() async throws {
        let pid: pid_t = 424_242
        let a = Session.named("lock-a"), b = Session.named("lock-b")
        try await Session.$current.withValue(a) { try await AppLocks.acquire(pid) }
        let conn = Connection(fd: -1, key: nil)
        let waiter = Task { @MainActor in
            await Connection.$current.withValue(conn) {
                await Session.$current.withValue(b) {
                    do { try await AppLocks.acquire(pid); return "got it" } catch { return "\(error)" }
                }
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)  // b is waiting
        conn.hangUp()
        Session.$current.withValue(a) { AppLocks.release(pid) }  // handed to b before its watcher looks
        let outcome = await waiter.value
        XCTAssertEqual(outcome, Cancelled().description)
        XCTAssertNil(AppLocks.holder(pid))
    }

    func testAWaiterWhoseClientLeavesStopsWaiting() async throws {
        let pid: pid_t = 424_243
        let a = Session.named("lock-c"), b = Session.named("lock-d")
        try await Session.$current.withValue(a) { try await AppLocks.acquire(pid) }
        let conn = Connection(fd: -1, key: nil)
        let waiter = Task { @MainActor in
            await Connection.$current.withValue(conn) {
                await Session.$current.withValue(b) {
                    do { try await AppLocks.acquire(pid); return "got it" } catch { return "\(error)" }
                }
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        conn.hangUp()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, Cancelled().description)
        XCTAssertEqual(AppLocks.holder(pid), "lock-c")
        Session.$current.withValue(a) { AppLocks.release(pid) }
    }

    // MARK: input gates

    /// Once the client has hung up, keys and buttons don't go down; ups still go, so nothing stays held.
    func testAHungUpClientSendsNoDownsButStillUps() throws {
        let log = NSTemporaryDirectory() + "pu-gates-\(getpid()).jsonl"
        try? FileManager.default.removeItem(atPath: log)
        Trace.configure(log)
        defer {
            Trace.configure(nil)
            try? FileManager.default.removeItem(atPath: log)
        }
        let r = Route(pid: getpid(), wid: 0, frame: .zero)
        let gone = Connection(fd: -1, key: nil)
        gone.hangUp()
        Connection.$current.withValue(gone) {
            Input.key(0x00, down: true, flags: [], r)
            Input.key(0x00, down: false, flags: [], r)
            Input.mouse(.leftMouseDown, .zero, r)
            Input.mouse(.leftMouseUp, .zero, r)
        }
        Input.key(0x01, down: true, flags: [], r)  // no request: not held back
        Input.key(0x01, down: false, flags: [], r)
        let types = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["type"] as? String
        }
        XCTAssertEqual(types, ["keyup", "up", "keydown", "keyup"])
    }
}
