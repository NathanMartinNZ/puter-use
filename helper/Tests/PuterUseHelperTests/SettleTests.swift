import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The loop behind every act's screenshot (`Handlers.settle`), with fake plans and frames instead of the screen.
final class SettleTests: XCTestCase {
    /// A frame of the window, alone or with a dark sheet over its middle.
    static func frame(sheet: Bool) -> Shot {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        if sheet {
            ctx.setFillColor(gray: 0.2, alpha: 1)
            ctx.fill(CGRect(x: 50, y: 60, width: 100, height: 60))
        }
        return Shot(image: ctx.makeImage()!, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    /// A plan pictures only the windows there when it was made. A sheet that opens after that gets a new
    /// plan, and what comes back pictures the sheet.
    @MainActor func testASheetThatOpensMidLoopGetsANewPlan() async throws {
        var windows: Set<Int> = [1]
        var plans: [Set<Int>] = [], captures = 0
        let (shot, sig) = try await Handlers.settle(
            basis: { windows },
            makePlan: { plans.append(windows); return windows },
            capture: { plan in
                captures += 1
                if captures == 1 { windows.insert(2) }  // the sheet opens just after the first frame
                return SettleTests.frame(sheet: plan.contains(2))
            },
            pause: {})
        XCTAssertEqual(plans, [[1], [1, 2]])
        XCTAssertEqual(captures, 3, "the first frame with the sheet, then one that matches it")
        XCTAssertEqual(sig, Signature(SettleTests.frame(sheet: true).image))
        XCTAssertEqual(sig, Signature(shot.image))
    }

    /// A sheet's window comes a moment before it's drawn: the new plan's first frame can still look like the
    /// old plan's. That isn't settled; the loop goes on until the sheet shows and holds still.
    @MainActor func testTheFirstFrameOfANewPlanDoesntEndTheLoop() async throws {
        var windows: Set<Int> = [1]
        var captures = 0, sheetFrames = 0
        let (_, sig) = try await Handlers.settle(
            basis: { windows }, makePlan: { windows },
            capture: { plan in
                captures += 1
                if captures == 1 { windows.insert(2) }
                if plan.contains(2) { sheetFrames += 1 }
                return SettleTests.frame(sheet: sheetFrames >= 2)
            },
            pause: {})
        XCTAssertEqual(captures, 4, "old plan, new plan's blank frame, the sheet, the sheet again")
        XCTAssertEqual(sig, Signature(SettleTests.frame(sheet: true).image))
    }

    /// A window that opens while a frame matching the last one is taken: not settled, a new plan.
    @MainActor func testAWindowOpeningDuringAMatchingFrameIsNotSettled() async throws {
        var windows: Set<Int> = [1]
        var plans: [Set<Int>] = [], captures = 0
        let (_, sig) = try await Handlers.settle(
            basis: { windows },
            makePlan: { plans.append(windows); return windows },
            capture: { plan in
                captures += 1
                if captures == 2 { windows.insert(2) }  // during the second frame, which still matches the first
                return SettleTests.frame(sheet: plan.contains(2))
            },
            pause: {})
        XCTAssertEqual(plans, [[1], [1, 2]])
        XCTAssertEqual(captures, 4)
        XCTAssertEqual(sig, Signature(SettleTests.frame(sheet: true).image))
    }

    /// Nothing opens: one plan, and it stops at the second frame as before.
    @MainActor func testNothingChangingKeepsOnePlan() async throws {
        var plans = 0, captures = 0
        _ = try await Handlers.settle(
            basis: { 1 }, makePlan: { plans += 1 },
            capture: { _ in captures += 1; return SettleTests.frame(sheet: false) }, pause: {})
        XCTAssertEqual(plans, 1)
        XCTAssertEqual(captures, 2)
    }

    /// A clock that moves only when the loop waits (0.15 s, or as asked) or captures (0.03 s), as the real
    /// one would.
    final class FakeClock {
        var t = 0.0
        var taken: [Double] = []
        func pause() { t += 0.15 }
        func wait(_ s: Double) { t += s }
        func capture(_ shot: Shot) -> Shot {
            taken.append(t)
            t += 0.03
            return shot
        }
        func capture(sheet: Bool) -> Shot { capture(SettleTests.frame(sheet: sheet)) }
        /// `act`'s early end. Plans take no time here and a capture 0.03 s, so frames that look like `before`
        /// end the loop from `start` + 0.18 s on (when the old loop took its second frame).
        func early(_ before: Signature?, start: Double) -> Handlers.Early {
            Handlers.Early(before: before, start: start, wait: { self.wait($0) })
        }
    }

    /// The window with only a caret (a 1-pixel line) on: a blink, not a change made by the action.
    static func caretFrame() -> Shot {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 110, width: 1, height: 14))
        return Shot(image: ctx.makeImage()!, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    static let plain = Signature(frame(sheet: false).image), withSheet = Signature(frame(sheet: true).image)
    static let caret = Signature(caretFrame().image)

    /// The click showed something (a change from what the agent last saw) and holds still: that's the
    /// answer, at the second frame, long before the floor.
    @MainActor func testAStillFrameThatChangedEndsAtOnce() async throws {
        let clock = FakeClock()
        let (_, sig) = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: true) }, pause: { clock.pause() },
            early: clock.early(SettleTests.plain, start: 0.62), clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 2)
        XCTAssertEqual(sig, SettleTests.withSheet)
    }

    /// Nothing to see yet: frames that still look like before don't end the loop until one is taken at the
    /// floor (when the wait used to take its second frame), even though they match; the last pause is
    /// stretched so that frame lands right on it, not just before.
    @MainActor func testUnchangedFramesWaitForTheFloor() async throws {
        let clock = FakeClock()
        let (_, sig) = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: false) }, pause: { clock.pause() },
            early: clock.early(SettleTests.plain, start: 0.62), clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 5, "frames at 0, 0.18, 0.36, 0.54, then (0.23 s on) one at the floor, 0.80")
        XCTAssertEqual(clock.taken.last!, 0.80, accuracy: 1e-9)
        XCTAssertEqual(sig, SettleTests.plain)
    }

    /// A caret blinking (here: on in every frame, off before) isn't the action's effect: no early end.
    @MainActor func testACaretAloneDoesntEndItEarly() async throws {
        XCTAssertFalse(Handlers.showsChange(SettleTests.caret, from: SettleTests.plain))
        XCTAssertFalse(Handlers.showsChange(SettleTests.plain, from: SettleTests.plain))
        XCTAssertTrue(Handlers.showsChange(SettleTests.withSheet, from: SettleTests.plain))
        XCTAssertTrue(Handlers.showsChange(SettleTests.plain, from: nil))
        let clock = FakeClock()
        let (_, sig) = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(SettleTests.caretFrame()) },
            pause: { clock.pause() }, early: clock.early(SettleTests.plain, start: 0.62), clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 5)
        XCTAssertEqual(clock.taken.last!, 0.80, accuracy: 1e-9)
        XCTAssertEqual(sig, SettleTests.caret, "still the frame as it is (act calls the caret a change)")
    }

    /// The floor is kept even past the usual seven frames (a long settle_ms puts it further out).
    @MainActor func testTheFloorOutlastsTheFrameCount() async throws {
        let clock = FakeClock()
        _ = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: false) }, pause: { clock.pause() },
            early: clock.early(SettleTests.plain, start: 1.82), clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 12, "every 0.18 s up to 1.80, then one at the floor")
        XCTAssertEqual(clock.taken.last!, 2.0, accuracy: 1e-9)
        XCTAssertLessThan(clock.taken[10], 2.0)
    }

    /// A change that shows after a few unchanged frames, still before the floor: caught, and the loop ends
    /// once it holds still.
    @MainActor func testALateChangeBeforeTheFloorIsCaught() async throws {
        let clock = FakeClock()
        let (_, sig) = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: clock.t > 0.4) }, pause: { clock.pause() },
            early: clock.early(SettleTests.plain, start: 0.62), clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 5, "three unchanged frames, then the change twice")
        XCTAssertEqual(clock.taken.last!, 0.72, accuracy: 1e-9)
        XCTAssertEqual(sig, SettleTests.withSheet)
    }

    /// With the early end, a sheet that opens after the first frame still gets a new plan, the new plan's
    /// first frame (still blank, like before) never ends the loop, and the answer pictures the sheet.
    @MainActor func testAReplanStillComesFirstWithTheEarlyEnd() async throws {
        let clock = FakeClock()
        var windows: Set<Int> = [1]
        var plans: [Set<Int>] = [], sheetFrames = 0
        let (_, sig) = try await Handlers.settle(
            basis: { windows }, makePlan: { plans.append(windows); return windows },
            capture: { plan in
                if clock.taken.isEmpty { windows.insert(2) }  // during the first frame
                if plan.contains(2) { sheetFrames += 1 }
                return clock.capture(sheet: sheetFrames >= 2)
            },
            pause: { clock.pause() }, early: clock.early(SettleTests.plain, start: 0), clock: { clock.t })
        XCTAssertEqual(plans, [[1], [1, 2]])
        XCTAssertEqual(clock.taken.count, 4, "old plan, new plan's blank frame, the sheet, the sheet again")
        XCTAssertEqual(sig, SettleTests.withSheet)
    }

    /// No early end (web pages, Electron apps, the screen): the first two matching frames end it, at the
    /// second frame, whatever they look like and however early, as before.
    @MainActor func testWithoutTheEarlyEndTheFirstMatchEndsIt() async throws {
        let clock = FakeClock()
        _ = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: false) }, pause: { clock.pause() },
            clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 2)
    }

    /// Nothing seen before (a first look, or a window the batch moved to): any still frames are the answer.
    @MainActor func testWithNothingSeenBeforeAnyStillFramesEndIt() async throws {
        let clock = FakeClock()
        _ = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: false) }, pause: { clock.pause() },
            early: clock.early(nil, start: 5), clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 2)
    }

    /// The end of a batch waits for a menu after a click, Return or a shortcut, not after typing, nor after
    /// navigate (it waited for its page); typing into a web search box waits for its suggestions.
    func testMenuWaitAfterTheLastAction() {
        XCTAssertTrue(Handlers.menuWait(["type": "click", "target": "Save"], combo: false))
        XCTAssertTrue(Handlers.menuWait(["type": "keypress", "keys": "Return"], combo: false))
        XCTAssertFalse(Handlers.menuWait(["type": "type", "text": "abc"], combo: false))
        XCTAssertTrue(Handlers.menuWait(["type": "type", "text": "abc"], combo: true))
        for k in ["navigate", "goto", "go_to"] {
            XCTAssertFalse(Handlers.menuWait(["type": k, "url": "example.com"], combo: false))
        }
        XCTAssertFalse(Handlers.menuWait(nil, combo: false))
        XCTAssertTrue(Handlers.menuWait(nil, combo: true))
    }

    /// The loop says when the old wait would have ended at the soonest (its second frame captured): when
    /// `act` used to look for a new window again.
    @MainActor func testTheLoopSaysWhenTheWaitUsedToLookAgain() async throws {
        let clock = FakeClock()
        let early = clock.early(SettleTests.plain, start: 0.62)
        _ = try await Handlers.settle(
            basis: { 1 }, makePlan: {}, capture: { _ in clock.capture(sheet: true) }, pause: { clock.pause() },
            early: early, clock: { clock.t })
        XCTAssertEqual(clock.taken.count, 2, "an early end, at 0.18")
        XCTAssertEqual(early.lookedAgain, 0.83, accuracy: 1e-9, "the floor (0.62 + 0.03 + 0.15) and a capture")
    }

    /// After an early end, an action that may open a window a moment later keeps `act` looking for one;
    /// a single click, typing, a scroll or a select don't.
    func testWhatMayOpenAWindowLater() {
        let yes: [[String: Any]] = [
            ["type": "double_click", "target": "Report"], ["type": "click", "x": 1, "y": 2, "count": 2],
            ["type": "click", "x": 1, "y": 2, "clicks": 2], ["type": "right_click", "target": "Row", "item": "Open"],
            ["type": "menu", "item": "File > Open…"], ["type": "keypress", "keys": "Return"],
            ["type": "keypress", "keys": "cmd+n"], ["type": "key", "keys": ["command", "o"]],
            ["type": "keypress", "keys": "Tab Tab Enter"], ["type": "key_up", "keys": "cmd"],
            ["type": "type", "text": "report", "submit": true], ["type": "type", "text": "report\n"],
            ["type": "fill", "fields": [], "submit": true],
        ]
        let no: [[String: Any]] = [
            ["type": "click", "target": "Save"], ["type": "triple_click", "target": "Name"],
            ["type": "keypress", "keys": "Tab"], ["type": "keypress", "keys": "ctrl+a"],
            ["type": "keypress", "keys": "Escape"], ["type": "type", "text": "report"], ["type": "scroll", "scroll_y": 300],
            ["type": "select", "target": "Color", "option": "Red"], ["type": "fill", "fields": [], "submit": "Send"],
        ]
        for a in yes { XCTAssertTrue(Handlers.opensWindow(a), "\(a)") }
        for a in no { XCTAssertFalse(Handlers.opensWindow(a), "\(a)") }
        XCTAssertFalse(Handlers.opensWindow(nil))
    }

    /// The look for a late window: every pause until the time, the last look at or after it; it stops at
    /// the first window found.
    @MainActor func testWatchingForALateWindow() async throws {
        let clock = FakeClock()
        var looks: [Double] = []
        let none = try await Handlers.watchForWindow(
            until: 0.27, look: { looks.append(clock.t); return false }, pause: { clock.wait(0.05) }, clock: { clock.t })
        XCTAssertFalse(none)
        XCTAssertEqual(looks.count, 6)
        XCTAssertGreaterThanOrEqual(looks.last!, 0.27)
        clock.t = 0
        looks = []
        let found = try await Handlers.watchForWindow(
            until: 0.27, look: { looks.append(clock.t); return clock.t > 0.12 }, pause: { clock.wait(0.05) }, clock: { clock.t })
        XCTAssertTrue(found)
        XCTAssertEqual(looks.count, 3, "at 0.05, 0.10 and 0.15, when it's there")
        let late = try await Handlers.watchForWindow(until: 0, look: { true }, pause: {}, clock: { 1 })
        XCTAssertFalse(late, "past the time already: no look")
    }

    /// A window is walked for a web page once: yes is kept; no is looked at again at the next act the first
    /// time (a web view's tree may come only once asked), then after 30 s.
    @MainActor func testAWebPageIsLookedForOncePerWindow() {
        Handlers.webPages = [:]
        var walks = 0
        XCTAssertTrue(Handlers.showsWebPage(7, now: 100) { walks += 1; return true })
        XCTAssertTrue(Handlers.showsWebPage(7, now: 1000) { walks += 1; return false })
        XCTAssertEqual(walks, 1)
        XCTAssertFalse(Handlers.showsWebPage(8, now: 100) { walks += 1; return false })
        XCTAssertFalse(Handlers.showsWebPage(8, now: 101) { walks += 1; return false }, "the first no, looked at again")
        XCTAssertEqual(walks, 3)
        XCTAssertFalse(Handlers.showsWebPage(8, now: 130) { walks += 1; return true })
        XCTAssertEqual(walks, 3, "no again within 30 s")
        XCTAssertTrue(Handlers.showsWebPage(8, now: 132) { walks += 1; return true }, "a page opened in it since")
        XCTAssertEqual(walks, 4)
        XCTAssertFalse(Handlers.showsWebPage(9, now: 100) { walks += 1; return false })
        XCTAssertTrue(Handlers.showsWebPage(9, now: 101) { walks += 1; return true }, "its tree came after the first look")
        Handlers.webPages = [:]
    }

    /// The screen waits in full; a window of an app that's no browser (here, no app at all) doesn't.
    @MainActor func testWhoWaitsInFull() {
        XCTAssertTrue(Handlers.waitsInFull(.screen))
        let w = WinInfo(id: 1, pid: .max, app: "App", title: "", frame: .zero, layer: 0, onScreen: true)
        XCTAssertFalse(Handlers.waitsInFull(.window(w)))
    }

    /// A new plan that can't be made (the window closed) ends the loop with the last frame and its own
    /// signature, from the plan before.
    @MainActor func testAFailedNewPlanKeepsTheLastFrame() async throws {
        var basis = 1, plans = 0
        let (shot, sig) = try await Handlers.settle(
            basis: { basis },
            makePlan: {
                plans += 1
                if plans > 1 { throw HelperError("window 1 no longer exists") }
            },
            capture: { _ in basis = 2; return SettleTests.frame(sheet: false) }, pause: {})
        XCTAssertEqual(plans, 2)
        XCTAssertEqual(sig, Signature(shot.image))
        XCTAssertEqual(shot.rect, CGRect(x: 0, y: 0, width: 200, height: 150))
    }
}
