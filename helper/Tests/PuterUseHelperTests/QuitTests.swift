import XCTest

@testable import PuterUseHelper

/// Quitting stops batches under way in every session (`Run.stopAll`), within a bound.
@MainActor
final class QuitTests: XCTestCase {
    override func tearDown() async throws {
        Connection.quitting = false
        Run.active = [:]
        Run.stopping = nil
        Run.stopped = false
    }

    /// `quit`, a signal and an AppKit quit can each ask to stop: it runs once, and a later ask waits for it.
    func testASecondStopWaitsForTheFirst() async {
        let run = Run(target: .screen, foreground: false, guarded: true, box: nil)
        Run.active[ObjectIdentifier(run)] = (run, Session.named("quit-c"))  // never stops: the bound ends it
        let first = Task { @MainActor in await Run.stopAll(within: 0.3) }
        await Input.ms(50)
        let t = Date()
        await Run.stopAll(within: 5)  // a fresh stop would wait up to 5 s
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.6)
        XCTAssertTrue(Run.stopped)
        XCTAssertTrue(Run.active.isEmpty)
        await first.value
    }

    /// The AppKit quit that `quit`'s own terminate makes ends at once: everything is stopped already.
    func testAnAppKitQuitAfterQuitEndsAtOnce() async {
        await Run.stopAll(within: 1)
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    /// Every request counts as given up; cleanup, which runs ungated, still runs.
    func testQuittingStopsEveryRequestButNotCleanup() async {
        let conn = Connection(fd: -1, key: nil)
        XCTAssertFalse(conn.hungUp())
        Connection.quitting = true
        XCTAssertTrue(conn.hungUp())
        XCTAssertThrowsError(try Connection.$current.withValue(conn) { try Connection.check() })
        let cleanupHeldBack = await Connection.$current.withValue(conn) { await Connection.ungated { Connection.hungUp } }
        XCTAssertFalse(cleanupHeldBack)
    }

    /// A batch that stops at its next step is waited for, not the whole bound.
    func testABatchThatStopsIsWaitedFor() async {
        let run = Run(target: .screen, foreground: false, guarded: true, box: nil)
        let conn = Connection(fd: -1, key: nil)
        Run.active[ObjectIdentifier(run)] = (run, Session.named("quit-a"))
        var sawIt = false
        let batch = Task { @MainActor in  // as act's loop: a step at a time until its client is gone
            await Connection.$current.withValue(conn) {
                while !Connection.hungUp { await Input.ms(20) }
            }
            sawIt = true
            await Input.ms(50)  // its own cleanup
            Run.active[ObjectIdentifier(run)] = nil
        }
        let t = Date()
        await Run.stopAll(within: 2)
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.6)
        XCTAssertTrue(sawIt)
        XCTAssertTrue(Run.active.isEmpty)
        await batch.value
    }

    /// One that doesn't stop is let go of once the bound is up: quit never hangs on it.
    func testABatchThatDoesNotStopIsAbandonedAfterTheBound() async {
        let run = Run(target: .screen, foreground: false, guarded: true, box: nil)
        Run.active[ObjectIdentifier(run)] = (run, Session.named("quit-b"))
        let t = Date()
        await Run.stopAll(within: 0.2)
        let took = Date().timeIntervalSince(t)
        XCTAssertGreaterThanOrEqual(took, 0.2)
        XCTAssertLessThan(took, 0.6)
        XCTAssertTrue(Run.active.isEmpty)
    }

    /// With nothing under way it's immediate.
    func testNothingUnderWayIsImmediate() async {
        let t = Date()
        await Run.stopAll(within: 1)
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.1)
    }
}
