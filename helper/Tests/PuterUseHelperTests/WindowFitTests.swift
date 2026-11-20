import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// `PUTER_USE_WINDOW_SIZE` for the windows `navigate` and `open` move the batch to (`Run.moveTo`).
final class WindowFitTests: XCTestCase {
    /// Only a window the batch opened is shrunk; one that was there when it started (the user's) never is,
    /// and with no box nothing is.
    @MainActor func testOnlyWindowsTheBatchOpenedAreSized() {
        let box = CGSize(width: 1280, height: 860)
        let run = Run(target: .screen, foreground: false, guarded: true, box: box)
        let mine: CGWindowID = 4_000_000_001, theirs: CGWindowID = 4_000_000_002
        run.existedBefore.insert(theirs)
        XCTAssertEqual(run.fitBox(for: mine), box)
        XCTAssertNil(run.fitBox(for: theirs))
        if let real = Windows.all().first?.id { XCTAssertNil(run.fitBox(for: real), "a window there at the start") }
        run.existedBefore.insert(mine)  // as moveTo does once it's on it: not sized again
        XCTAssertNil(run.fitBox(for: mine))
        XCTAssertNil(Run(target: .screen, foreground: false, guarded: true, box: nil).fitBox(for: mine))
    }

    /// Waits until the window server shows the new size, then gives that frame.
    @MainActor func testWaitsForTheNewSize() async throws {
        var reads = 0
        let f = try await Run.resized(to: CGSize(width: 1280, height: 860), timeout: 2) {
            reads += 1
            return reads < 3 ? CGRect(x: 10, y: 30, width: 1712, height: 1409) : CGRect(x: 10, y: 30, width: 1280.4, height: 860)
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(f?.size, CGSize(width: 1280, height: 860), "within a point: the size asked for")
        XCTAssertEqual(f?.origin, CGPoint(x: 10, y: 30))
    }

    /// An app that keeps a bigger minimum size: the frame it has when time's up. A window that's gone: nil.
    @MainActor func testGivesUpAfterTheTimeoutAndOnAGoneWindow() async throws {
        let start = Date()
        let f = try await Run.resized(to: CGSize(width: 400, height: 300), timeout: 0.1) {
            CGRect(x: 0, y: 0, width: 500, height: 300)
        }
        XCTAssertEqual(f?.width, 500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let gone = try await Run.resized(to: CGSize(width: 400, height: 300), timeout: 2) { nil }
        XCTAssertNil(gone)
    }

    /// The box is 1440x900 pt unless the request says otherwise; "off" turns it off. A window that size is
    /// captured at full sharpness (only the tile snap trims it) within the token cap.
    @MainActor func testDefaultBoxIs1440x900AndOffTurnsItOff() {
        let box = CGSize(width: 1440, height: 900)
        XCTAssertEqual(Handlers.Opts([:]).windowBox, box)
        XCTAssertNil(Handlers.Opts(["window_size": "off"]).windowBox)
        XCTAssertEqual(Handlers.Opts(["window_size": "1280x860"]).windowBox, CGSize(width: 1280, height: 860))
        let s = Sizing()
        let (w, h) = s.size(for: CGRect(origin: .zero, size: box), native: 2, zoom: false)
        XCTAssertEqual([w, h], [1064, 665])
        XCTAssertLessThanOrEqual(s.tokens(Double(w), Double(h)), Double(s.maxTokens))
    }

    /// Windows of an app that started during the batch, or less than 10 s before it, may be ones it restored
    /// at launch (the user's): they keep their size. An app that's been running longer gets the box.
    func testAppsJustLaunchedKeepTheirWindowSizes() {
        let began = Date()
        XCTAssertTrue(Run.launching(started: began.addingTimeInterval(2), batchBegan: began), "launched by the batch")
        XCTAssertTrue(Run.launching(started: began.addingTimeInterval(-3), batchBegan: began), "launched just before")
        XCTAssertFalse(Run.launching(started: began.addingTimeInterval(-60), batchBegan: began))
        XCTAssertFalse(Run.launching(started: nil, batchBegan: began), "gone")
        let me = Run.startTime(getpid())
        XCTAssertNotNil(me)
        XCTAssertLessThanOrEqual(me ?? .distantFuture, Date())
        XCTAssertGreaterThan(me ?? .distantPast, Date().addingTimeInterval(-3600), "this test process started recently")
        XCTAssertNil(Run.startTime(99_999), "no such process (macOS pids stop at 99998)")
    }

    /// A new window may be the user's when the app is their front app and they've pressed a modifier key or a
    /// mouse button since just before the batch: then it's not followed, shrunk or moved. Either alone is the
    /// agent's. In foreground mode it's still followed (the agent's own input looks like theirs there). Their
    /// typing (Return or Space on a button can open one) stops only the follow, not the shrinking and moving.
    func testWindowTheUserMayHaveOpenedIsLeftAlone() {
        func check(_ launching: Bool, _ front: Bool, _ pressed: Bool, typed: Bool = false, fg: Bool = false,
                   fit: Bool, place: Bool, follow: Bool, users: Bool, line: UInt = #line) {
            let a = Run.arrange(launching: launching, front: front, userPressed: pressed, userTyped: typed, foreground: fg)
            XCTAssertEqual([a.fit, a.place, a.follow, a.users], [fit, place, follow, users], line: line)
        }
        check(false, true, false, typed: true, fit: true, place: true, follow: false, users: false)  // typing here
        check(false, false, false, typed: true, fit: true, place: true, follow: true, users: false)  // typing elsewhere
        check(false, true, false, typed: true, fg: true, fit: true, place: true, follow: true, users: false)
        check(false, false, false, fit: true, place: true, follow: true, users: false)  // background app, user quiet
        check(false, true, false, fit: true, place: true, follow: true, users: false)  // their front app, but idle
        check(false, false, true, fit: true, place: true, follow: true, users: false)  // busy in another app
        check(false, true, true, fit: false, place: false, follow: false, users: true)  // busy in this app: maybe theirs
        check(false, true, true, fg: true, fit: false, place: false, follow: true, users: true)  // foreground, as before
        check(true, false, false, fit: false, place: true, follow: true, users: false)  // launching: keeps its size
        check(true, true, true, fit: false, place: false, follow: false, users: true)
        let box = CGSize(width: 1440, height: 900)
        XCTAssertEqual(Run.leftAloneNote(CGSize(width: 1720, height: 1409), box: box), ", not resized: the user may have opened it")
        XCTAssertEqual(Run.leftAloneNote(CGSize(width: 480, height: 348), box: box), "", "the box wouldn't have changed it")
        XCTAssertEqual(Run.leftAloneNote(CGSize(width: 1720, height: 1409), box: nil), "", "PUTER_USE_WINDOW_SIZE=off")
        XCTAssertGreaterThanOrEqual(Run.sinceUser(Run.opening), 0)
    }

    /// For shrinking and moving, only a modifier key or a mouse button going down counts: typing, letting go,
    /// moving the pointer and scrolling don't. For the follow, a plain key down counts too (`arrange`).
    func testOnlyModifiersAndMouseDownsCount() {
        func since(_ types: [CGEventType], _ recent: CGEventType) -> Double { Run.sinceUser(types) { $0 == recent ? 0.5 : 600 } }
        for t in [CGEventType.flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertEqual(since(Run.opening, t), 0.5, "\(t.rawValue) counts")
        }
        for t in [CGEventType.keyDown, .keyUp, .leftMouseUp, .rightMouseUp, .mouseMoved, .leftMouseDragged, .scrollWheel] {
            XCTAssertEqual(since(Run.opening, t), 600, "\(t.rawValue) doesn't count")
        }
        XCTAssertEqual(since([.keyDown], .keyDown), 0.5, "typing, for the follow")
        XCTAssertEqual(since([.keyDown], .keyUp), 600)
    }

    /// The note for a window that isn't switched to names it, its title and its app, and how to use it.
    func testNotFollowedNote() {
        XCTAssertEqual(Run.notFollowedNote(id: 17950, title: "Inbox", app: "Firefox"),
                       "a new window #17950 \"Inbox\" opened in Firefox while the user was using it: not switched to, "
                           + "as it may be theirs. If your action was meant to open one (cmd+n, a link to a new window), "
                           + "pass window=17950")
        XCTAssertTrue(Run.notFollowedNote(id: 5, title: "", app: "Mail").hasPrefix("a new window #5 opened in Mail while"))
        XCTAssertLessThan(Run.notFollowedNote(id: 5, title: String(repeating: "x", count: 300), app: "Mail").count, 240,
                          "the title is clipped")
    }
}
