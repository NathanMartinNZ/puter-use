import XCTest

@testable import PuterUseHelper

/// `act` skips the wait after re-sending the activation record only when the app was already held on
/// that window before this call (`Hold.heldSettled`).
@MainActor
final class HoldSettledTests: XCTestCase {
    func testOnlyAnEarlierHoldOnTheSameWindowSkipsTheWait() {
        let saved = (Hold.held, Hold.fresh)
        defer { (Hold.held, Hold.fresh) = saved }
        let pid: pid_t = 999_001
        Hold.held[pid] = nil
        Hold.fresh.remove(pid)
        XCTAssertFalse(Hold.heldSettled(pid: pid, wid: 10), "not held: wait")

        Hold.held[pid] = 10
        XCTAssertTrue(Hold.heldSettled(pid: pid, wid: 10), "held on this window since an earlier call")
        XCTAssertFalse(Hold.heldSettled(pid: pid, wid: 11), "the hold moves to another of its windows: wait")
        XCTAssertFalse(Hold.heldSettled(pid: pid + 1, wid: 10), "another app")

        Hold.fresh.insert(pid)
        XCTAssertFalse(Hold.heldSettled(pid: pid, wid: 10), "a fresh hold (just told it's active): wait")
    }
}
