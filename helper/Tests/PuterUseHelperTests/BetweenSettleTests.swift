import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The wait between a batch's actions after one that may open something (`Run.settle`), with a fake window
/// list and clock: a window that opened during the action itself skips the look for one.
final class BetweenSettleTests: XCTestCase {
    static let size = CGSize(width: 800, height: 560)
    static let sheet: CGWindowID = 7

    func set(_ over: Set<CGWindowID>, size: CGSize? = BetweenSettleTests.size) -> WindowSet {
        WindowSet(over: over, size: size)
    }

    /// Runs the wait. `reads`: the window set on each look after `start` (the last one repeats); `frames`:
    /// the frames over the window on each look (the last one repeats). Returns where it saw a change and its pauses.
    @MainActor func run(start: WindowSet, before: WindowSet?, reads: [WindowSet] = [], frames: [[CGRect]] = [[]])
        async throws -> (Run.Settled, [Double], looks: Int)
    {
        var pauses: [Double] = [], looks = 0, frameLooks = 0
        let seen = try await Run.settle(
            start: start, since: before,
            read: { looks += 1; return reads.isEmpty ? start : reads[min(looks, reads.count) - 1] },
            frames: { _ in frameLooks += 1; return frames[min(frameLooks, frames.count) - 1] },
            pause: { pauses.append($0) })
        return (seen, pauses, looks)
    }

    /// A sheet the action made at once (an accessibility press): it's there as the action ends, so there's
    /// no looking for one, only the wait for it to stop sliding in and draw.
    @MainActor func testASheetMadeDuringTheActionIsWaitedOutWithoutLookingForOne() async throws {
        let sliding = [[CGRect(x: 0, y: -80, width: 320, height: 120)], [CGRect(x: 0, y: -30, width: 320, height: 120)],
                       [CGRect(x: 0, y: 0, width: 320, height: 120)]]
        let (seen, pauses, looks) = try await run(start: set([Self.sheet]), before: set([]), frames: sliding)
        XCTAssertEqual(seen, .action)
        XCTAssertEqual(looks, 0, "no 25 ms looks for something to appear")
        XCTAssertEqual(pauses, [0.04, 0.04, 0.04, 0.08], "until its frame holds still, then a moment to draw")
    }

    /// Nothing changed during the action and nothing opens: the six 25 ms looks, as before.
    @MainActor func testNothingOpeningLooksAsBefore() async throws {
        let (seen, pauses, looks) = try await run(start: set([]), before: set([]))
        XCTAssertEqual(seen, .nothing)
        XCTAssertEqual(looks, 6)
        XCTAssertEqual(pauses, Array(repeating: 0.025, count: 6))
    }

    /// No baseline (another caller, or the action moved to another window): as before, and a sheet that
    /// comes a moment later is still caught and waited out.
    @MainActor func testWithoutABaselineASheetComingLaterIsCaughtAsBefore() async throws {
        let (seen, pauses, looks) = try await run(start: set([]), before: nil,
                                                  reads: [set([]), set([]), set([Self.sheet])],
                                                  frames: [[CGRect(x: 0, y: 0, width: 320, height: 120)]])
        XCTAssertEqual(seen, .after)
        XCTAssertEqual(looks, 3)
        XCTAssertEqual(pauses, [0.025, 0.025, 0.025, 0.04, 0.08])
    }

    /// The same with a baseline that matches: the action opened nothing by itself.
    @MainActor func testWithAMatchingBaselineASheetComingLaterIsCaughtAsBefore() async throws {
        let (seen, pauses, _) = try await run(start: set([3]), before: set([3]), reads: [set([3]), set([3, Self.sheet])])
        XCTAssertEqual(seen, .after)
        XCTAssertEqual(pauses, [0.025, 0.025, 0.04, 0.08])
    }

    /// A sheet that closed during the action, or a resize, isn't an opening: something may still be about to
    /// open (a dialog after a sheet), so it looks as before.
    @MainActor func testAClosingOrAResizeDuringTheActionStillLooks() async throws {
        for (before, start) in [(set([Self.sheet]), set([])), (set([], size: CGSize(width: 700, height: 560)), set([]))] {
            let (seen, pauses, looks) = try await run(start: start, before: before)
            XCTAssertEqual(seen, .nothing)
            XCTAssertEqual(looks, 6)
            XCTAssertEqual(pauses, Array(repeating: 0.025, count: 6))
        }
    }

    /// What counts as opened during the action.
    func testOpenedDuring() {
        XCTAssertFalse(Run.openedDuring(nil, set([Self.sheet])), "no baseline")
        XCTAssertFalse(Run.openedDuring(set([Self.sheet]), set([Self.sheet])), "already there before")
        XCTAssertTrue(Run.openedDuring(set([]), set([Self.sheet])))
        XCTAssertTrue(Run.openedDuring(set([3]), set([Self.sheet])), "one closed and another opened")
        XCTAssertFalse(Run.openedDuring(set([Self.sheet]), set([])), "closed")
        XCTAssertFalse(Run.openedDuring(set([]), set([Self.sheet], size: nil)), "the window itself closed")
    }
}
