import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The element a compound action (type, fill) has already looked up goes to its click as `_node`: used as
/// it is, never searched for again, and never saved (no Accessibility permission under `swift test`).
@MainActor
final class ResolvedNodeTests: XCTestCase {
    let node = AX.Node(element: AXUIElementCreateApplication(424_301), frame: CGRect(x: 10, y: 100, width: 30, height: 20),
                       role: "AXTextField", label: "Name", name: "field")

    /// The click aims at the node it was given, not at whatever a search for its target finds now.
    func testActionPointUsesTheGivenNode() async throws {
        let w = WinInfo(id: 424_301, pid: 424_301, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        let got = try await Handlers.actionPoint(["type": "click", "target": "Nowhere", "_pointer": true, "_node": node], .window(w))
        let (p, n) = try XCTUnwrap(got)
        XCTAssertEqual(p, CGPoint(x: 25, y: 110))
        XCTAssertTrue(CFEqual(try XCTUnwrap(n).element, node.element))
    }

    /// A saved step never holds the node: it means nothing after this session, and isn't JSON.
    func testARecordedStepHasNoNode() {
        let w = WinInfo(id: 424_302, pid: 424_302, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        for t: Target in [.screen, .window(w)] {
            let step = Macros.record(["type": "click", "target": "Name", "x": 25, "y": 110, "units": "pt", "_node": node], t)
            XCTAssertNil(step["_node"])
            XCTAssertEqual(step["target"] as? String, "Name")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(step))
        }
    }
}
