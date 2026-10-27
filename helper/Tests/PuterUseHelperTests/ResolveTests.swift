import XCTest

@testable import PuterUseHelper

@MainActor
final class ResolveTests: XCTestCase {
    /// A window id no window can have is "not found", not a crash: CGWindowID is a UInt32.
    func testImpossibleWindowIdsAreNotFound() throws {
        let numbers = try JSONSerialization.jsonObject(with: Data("[-1, 4294967296, 1e300, 2.5]".utf8)) as! [Any]
        let cases: [(Any, String)] = [
            (numbers[0], "-1"), (numbers[1], "4294967296"), (numbers[2], "1e+300"), (numbers[3], "2.5"),
            ("-7", "-7"), ("99999999999", "99999999999"),
        ]
        for (v, shown) in cases {
            XCTAssertThrowsError(try Handlers.resolve(v), "\(v)") { error in
                XCTAssertEqual("\(error)", "window \(shown) not found")
            }
        }
    }

    func testAWindowIdStillResolves() throws {
        let w = try XCTUnwrap(Windows.all(onScreenOnly: true).first { Windows.info($0.id) != nil }, "no windows to look up")
        for v: Any in [NSNumber(value: w.id), "\(w.id)", NSNumber(value: Double(w.id))] {
            guard case .window(let got) = try Handlers.resolve(v) else { return XCTFail("\(v) resolved to the screen") }
            XCTAssertEqual(got.id, w.id)
        }
    }
}
