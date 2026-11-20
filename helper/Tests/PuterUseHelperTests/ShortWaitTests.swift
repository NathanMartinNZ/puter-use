import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Waits that end as soon as what they wait for has happened: close_window, a select at the end of a
/// batch, and a new window's layout after it's sized or moved on screen.
final class ShortWaitTests: XCTestCase {
    /// A close_window that closed its window ends the batch without the menu wait (one look is left);
    /// one whose window is still there (a sheet asking something) still waits, as other actions do.
    func testAClosedWindowSkipsTheMenuWait() {
        XCTAssertFalse(Handlers.menuWait(["type": "close_window"], combo: false, gone: true))
        XCTAssertFalse(Handlers.menuWait(["type": "close"], combo: false, gone: true))
        XCTAssertTrue(Handlers.menuWait(["type": "close_window"], combo: false, gone: false))
        XCTAssertTrue(Handlers.menuWait(["type": "close_window"], combo: false))
        XCTAssertTrue(Handlers.menuWait(["type": "click", "target": "Close"], combo: false, gone: true), "only close_window")
        XCTAssertFalse(Handlers.menuWait(nil, combo: false, gone: true))
    }

    /// `AX.choose` leaves the wait for its menu to the end of the batch only for the batch's last action,
    /// when the end looks for a menu as long (not in foreground mode). Mid-batch, the check between actions
    /// doesn't wait, so it does.
    func testOnlyTheLastSelectLeavesItsMenuWaitToTheEnd() {
        let select: [String: Any] = ["type": "select", "target": "Color", "option": "Green"]
        let pick: [String: Any] = ["type": "click", "target": "Color", "item": "Blue"]
        func last(_ a: [String: Any], _ last: Bool = true, menuLook: Bool = true) -> Bool {
            Handlers.marked(a, last: last, menuLook: menuLook)["_last"] as? Bool == true
        }
        XCTAssertTrue(last(select))
        XCTAssertTrue(last(pick))
        XCTAssertFalse(last(select, false), "mid-batch")
        XCTAssertFalse(last(pick, false), "mid-batch")
        XCTAssertFalse(last(select, menuLook: false), "foreground: the end doesn't look")
        XCTAssertFalse(last(["type": "navigate", "url": "example.com"]), "the end doesn't wait after navigate")
        XCTAssertFalse(last(["type": "type", "text": "abc"]), "nor after typing")
        XCTAssertFalse(last(["type": "select", "option": "Red", "_last": true], false), "not taken from the request")
        // A batch: only its last action is marked, and nothing else about the actions changes.
        let batch: [[String: Any]] = [select, ["type": "click", "target": "Save"], select]
        let run = batch.indices.map { Handlers.marked(batch[$0], last: $0 == batch.count - 1, menuLook: true) }
        XCTAssertEqual(run.map { $0["_last"] as? Bool == true }, [false, false, true])
        for (a, m) in zip(batch, run) {
            var m = m
            m["_last"] = nil
            XCTAssertEqual(NSDictionary(dictionary: a), NSDictionary(dictionary: m))
        }
    }

    /// A cancelled request's cleanup waits for a menu only if an action that ran (or was cut short: the one at
    /// `done`) could have opened one; after waits, looks, moves and scrolls it just looks once.
    func testCancelCleanupWaitsOnlyAfterSomethingThatCouldOpenAMenu() {
        let waitFor: [String: Any] = ["type": "wait_for", "text": "Never"]
        XCTAssertFalse(Handlers.cancelWait([waitFor], done: 0), "cut short in a wait_for")
        XCTAssertFalse(Handlers.cancelWait([["type": "wait", "ms": 5000]], done: 0))
        XCTAssertFalse(Handlers.cancelWait([["type": "move", "x": 1, "y": 2], ["type": "scroll", "direction": "down"],
                                            ["type": "screenshot"], waitFor], done: 3))
        XCTAssertTrue(Handlers.cancelWait([["type": "click", "target": "Color"], ["type": "wait", "ms": 5000]], done: 1),
                      "a click ran before the wait")
        XCTAssertTrue(Handlers.cancelWait([["type": "click", "target": "Color"]], done: 0), "cut short in the click")
        for a: [String: Any] in [
            ["type": "right_click", "x": 1, "y": 2], ["type": "keypress", "keys": "cmd+n"], ["type": "menu", "path": "File"],
            ["type": "select", "target": "Color", "option": "Blue"], ["type": "type", "text": "ab"],
            ["type": "key_down", "key": "cmd"], ["type": "mouse_down", "button": "right"],
        ] {
            XCTAssertTrue(Handlers.cancelWait([a, waitFor], done: 1), "\(a)")
        }
        XCTAssertFalse(Handlers.cancelWait([waitFor, ["type": "click", "target": "Save"]], done: 0),
                       "the click after the wait never started")
    }

    /// `AX.choose` looks for its menu only once after the pick as the batch's last action in a native app;
    /// in a browser (where `act` waits in full) or a window it can't tell, and mid-batch, it waits as before.
    func testChooseLooksOnceOnlyAtTheEndInNativeApps() {
        XCTAssertTrue(Handlers.looksOnce(menuLater: true, waitsInFull: false))
        XCTAssertFalse(Handlers.looksOnce(menuLater: true, waitsInFull: true), "a browser")
        XCTAssertFalse(Handlers.looksOnce(menuLater: true, waitsInFull: nil), "window not known")
        XCTAssertFalse(Handlers.looksOnce(menuLater: false, waitsInFull: false), "mid-batch")
    }

    /// A pick from a pop-up's menu as the batch's last action makes that act's closing look quiet, for that
    /// session, app and act only, and only once.
    @MainActor func testAPickMakesOnlyItsOwnActsClosingLookQuiet() {
        let a = Session(id: "t-pick-a", ordinal: 1), b = Session(id: "t-pick-b", ordinal: 2)
        Session.$current.withValue(a) {
            a.acts = 5
            Handlers.pickedFromMenu(pid: 42)
            let other = Session.$current.withValue(b) { Handlers.pickedJustNow(pid: 42) }
            XCTAssertFalse(other, "another session")
            XCTAssertFalse(Handlers.pickedJustNow(pid: 43), "another app")
            XCTAssertFalse(Handlers.pickedJustNow(pid: 42), "asked once: forgotten")
            Handlers.pickedFromMenu(pid: 42)
            XCTAssertTrue(Handlers.pickedJustNow(pid: 42))
            XCTAssertFalse(Handlers.pickedJustNow(pid: 42))
            Handlers.pickedFromMenu(pid: 42)
            a.acts = 6  // the next act: its look isn't the pick's
            XCTAssertFalse(Handlers.pickedJustNow(pid: 42))
        }
        XCTAssertNil(Handlers.picked[ObjectIdentifier(a)])
    }

    /// Internal keys a client sends (`_last`, `_node`, `_pointer`, any "_" key) are dropped before the action
    /// runs, in fill's fields and its submit too; everything else stays.
    func testInternalKeysFromTheRequestAreDropped() {
        let fill: [String: Any] = [
            "type": "fill", "_pointer": true,
            "fields": [["target": "Color", "option": "Green", "_last": true],
                       ["target": "Name", "text": "Ada", "_node": "x", "_pointer": true]],
            "submit": ["target": "Save", "_pointer": true, "_last": true],
        ]
        let m = Handlers.marked(fill, last: false, menuLook: true)
        XCTAssertNil(m["_pointer"])
        XCTAssertEqual(m["type"] as? String, "fill")
        let fields = m["fields"] as? [[String: Any]] ?? []
        XCTAssertEqual(fields.map { $0.keys.sorted() }, [["option", "target"], ["target", "text"]])
        XCTAssertEqual((m["submit"] as? [String: Any])?.keys.sorted(), ["target"])
        // As JSON arrives (Foundation arrays and dictionaries).
        let json = try! JSONSerialization.jsonObject(with: Data(
            #"{"type":"fill","fields":[{"target":"Color","option":"Blue","_last":true}],"_node":1}"#.utf8)) as! [String: Any]
        let j = Handlers.marked(json, last: true, menuLook: true)
        XCTAssertNil(j["_node"])
        XCTAssertNil((j["fields"] as? [[String: Any]])?.first?["_last"])
        XCTAssertEqual(j["_last"] as? Bool, true, "set again by puter-use itself: fill is the batch's last action")
        XCTAssertEqual(Handlers.external(["type": "click", "target": "Save", "submit": true])["submit"] as? Bool, true)
    }

    /// The frame poll ends once the window is where it was asked to be, but not before the floor (time to
    /// lay out there); never there, it ends at the cap with the frame it has; a gone window gives nil.
    @MainActor func testTheFramePollWaitsForThePlaceAndTheFloor() async throws {
        let to = CGRect(x: 0, y: 25, width: 480, height: 320)
        var reads = 0
        var start = Date()
        var f = try await Run.framed(timeout: 0.15, floor: 0.05, frame: { reads += 1; return to }) { Run.matches($0, to) }
        XCTAssertEqual(f, to)
        XCTAssertEqual(reads, 1, "there at the first look, after the floor")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        reads = 0
        f = try await Run.framed(timeout: 2, floor: 0, frame: {
            reads += 1
            return reads < 4 ? CGRect(x: -200, y: 25, width: 480, height: 320) : CGRect(x: 0.5, y: 25, width: 480, height: 320.4)
        }) { Run.matches($0, to) }
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(f?.minX, 0.5)

        start = Date()
        f = try await Run.framed(timeout: 0.1, floor: 0.05, frame: { CGRect(x: -200, y: 25, width: 480, height: 320) }) {
            Run.matches($0, to)
        }
        XCTAssertEqual(f?.minX, -200, "the frame it has at the cap")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        let gone = try await Run.framed(timeout: 1, floor: 0, frame: { nil }) { _ in true }
        XCTAssertNil(gone)
    }

    /// Give or take a point at each edge.
    func testMatches() {
        let to = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertTrue(Run.matches(CGRect(x: 10.8, y: 19.2, width: 300, height: 200.5), to))
        XCTAssertFalse(Run.matches(CGRect(x: 12, y: 20, width: 300, height: 200), to), "moved 2 pt")
        XCTAssertFalse(Run.matches(CGRect(x: 10, y: 20, width: 296, height: 200), to), "2 pt narrower")
    }

    /// A frame read on the way (1441x901 for 1440x900) is reported as the size asked for, at its place, so the
    /// "sized to" note never shows a size in between; one an app keeps bigger is reported as it is.
    @MainActor func testResizedReportsTheSizeAskedForNotOneOnTheWay() async throws {
        let box = CGSize(width: 1440, height: 900)
        let f = try await Run.resized(to: box) { CGRect(x: 26, y: 62, width: 1441, height: 901) }
        XCTAssertEqual(f, CGRect(x: 26, y: 62, width: 1440, height: 900))
        let kept = try await Run.resized(to: box, timeout: 0.05) { CGRect(x: 26, y: 62, width: 1500, height: 900) }
        XCTAssertEqual(kept?.size, CGSize(width: 1500, height: 900), "a minimum size the app keeps")
    }

    /// A window sized to the box: the poll takes its floor even when the size is there at once.
    @MainActor func testResizedKeepsItsFloor() async throws {
        let start = Date()
        let f = try await Run.resized(to: CGSize(width: 400, height: 300), floor: 0.05) { CGRect(x: 0, y: 0, width: 400, height: 300) }
        XCTAssertEqual(f?.size, CGSize(width: 400, height: 300))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05)
    }
}
