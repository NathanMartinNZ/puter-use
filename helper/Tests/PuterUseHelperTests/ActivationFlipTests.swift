import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// An act makes a background window's app active, and the window key for keys: its title bar and what's
/// selected change colour. With a picture the agent was shown to compare with, frames are taken around that
/// (`Handlers.rebase`), so the change of look alone isn't sent as a change, while anything else still is.
final class ActivationFlipTests: XCTestCase {
    /// A 200x150 frame of the window: its title bar pale (inactive) or dark (active and key), with a dark
    /// dialog over its middle or not.
    static func frame(active: Bool = false, dialog: Bool = false) -> Shot {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        ctx.setFillColor(gray: active ? 0.45 : 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 130, width: 200, height: 20))  // (the top: CG's origin is bottom-left)
        if dialog {
            ctx.setFillColor(gray: 0.2, alpha: 1)
            ctx.fill(CGRect(x: 50, y: 40, width: 100, height: 60))
        }
        return Shot(image: ctx.makeImage()!, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    /// What the agent last saw: the window inactive, no dialog.
    static let seen = Signature(frame().image)

    /// A window and what happens to it: its look, what's over it (`basis`), and each step taken, in order.
    @MainActor final class Window {
        var active = false, dialog = false, basis = 1
        var steps: [String] = []
        var failCaptures = Set<Int>()  // captures (1-based) that fail
        var captures = 0

        func capture() -> Shot? {
            captures += 1
            steps.append("capture")
            return failCaptures.contains(captures) ? nil : ActivationFlipTests.frame(active: active, dialog: dialog)
        }
    }

    @MainActor func rebase(_ w: Window, from before: Signature = ActivationFlipTests.seen, blinked: Bool = false,
                           flip: @MainActor (Window) -> Void = { $0.active = true }) async -> Signature? {
        await Handlers.rebase(before, basis: { w.basis }, capture: { w.capture() }, flip: {
            w.steps.append("flip")
            flip(w)
        }, pause: { _ in w.steps.append("pause") }, blinked: { _, _ in blinked })
    }

    /// Nothing changed since the agent's image: the frame after the flip is the new baseline, so the act's
    /// end, compared with it, shows no change for the flip. One frame before, then one after the window's had
    /// a moment to draw, and one more as the look changed (it may still have been drawing).
    @MainActor func testAnUnchangedWindowIsRebasedPastItsNewLook() async {
        let w = Window()
        let new = await rebase(w)
        XCTAssertEqual(new, Signature(Self.frame(active: true).image))
        XCTAssertEqual(w.steps, ["capture", "flip", "pause", "capture", "pause", "capture"])
    }

    /// A flip that changes nothing on screen (an app whose look doesn't follow): one frame after it is enough.
    @MainActor func testAFlipThatChangesNothingTakesOneFrameAfter() async {
        let w = Window()
        let new = await rebase(w, flip: { _ in })
        XCTAssertEqual(new, Self.seen)
        XCTAssertEqual(w.steps, ["capture", "flip", "pause", "capture"])
    }

    /// The window changed by itself since the agent's image (a dialog came up): the baseline stays, so that
    /// change is still shown. The flip still runs, and no frame is taken after it.
    @MainActor func testAnOutsideChangeIsNeverFoldedIn() async {
        let w = Window()
        w.dialog = true
        let new = await rebase(w)
        XCTAssertNil(new)
        XCTAssertEqual(w.steps, ["capture", "flip"])
        XCTAssertTrue(w.active)
    }

    /// Only the text cursor blinked since: as good as unchanged.
    @MainActor func testOnlyTheCursorBlinkingStillRebases() async {
        let w = Window()
        w.dialog = true  // stands in for the cursor's sliver; `blinked` says that's all it is
        let new = await rebase(w, blinked: true)
        XCTAssertEqual(new, Signature(Self.frame(active: true, dialog: true).image))
    }

    /// Something opened as the app became active (a popover it shows again): what's over the window changed,
    /// so nothing is folded in.
    @MainActor func testAWindowThatOpensWithTheFlipIsNotFoldedIn() async {
        let w = Window()
        let new = await rebase(w, flip: { $0.active = true; $0.basis = 2 })
        XCTAssertNil(new)
    }

    /// A frame that can't be taken, before or after: no new baseline, and the flip runs all the same.
    @MainActor func testAFailedCaptureMeansNoRebaseButTheFlipRuns() async {
        let before = Window()
        before.failCaptures = [1]
        let none = await rebase(before)
        XCTAssertNil(none)
        XCTAssertEqual(before.steps, ["capture", "flip"])

        let after = Window()
        after.failCaptures = [2]
        let noneAfter = await rebase(after)
        XCTAssertNil(noneAfter)
        XCTAssertTrue(after.active)
    }

    /// A second frame after the flip that can't be taken: the first one after it is used.
    @MainActor func testTheFirstFrameAfterIsKeptWhenTheSecondFails() async {
        let w = Window()
        w.failCaptures = [3]
        let new = await rebase(w)
        XCTAssertEqual(new, Signature(Self.frame(active: true).image))
    }

    /// The flip's own error (the client hung up) goes to the caller; nothing is taken after it.
    @MainActor func testTheFlipsErrorIsThrown() async {
        struct Gone: Error {}
        let w = Window()
        do {
            _ = try await Handlers.rebase(Self.seen, basis: { w.basis }, capture: { w.capture() },
                                          flip: { throw Gone() }, pause: { _ in }, blinked: { _, _ in false })
            XCTFail("expected the flip's error")
        } catch {
            XCTAssertTrue(error is Gone)
        }
        XCTAssertEqual(w.captures, 1)
    }

    /// Frames are taken only with a picture the agent was shown, of a window on screen, whose app isn't held
    /// on it yet, or that gets keys and isn't key yet. Not again for a window held (and key) since an earlier
    /// act, nor for one whose hold is new and gets no keys (a scroll, a click by accessibility).
    func testWhenTheActStartIsProbed() {
        func probes(seen: Bool = true, onScreen: Bool = true, held: Bool, keys: Bool, key: Bool = false) -> Bool {
            Handlers.probesFlip(seen: seen, onScreen: onScreen, heldHere: held, keys: keys, keyHere: key)
        }
        XCTAssertTrue(probes(held: false, keys: false), "made active for the first time")
        XCTAssertTrue(probes(held: false, keys: true), "made active and key")
        XCTAssertTrue(probes(held: true, keys: true, key: false), "held, but not key yet: keys make it key")
        XCTAssertFalse(probes(held: true, keys: true, key: true), "held and key since an earlier act")
        XCTAssertFalse(probes(held: true, keys: false), "held already, and no keys")
        XCTAssertFalse(probes(seen: false, held: false, keys: true), "no picture the agent saw: nothing to compare with")
        XCTAssertFalse(probes(onScreen: false, held: false, keys: true), "minimized or hidden: it shows the window anyway")
    }

    /// A batch of activate (raise, focus_window) only makes its window key at the start, as keys do, so an
    /// activate on a window already in view shows no change; not with anything else in the batch.
    func testWhatCountsAsOnlyActivating() {
        XCTAssertTrue(Handlers.activatesOnly([["type": "activate"]]))
        XCTAssertTrue(Handlers.activatesOnly([["type": "raise"], ["action": "focus_window"]]))
        XCTAssertFalse(Handlers.activatesOnly([]))
        XCTAssertFalse(Handlers.activatesOnly([["type": "activate"], ["type": "click", "target": "Save"]]))
        XCTAssertFalse(Handlers.activatesOnly([["type": "wait", "ms": 100]]))
    }
}
