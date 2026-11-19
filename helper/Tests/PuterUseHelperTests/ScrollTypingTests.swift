import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The scroll watch's bookkeeping and the typing pace (no Accessibility permission under `swift test`).
final class ScrollTypingTests: XCTestCase {
    let a = AXUIElementCreateApplication(424_201), b = AXUIElementCreateApplication(424_202)
    let f = CGRect(x: 0, y: 100, width: 50, height: 20)

    /// How far the content moved: the most at any point, unbounded where the element changed; nothing to go
    /// by is "can't tell".
    func testCompareMeasuresMovement() {
        typealias S = ScrollWatch.Spot
        XCTAssertEqual(ScrollWatch.compare([S(element: a, frame: f)], [S(element: a, frame: f)]), 0)
        XCTAssertEqual(ScrollWatch.compare([S(element: a, frame: f), S(element: b, frame: f)],
                                           [S(element: a, frame: f.offsetBy(dx: 0, dy: -40)), S(element: b, frame: f.offsetBy(dx: 0, dy: 12))]), 40)
        XCTAssertEqual(ScrollWatch.compare([S(element: a, frame: f)], [S(element: b, frame: f)]), .infinity)
        XCTAssertEqual(ScrollWatch.compare([S(element: a, frame: f), nil], [S(element: a, frame: f), S(element: b, frame: f)]), 0,
                       "a point with nothing on one look doesn't count")
        XCTAssertNil(ScrollWatch.compare([nil, nil], [nil, S(element: a, frame: f)]))
    }

    /// It looks along the way it scrolls, only inside the window.
    func testWatchLooksAlongTheScrollInsideTheWindow() {
        let down = ScrollWatch(pid: 1, at: CGPoint(x: 100, y: 50), within: CGRect(x: 0, y: 0, width: 400, height: 300), dx: 0, dy: 900)
        XCTAssertTrue(down.vertical)
        XCTAssertTrue(down.forward)
        XCTAssertEqual(down.points, [CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 140)], "the point 90 above is outside the window")
        let left = ScrollWatch(pid: 1, at: CGPoint(x: 200, y: 50), within: .zero, dx: -600, dy: 20)
        XCTAssertFalse(left.vertical)
        XCTAssertFalse(left.forward)
        XCTAssertEqual(left.points.count, 3)
    }

    /// The default pace is 280 WPM: keys come twice as often as at 140.
    @MainActor func testTypingIsTwiceAsFast() {
        XCTAssertEqual(Session(id: "t-pace", ordinal: 7).typist.wpm, 280)
        XCTAssertEqual(Typist(wpm: 280).base * 2, Typist(wpm: 140).base, accuracy: 1e-9)
    }
}
