import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Whether an act's picture is sent (`Handlers.shownChange`): what keeps moving by itself left out, then a text
/// cursor blinking. That decides the picture only: a wait for a change, the settle loop and the outline's check
/// that the window changed go by the frames as they are, so a spinner or a progress label that keeps moving
/// still counts there. Frames are `AmbientMaskTests`' (240 px wide: a pixel is a cell).
final class AmbientShownTests: XCTestCase {
    typealias F = AmbientMaskTests

    /// The spinner and the clock's digit, as the frames before the agent's last image saw them move.
    static var moving: [CGRect] {
        var m = Motion()
        let frames = [(0, 0), (1, 1), (2, 2), (3, 0), (0, 1)].map { F.frame(phase: $0.0, tick: $0.1) }
        for (a, b) in zip(frames, frames.dropFirst()) { m.add(a, b) }
        return Ambient.regions(m, perPoint: F.perPoint)
    }

    func shown(_ now: Signature, _ before: Signature, mask: [CGRect], blink: (CellDiff) -> Bool = { _ in false })
        -> (change: (box: CGRect, fraction: Double)?, leftOut: Bool, blinked: Bool) {
        Handlers.shownChange(now, from: before, outW: 952, outH: 595, mask: mask, blink: blink)
    }

    /// Only the spinner and the clock moved: no picture. Everything else that looks at frames still sees it.
    func testOnlyWhatKeepsMovingSendsNoPictureButCountsElsewhere() throws {
        let before = F.frame(phase: 0, tick: 0), now = F.frame(phase: 2, tick: 2)
        let mask = Ambient.mask(known: Self.moving, moving: Self.moving, touched: [], maxSide: F.maxSide)
        XCTAssertEqual(mask.count, 2)
        let s = shown(now, before, mask: mask)
        XCTAssertNil(s.change)
        XCTAssertTrue(s.leftOut)
        XCTAssertFalse(s.blinked)
        // As the frames are: a change all the same.
        let raw = try XCTUnwrap(now.diff(before, outW: now.w, outH: now.h))
        XCTAssertTrue(Handlers.showsChange(now, from: before), "the settle loop's early end")
        XCTAssertNotNil(Handlers.outlineMissed(box: raw.box, cursorField: nil), "the outline's check that the window changed")
        var bigger = F.frame(phase: 2, tick: 2, dark: [CGRect(x: 0, y: 60, width: 240, height: 30)])
        XCTAssertTrue(Handlers.changed(from: before, to: bigger), "a wait for a change")
        bigger = F.frame(phase: 2, tick: 2)
        XCTAssertFalse(Handlers.changed(from: before, to: bigger), "(the spinner alone is under its threshold, as ever)")
    }

    /// Nothing left out: the change as it always was.
    func testWithNoMaskItsTheChangeAsBefore() throws {
        let before = F.frame(phase: 0), now = F.frame(phase: 2)
        let s = shown(now, before, mask: [])
        let old = try XCTUnwrap(now.diff(before, outW: 952, outH: 595))
        XCTAssertEqual(s.change?.box, old.box)
        XCTAssertEqual(s.change?.fraction, old.fraction)
        XCTAssertFalse(s.leftOut)
    }

    /// Something beside what keeps moving changed too: the picture is sent, and its change is all of it (the
    /// spinner's part too), as the frames are.
    func testAPictureSentShowsTheWholeChange() throws {
        let before = F.frame(phase: 0), now = F.frame(phase: 2, dark: [F.label])
        let s = shown(now, before, mask: [F.spinner.insetBy(dx: -1, dy: -1)])
        let old = try XCTUnwrap(now.diff(before, outW: 952, outH: 595))
        XCTAssertEqual(s.change?.box, old.box)
        XCTAssertEqual(s.change?.fraction, old.fraction)
        XCTAssertFalse(s.leftOut)
    }

    /// The cursor check is asked about what's left once the mask is out, and a blink then sends no picture.
    func testTheCursorCheckSeesWhatsLeft() {
        let cursor = CGRect(x: 60, y: 70, width: 1, height: 4)
        let before = F.frame(phase: 0), now = F.frame(phase: 2, dark: [cursor])
        var asked: CGRect?
        let s = shown(now, before, mask: [F.spinner.insetBy(dx: -1, dy: -1)]) { rest in
            asked = rest.box
            return true
        }
        XCTAssertEqual(asked, cursor)
        XCTAssertNil(s.change)
        XCTAssertTrue(s.blinked)
        XCTAssertTrue(s.leftOut)
        let alone = shown(F.frame(dark: [cursor]), F.frame(), mask: []) { _ in true }
        XCTAssertTrue(alone.blinked)
        XCTAssertFalse(alone.leftOut, "nothing was left out: the cursor alone")
    }

    func testOtherSizesAndNoChange() {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let other = shown(Signature(ctx.makeImage()!), F.frame(), mask: [F.spinner])
        XCTAssertEqual(other.change?.box, CGRect(x: 0, y: 0, width: 952, height: 595))
        XCTAssertEqual(other.change?.fraction, 1)
        let none = shown(F.frame(), F.frame(), mask: [F.spinner])
        XCTAssertNil(none.change)
        XCTAssertFalse(none.leftOut)
    }

    // MARK: - a spinner and a clock that ticks once a second, over two waits

    /// `Ambient.watch` with frames handed out in turn (nil once they're used up) and a made-up clock (each pause
    /// 0.15 s): the mask, and how many frames it took.
    @MainActor func watched(_ d: Signature, from before: Signature, known: [CGRect], motion: inout Motion, last: Signature,
                            frames: [Signature]) async throws -> (mask: [CGRect], taken: Int) {
        var taken = 0, ticks = 0
        let mask = try await Ambient.watch(known: known, touched: [], perPoint: F.perPoint, motion: &motion, last: last,
                                           quiet: { self.shown(d, before, mask: $0).change == nil }, frame: {
            defer { taken += 1 }
            return taken < frames.count ? frames[taken] : nil
        }, pause: { ticks += 1 }, clock: { Double(ticks) * 0.15 })
        return (mask, taken)
    }

    /// The agent's screenshot, then two waits on a page with a spinner and a clock ticking once a second. Each act's
    /// own frames, 0.15 s apart, see the spinner turn but not the clock tick. The first wait's picture is sent (nothing
    /// was known to move), and kept with it is all that changed since the screenshot, as only waiting went between.
    /// The second wait's frames see the spinner again; the clock's tick, all that's left, is watched for a moment
    /// longer and seen: no picture.
    @MainActor func testASpinnerAndAClockSendOnePictureThenNone() async throws {
        let screenshot = F.frame(phase: 0, tick: 0)  // (a screenshot keeps no motion)

        // The first wait: frames of the spinner turning, the clock still between them. (The made-up clock's digit
        // goes 164, 166, 168, 164, … across: these ticks keep to where it was seen moving.)
        var motion = Motion()
        let last1 = F.frame(phase: 2, tick: 2)
        motion.add(F.frame(phase: 1, tick: 2), last1)
        let moving1 = Ambient.regions(motion, perPoint: F.perPoint)
        XCTAssertEqual(moving1.count, 1, "only the spinner moved between its frames")
        XCTAssertNotNil(shown(last1, screenshot, mask: []).change, "nothing known to move yet: the picture is sent")
        let kept = Ambient.record(moving1, now: last1, before: screenshot, idle: true, perPoint: F.perPoint)
        XCTAssertTrue(kept.contains { $0.intersects(CGRect(x: 164, y: 40, width: 6, height: 4)) }, "the clock, which ticked since")
        XCTAssertEqual(Ambient.record(moving1, now: last1, before: screenshot, idle: false, perPoint: F.perPoint), moving1,
                       "after a click or keys, only what moved between its frames")

        // The second wait: its frames see the spinner, not the clock, which ticked since the first picture.
        var motion2 = Motion()
        let last2 = F.frame(phase: 0, tick: 3)
        motion2.add(F.frame(phase: 3, tick: 3), last2)
        let mask = Ambient.mask(known: kept, moving: Ambient.regions(motion2, perPoint: F.perPoint), touched: [], maxSide: F.maxSide)
        XCTAssertNotNil(shown(last2, last1, mask: mask).change, "the clock's tick is left")
        let w = try await watched(last2, from: last1, known: kept, motion: &motion2, last: last2,
                                  frames: [F.frame(phase: 1, tick: 3), F.frame(phase: 2, tick: 4), F.frame(phase: 3, tick: 4)])
        XCTAssertEqual(w.taken, 2, "until the clock ticked")
        let s = shown(last2, last1, mask: w.mask)
        XCTAssertNil(s.change, "no picture")
        XCTAssertTrue(s.leftOut)
        XCTAssertEqual(Ambient.regions(motion2, perPoint: F.perPoint).count, 2, "the clock moves in its frames now too")

        // As it was: with only what moved between the first wait's frames kept, the clock isn't known; nothing's
        // watched for, and the picture is sent.
        var unwatched = Motion()
        unwatched.add(F.frame(phase: 3, tick: 3), last2)
        let before = try await watched(last2, from: last1, known: moving1, motion: &unwatched, last: last2, frames: [F.frame(phase: 1, tick: 4)])
        XCTAssertEqual(before.taken, 0)
        XCTAssertNotNil(shown(last2, last1, mask: before.mask).change)
    }

    /// What was moving but stopped (the spinner gone, the clock stopped: the page loaded) is watched for its moment,
    /// and counts: the picture is sent. Something beside what was moving isn't watched for at all.
    @MainActor func testWhatStoppedOrChangedBesideItIsStillAPicture() async throws {
        let first = F.frame(phase: 2, tick: 1)
        let known = Ambient.record([], now: first, before: F.frame(phase: 0, tick: 0), idle: true, perPoint: F.perPoint)
        let stopped = F.frame(phase: 0, tick: 1)
        var motion = Motion()
        motion.add(stopped, stopped)
        let w = try await watched(stopped, from: first, known: known, motion: &motion, last: stopped,
                                  frames: Array(repeating: stopped, count: 20))
        XCTAssertEqual(w.taken, 8, "frames for its moment (1.1 s), no more")
        XCTAssertNotNil(shown(stopped, first, mask: w.mask).change)

        let beside = F.frame(phase: 3, tick: 2, dark: [F.label])
        var turning = Motion()
        turning.add(F.frame(phase: 2, tick: 2), beside)
        let b = try await watched(beside, from: first, known: known, motion: &turning, last: beside, frames: [beside])
        XCTAssertEqual(b.taken, 0)
        XCTAssertNotNil(shown(beside, first, mask: b.mask).change)
    }

    /// Where a batch's pointer went, for what keeps moving to stay in its change there: a scroll's or move's x,y,
    /// the middle of the picture for a scroll given none; nothing to say (nil) for one aimed by element or target.
    @MainActor func testWhereABatchAimed() throws {
        let w = WinInfo(id: 424_701, pid: 424_701, app: "Browser", title: "", frame: CGRect(x: 100, y: 50, width: 400, height: 300),
                        layer: 0, onScreen: true)
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try Session.$current.withValue(Session(id: "t-ambient-aim", ordinal: 1)) {
            Handlers.meta[w.id] = Meta(offset: .zero, size: w.frame.size, width: 800, height: 600, sig: Signature(ctx.makeImage()!))
            let t = Target.window(w)
            XCTAssertEqual(Handlers.aimedPoints([["type": "wait", "ms": 1000]], t), [])
            XCTAssertEqual(Handlers.aimedPoints([["type": "scroll", "x": 200, "y": 100, "scroll_y": 300]], t), [CGPoint(x: 200, y: 100)])
            XCTAssertEqual(Handlers.aimedPoints([["type": "move", "coordinate": [400, 300]]], t), [CGPoint(x: 300, y: 200)])
            XCTAssertEqual(Handlers.aimedPoints([["type": "scroll", "scroll_y": 300]], t), [CGPoint(x: 300, y: 200)], "the middle")
            XCTAssertNil(Handlers.aimedPoints([["type": "scroll", "target": "Results", "scroll_y": 300]], t))
            XCTAssertNil(Handlers.aimedPoints([["type": "hover", "element": 4]], t))
            XCTAssertNil(Handlers.aimedPoints([["type": "move", "x": 900, "y": 10]], t), "off the picture")
            XCTAssertEqual(try Handlers.toGlobal(t, 200, 100), CGPoint(x: 200, y: 100))
        }
    }
}
