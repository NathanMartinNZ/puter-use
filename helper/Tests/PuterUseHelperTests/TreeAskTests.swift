import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// `AXManualAccessibility` is sent at most once per `AX.treeEvery` per app, not on every lookup (`AX.askForTree`).
final class TreeAskTests: XCTestCase {
    let pid: pid_t = 900_001  // above any real pid
    var sent: [pid_t] = []

    override func setUp() {
        AX.treeAsked = [:]
        sent = []
    }

    override func tearDown() { AX.treeAsked = [:] }

    func ask(_ pid: pid_t, at now: TimeInterval, answer: AXError = .success) {
        AX.askForTree(pid, now: now) { sent.append(pid); return answer }
    }

    /// A burst of lookups (typing) sends it once; the first lookup 5 s after the answer sends it again.
    func testSentOncePerInterval() {
        XCTAssertEqual(AX.treeEvery, 5)
        for i in 0..<50 { ask(pid, at: 100 + Double(i) * 0.09) }  // 4.4 s of lookups
        XCTAssertEqual(sent.count, 1)
        ask(pid, at: 104.99)
        XCTAssertEqual(sent.count, 1)
        ask(pid, at: 105)
        XCTAssertEqual(sent.count, 2)
        ask(pid, at: 109.9)
        XCTAssertEqual(sent.count, 2)
    }

    /// Each app has its own clock.
    func testPerApp() {
        ask(pid, at: 100)
        ask(pid + 1, at: 101)
        ask(pid, at: 102)
        ask(pid + 1, at: 102)
        XCTAssertEqual(sent, [pid, pid + 1])
    }

    /// Native apps answer "unsupported" (some "not implemented"): that's an answer too, asked again only
    /// after the interval.
    func testUnsupportedAndNotImplementedCountAsAnswered() {
        for (i, answer) in [AXError.attributeUnsupported, .notImplemented].enumerated() {
            let p = pid + pid_t(i)
            ask(p, at: 100, answer: answer)
            ask(p, at: 101, answer: answer)
            ask(p, at: 105, answer: answer)
        }
        XCTAssertEqual(sent, [pid, pid, pid + 1, pid + 1])
    }

    /// A busy or launching app ("cannot complete") or any other error: the next lookup asks again, and
    /// once it answers, the interval runs from that answer.
    func testNoAnswerIsRetriedOnTheNextLookup() {
        ask(pid, at: 100, answer: .cannotComplete)
        ask(pid, at: 100.1, answer: .cannotComplete)
        ask(pid, at: 100.2, answer: .failure)
        ask(pid, at: 100.3, answer: .invalidUIElement)
        XCTAssertEqual(sent.count, 4)
        ask(pid, at: 100.4)  // answered
        ask(pid, at: 104)
        XCTAssertEqual(sent.count, 5)
        ask(pid, at: 105.4)
        XCTAssertEqual(sent.count, 6)
    }

    /// A clock that went back (can't happen with uptime, but cheap to be safe) sends it.
    func testClockBackSends() {
        ask(pid, at: 100)
        ask(pid, at: 99)
        XCTAssertEqual(sent.count, 2)
    }

    /// The table stays small: answers older than the interval (gone apps, pids the system reuses) are dropped,
    /// recent ones kept, so a recent app is still not asked again.
    func testTableStaysSmall() {
        for i in 0..<200 { ask(pid + pid_t(i), at: 100 + Double(i)) }  // one new app a second
        XCTAssertLessThanOrEqual(AX.treeAsked.count, 32)
        XCTAssertEqual(sent.count, 200)
        ask(pid + 199, at: 300)  // answered at 299
        ask(pid + 196, at: 300)  // at 296
        XCTAssertEqual(sent.count, 200)
        ask(pid + 190, at: 300)  // at 290: due again
        XCTAssertEqual(sent.count, 201)
    }
}
