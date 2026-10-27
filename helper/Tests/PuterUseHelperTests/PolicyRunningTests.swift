import XCTest

@testable import PuterUseHelper

@MainActor
final class PolicyRunningTests: XCTestCase {
    /// The action being run is its own request's: another session's request, handled while this one waits
    /// partway through an action, doesn't see it (or its confirm: true).
    func testAnotherRequestDoesNotSeeTheRunningAction() async {
        let (entered, inside) = AsyncStream<Void>.makeStream()
        let (leave, release) = AsyncStream<Void>.makeStream()
        let first = Task { @MainActor in
            await Policy.$running.withValue(["type": "key", "keys": "return", "confirm": true]) {
                inside.yield()
                for await _ in leave { break }  // between awaits, as an action is while it types or waits
                return Policy.running?["type"] as? String
            }
        }
        for await _ in entered { break }
        let other = await Task { @MainActor in Policy.running }.value  // a request of another session
        XCTAssertNil(other)
        release.yield()
        let own = await first.value
        XCTAssertEqual(own, "key", "the action still sees itself after the wait")
    }

    /// Work an action starts on its way (the tremor of a held button) runs as part of it.
    func testTasksAnActionStartsSeeIt() async {
        let seen = await Policy.$running.withValue(["type": "type"]) {
            await Task { Policy.running?["type"] as? String }.value
        }
        XCTAssertEqual(seen, "type")
        XCTAssertNil(Policy.running)
    }
}
