import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// wait_for: where it looks for text (`Handlers.waitScope`), and when {change: true} counts the window as
/// changed (`Handlers.changed`, `Handlers.awaitChange`), with fake frames and a fake clock.
final class WaitForTests: XCTestCase {
    /// A 240x150 frame (one signature cell per pixel), light grey, with dark blocks.
    static func frame(_ blocks: [CGRect] = [], width: Int = 240) -> Signature {
        let ctx = CGContext(data: nil, width: width, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 150))
        ctx.setFillColor(gray: 0.2, alpha: 1)
        for b in blocks { ctx.fill(b) }
        return Signature(ctx.makeImage()!)
    }

    /// The batch's window, what's over it and windows that appeared since the batch began; never another
    /// window of the app that was already on screen (the user's).
    func testTextIsLookedForInTheBatchsWindowsOnly() {
        let shown = [12, 10, 11, 20, 21].map { WaitForTests.win(CGWindowID($0)) }
        let scope = Handlers.waitScope(10, over: [11], shown: shown, atStart: [10, 12]) { $0.id == 21 }
        XCTAssertEqual(scope, [10, 11, 20])
        XCTAssertFalse(scope.contains(12), "the user's window, on screen when the batch began")
        XCTAssertFalse(scope.contains(21), "macOS's dictation orb")
        XCTAssertEqual(Handlers.waitScope(10, over: [], shown: [shown[0], shown[1]], atStart: [10, 12]) { _ in false }, [10])
    }

    static func win(_ id: CGWindowID, pid: pid_t = 1, title: String = "w", _ f: CGRect = CGRect(x: 1000, y: 0, width: 400, height: 300),
                    layer: Int = 0) -> WinInfo {
        WinInfo(id: id, pid: pid, app: "App", title: title, frame: f, layer: layer, onScreen: true)
    }

    /// What ends a change wait as "a new window opened": a window of the app that wasn't on screen when
    /// the batch began, isn't drawn in the target's picture, and isn't macOS's own (the dictation orb).
    func testANewWindowCountsButNotTheDictationOrb() {
        let target = WaitForTests.win(1, CGRect(x: 0, y: 0, width: 800, height: 600))
        let orb = WaitForTests.win(9, title: "", CGRect(x: 900, y: 700, width: 280, height: 168))
        let wins = [target, WaitForTests.win(2), orb,
                    WaitForTests.win(3, CGRect(x: 100, y: 100, width: 400, height: 200)),  // a sheet within it
                    WaitForTests.win(4, CGRect(x: 1000, y: 0, width: 150, height: 40)),  // a tooltip-sized one
                    WaitForTests.win(5, layer: 3), WaitForTests.win(6, pid: 2), WaitForTests.win(7)]
        let got = Handlers.appeared(wins, over: target, atStart: [1, 7], system: { $0.id == orb.id }).map(\.id)
        XCTAssertEqual(got, [2])
        XCTAssertEqual(Handlers.appeared([target, orb], over: target, atStart: [1], system: { _ in false }).map(\.id), [9],
                       "the filter is what keeps the orb out")
    }

    /// A caret or a line of text isn't a change; a redrawn area over 1% of the window, or a picture of
    /// another size, is.
    func testOnlyAChangeOverTheThresholdCounts() {
        let base = WaitForTests.frame()
        XCTAssertFalse(Handlers.changed(from: base, to: base))
        XCTAssertFalse(Handlers.changed(from: base, to: WaitForTests.frame([CGRect(x: 100, y: 40, width: 1, height: 14)])), "a caret")
        XCTAssertFalse(Handlers.changed(from: base, to: WaitForTests.frame([CGRect(x: 20, y: 30, width: 60, height: 4)])),
                       "a line of status text (240 cells, 0.7%)")
        XCTAssertFalse(Handlers.changed(from: base, to: WaitForTests.frame([CGRect(x: 0, y: 0, width: 20, height: 18)])), "1.0%")
        XCTAssertTrue(Handlers.changed(from: base, to: WaitForTests.frame([CGRect(x: 0, y: 0, width: 20, height: 19)])), "1.06%")
        XCTAssertTrue(Handlers.changed(from: base, to: WaitForTests.frame([CGRect(x: 0, y: 40, width: 240, height: 100)])), "a page")
        XCTAssertTrue(Handlers.changed(from: base, to: WaitForTests.frame(width: 200)), "resized")
    }

    /// Looks until one differs enough, pausing between them; small changes on the way don't end it.
    @MainActor func testTheWaitEndsOnTheFirstFrameThatDiffersEnough() async throws {
        let base = WaitForTests.frame()
        var now = 0.0, looks = 0, pauses = 0
        let frames = [base, WaitForTests.frame([CGRect(x: 5, y: 5, width: 8, height: 8)]), nil,
                      WaitForTests.frame([CGRect(x: 0, y: 40, width: 240, height: 100)])]
        let seen = try await Handlers.awaitChange(
            from: base, timeout: 5, look: { looks += 1; return frames[looks - 1] }, window: { false },
            pause: { pauses += 1; now += 0.15 }, clock: { now })
        XCTAssertEqual(seen?.seen, .picture)
        XCTAssertEqual(looks, 4, "a spinner-sized change and a failed capture don't count")
        XCTAssertEqual(pauses, 3)
        XCTAssertEqual(seen?.after ?? -1, 0.45, accuracy: 1e-9)
    }

    /// Nothing changes: nil once the time is up (the caller notes it), after at least one look.
    @MainActor func testNoChangeTimesOut() async throws {
        let base = WaitForTests.frame()
        var now = 0.0, looks = 0
        let seen = try await Handlers.awaitChange(
            from: base, timeout: 1, look: { looks += 1; return WaitForTests.frame([CGRect(x: 100, y: 40, width: 1, height: 14)]) },
            window: { false }, pause: { now += 0.15 }, clock: { now })
        XCTAssertNil(seen)
        XCTAssertEqual(looks, 8, "0, 0.15, … 1.05 s")
        var once = 0
        let none = try await Handlers.awaitChange(from: base, timeout: 0, look: { once += 1; return base }, window: { false },
                                                  pause: { XCTFail("no pause after the time is up") }, clock: { 0 })
        XCTAssertNil(none)
        XCTAssertEqual(once, 1)
    }

    /// A window opening or closing ends it without a look; so does the batch being on another window.
    @MainActor func testAWindowChangeEndsItAtOnce() async throws {
        var opened = false, now = 0.0, looks = 0
        let seen = try await Handlers.awaitChange(
            from: WaitForTests.frame(), timeout: 5, look: { looks += 1; if looks == 2 { opened = true }; return WaitForTests.frame() },
            window: { opened }, pause: { now += 0.15 }, clock: { now })
        XCTAssertEqual(seen?.seen, .window)
        XCTAssertEqual(looks, 2)
        let moved = try await Handlers.awaitChange(from: nil, timeout: 5, look: { XCTFail("no look"); return nil },
                                                   window: { false }, pause: {}, clock: { 0 })
        XCTAssertEqual(moved?.seen, .window)
    }

    /// A cancel during the pause ends the wait with it.
    @MainActor func testACancelStopsTheWait() async {
        do {
            _ = try await Handlers.awaitChange(from: WaitForTests.frame(), timeout: 5, look: { WaitForTests.frame() },
                                               window: { false }, pause: { throw Cancelled() }, clock: { 0 })
            XCTFail("expected Cancelled")
        } catch {
            XCTAssertTrue(error is Cancelled)
        }
    }

    /// A key wait_for doesn't read is refused before anything runs, named, with the key it most likely meant.
    func testAnUnknownWaitForKeyIsRefusedWithAHint() {
        let takes = ": wait_for takes text, role, gone, change, timeout_ms"
        XCTAssertEqual(Handlers.unknownKeys(["type": "wait_for", "text": "Done", "timeout": 5000]),
                       "has an unknown key \"timeout\" (did you mean timeout_ms?)" + takes)
        XCTAssertEqual(Handlers.unknownKeys(["type": "wait_for", "text": "Done", "window": 3, "timeout": 5000]),
                       "has unknown keys \"timeout\" (did you mean timeout_ms?), \"window\" (that's act's own parameter)" + takes)
        let meant = ["timeoutMs": "timeout_ms", "timeout-ms": "timeout_ms", "timeout_s": "timeout_ms", "seconds": "timeout_ms",
                     "target": "text", "query": "text", "txt": "text", "texts": "text", "changed": "change", "gon": "gone",
                     "Role": "role"]
        for (k, want) in meant {
            XCTAssertEqual(Handlers.closest(k, Handlers.waitForKeys), want, k)
            XCTAssertEqual(Handlers.unknownKeys(["type": "wait_for", "text": "x", k: 1]),
                           "has an unknown key \"\(k)\" (did you mean \(want)?)" + takes, k)
        }
        for k in ["window", "element", "x", "until", "id"] {
            XCTAssertNil(Handlers.closest(k, Handlers.waitForKeys), "\(k): nothing close, no guess")
        }
        XCTAssertEqual(Handlers.unknownKeys(["type": "waitfor", "text": "x", "element": 2]), "has an unknown key \"element\"" + takes)
    }

    /// Every wait_for form the docs, the CLI, api.py and macros send still runs. Other actions are checked the
    /// same way, by their own keys (ActionKeysTests).
    func testValidWaitForsPassAndOtherActionsAreCheckedByTheirOwnKeys() {
        let ok: [[String: Any]] = [
            ["type": "wait_for", "text": "Done"],
            ["type": "wait_for", "text": "Done", "role": "text", "gone": true, "timeout_ms": 900],
            ["type": "wait_for", "change": true, "timeout_ms": 4000],
            ["type": "wait_for", "timeout_ms": 5000, "text": "Done", "gone": true],  // api.py's order
            ["type": "wait_for", "role": "button"],
            ["action": "wait_for", "label": "Done", "ms": 500],  // the older names it still reads
            ["type": "waitfor", "text": "Done", "confirm": true],  // CLI --confirm, a confirmed macro's step
            ["type": "wait_for", "text": "Done", "_node": 1, "_last": true],  // puter-use's own (a client's are dropped)
        ]
        for a in ok { XCTAssertNil(Handlers.unknownKeys(a), "\(a)") }
        let others: [[String: Any]] = [
            ["type": "click", "x": 10, "y": 20, "keys": ["shift"], "item": "Red"],
            ["action": "left_click", "coordinate": [10, 20]],
            ["type": "scroll", "scroll_direction": "down", "scroll_amount": 3],
        ]
        for a in others { XCTAssertNil(Handlers.unknownKeys(a), "\(a)") }
        XCTAssertEqual(Handlers.unknownKeys(["type": "wait", "timeout": 5]),
                       "has an unknown key \"timeout\" (did you mean ms?): wait takes ms")
        XCTAssertEqual(Handlers.unknownKeys(["type": "fill", "fields": [["target": "Name", "text": "Ada", "whatever": 1]], "submit": true]),
                       "field 1 has an unknown key \"whatever\": a field takes element, target, text, option, checked, clear")
    }

    func testOnlyAChangeWaitTakesTheStartingPicture() {
        XCTAssertTrue(Handlers.waitsForChange(["type": "wait_for", "change": true]))
        XCTAssertFalse(Handlers.waitsForChange(["type": "wait_for", "text": "Done"]))
        XCTAssertFalse(Handlers.waitsForChange(["type": "wait", "change": true]))
    }
}
