import XCTest

@testable import PuterUseHelper

/// The `read` action: text read at its point in a batch (an element's whole text, a page at a time, or a
/// region's), returned in the reply's `reads`. A batch of reads and clipboard actions only shows no image.
final class ActReadTests: XCTestCase {
    func source(_ a: [String: Any]) throws -> Handlers.ReadSource {
        var action: [String: Any] = ["type": "read"]
        action.merge(a) { _, new in new }
        return try Handlers.readSource(action)
    }

    /// Each way of naming what to read; with none, the focused text. Empty values (null) count as not given.
    func testWhatAReadReads() throws {
        guard case .focused = try source([:]) else { return XCTFail("nothing named: the focused text") }
        guard case .focused = try source(["element": NSNull(), "target": NSNull()]) else { return XCTFail("nulls aren't given") }
        guard case .element(12) = try source(["element": 12]) else { return XCTFail("element") }
        guard case .element(7) = try source(["element": "7"]) else { return XCTFail("a number in text is a number") }
        guard case .target(let v) = try source(["target": "Notes"]), v as? String == "Notes" else { return XCTFail("target") }
        guard case .target(let spec) = try source(["target": ["text": "Notes", "role": "textarea"]]),
              (spec as? [String: Any])?["role"] as? String == "textarea" else { return XCTFail("target spec") }
        guard case .element = try source(["element": 3, "offset": 10_000, "limit": 500]) else { return XCTFail("paged") }
    }

    /// A region in either corner order comes back top-left first.
    func testARegionIsReadTopLeftFirst() throws {
        guard case .region(let r) = try source(["region": [300, 400, 10, 20]]) else { return XCTFail("region") }
        XCTAssertEqual(r, Handlers.Region(x0: 10, y0: 20, x1: 300, y1: 400))
        XCTAssertEqual(Handlers.regionName(r), "region (10,20)-(300,400)")
    }

    /// Mistakes fail with what to do instead: two ways of naming at once, a region that isn't four numbers,
    /// a page of a region (its text comes whole), an element that isn't a number.
    func testWhatAReadRefuses() {
        XCTAssertThrowsError(try source(["element": 3, "target": "Notes"])) { e in
            XCTAssertTrue("\(e)".contains("element and target"))
        }
        XCTAssertThrowsError(try source(["target": "Notes", "region": [0, 0, 10, 10]]))
        XCTAssertThrowsError(try source(["region": [0, 0, 10]])) { e in XCTAssertTrue("\(e)".contains("[x0, y0, x1, y1]")) }
        XCTAssertThrowsError(try source(["region": "top half"]))
        XCTAssertThrowsError(try source(["region": [0, 0, 10, 10], "offset": 100])) { e in XCTAssertTrue("\(e)".contains("whole")) }
        XCTAssertThrowsError(try source(["element": "Notes"]))
    }

    /// The region parse screenshot and read share: four numbers, either corner first; else nil.
    func testRegionPoints() {
        XCTAssertEqual(Handlers.regionPoints([5, 6, 1, 2]), Handlers.Region(x0: 1, y0: 2, x1: 5, y1: 6))
        XCTAssertEqual(Handlers.regionPoints([0.5, 1, 2.5, 3]), Handlers.Region(x0: 0.5, y0: 1, x1: 2.5, y1: 3))
        XCTAssertNil(Handlers.regionPoints([1, 2, 3]))
        XCTAssertNil(Handlers.regionPoints(nil))
        XCTAssertNil(Handlers.regionPoints(NSNull()))
        XCTAssertNil(Handlers.regionPoints(["a", "b", "c", "d"]))
    }

    /// Reads with clipboard actions only: nothing on screen changes, so no picture before or after (unless
    /// "always"). A read in a batch that does something else runs at its point, and the batch looks as ever.
    func testABatchOfReadsShowsNoImage() {
        let read: [String: Any] = ["type": "read", "target": "Total"], clip: [String: Any] = ["type": "clipboard"]
        XCTAssertTrue(Handlers.onlyClipboard([read], always: false))
        XCTAssertTrue(Handlers.onlyClipboard([read, clip, ["type": "read", "region": [0, 0, 10, 10]]], always: false))
        XCTAssertFalse(Handlers.onlyClipboard([read], always: true))
        XCTAssertFalse(Handlers.onlyClipboard([["type": "click", "target": "Invoice #42"], read], always: false))
        XCTAssertFalse(Handlers.onlyClipboard([["type": "wait_for", "text": "Total"], read], always: false))
        XCTAssertEqual(Handlers.ending(wantShot: true, always: false, done: 2, stopped: false, failed: false, firstLook: true,
                                       clipboardOnly: true), .status)
    }

    /// A read opens nothing: no wait for a menu or sheet after it, nor a look for a new window.
    func testAReadOpensNothing() {
        XCTAssertFalse(Handlers.mayOpen(["type": "read"]))
        XCTAssertFalse(Handlers.opensWindow(["type": "read", "element": 4]))
        XCTAssertEqual(Handlers.followWait([["type": "read"]], done: 1, failed: false), 0.05)
    }
}
