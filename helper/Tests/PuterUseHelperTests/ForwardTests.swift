import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Bringing an app forward for a moment to redraw one of the agent's windows: when it's done, what the agent is told,
/// and why it wasn't done when that's worth saying.
@MainActor
final class ForwardTests: XCTestCase {
    typealias H = Handlers

    /// The decision with everything allowing it, but for what a test changes.
    func forward(cover: H.Cover = .covered, owner: Owner = .agent, enabled: Bool = true, foreground: Bool = false,
                 drawsCovered: Bool = false, onScreen: Bool = true, otherAgent: Bool = false, sinceLast: TimeInterval? = nil,
                 appFront: Bool = false, quiet: Bool = true, frontFullScreen: Bool = false) -> H.Forward {
        H.forward(cover: cover, owner: owner, enabled: enabled, foreground: foreground, drawsCovered: drawsCovered,
                  onScreen: onScreen, otherAgent: otherAgent, sinceLast: sinceLast, appFront: appFront, quiet: quiet,
                  frontFullScreen: frontFullScreen)
    }

    /// Only a covered window of the session's own, on this Space, with the setting on, out of foreground mode, of an
    /// app that stops drawing covered windows and no other agent is driving, not brought forward in the last 30 s,
    /// while the user is in another app that isn't full screen and has left the keyboard and mouse alone.
    func testWhenAWindowsAppIsBroughtForward() {
        XCTAssertEqual(forward(), .go)
        XCTAssertEqual(forward(sinceLast: 30), .go, "30 s since the last time")
        XCTAssertEqual(forward(enabled: false), .off)
        XCTAssertEqual(forward(foreground: true), .foreground)
        for cover: H.Cover in [.minimized, .otherSpace, .hidden, .inView] {
            XCTAssertEqual(forward(cover: cover), .notCovered, "\(cover)")
        }
        XCTAssertEqual(forward(owner: .user), .notOwn, "never a window of the user's")
        XCTAssertEqual(forward(owner: .shared), .notOwn, "nor one of the agent's the user has used")
        XCTAssertEqual(forward(drawsCovered: true), .drawsOn)
        XCTAssertEqual(forward(onScreen: false), .otherSpace, "bringing its app forward could switch Spaces")
        XCTAssertEqual(forward(otherAgent: true), .otherAgent)
        XCTAssertEqual(forward(sinceLast: 29.9), .recently)
        XCTAssertEqual(forward(sinceLast: 0), .recently)
        XCTAssertEqual(forward(appFront: true), .appInFront)
        XCTAssertEqual(forward(quiet: false), .busy)
        XCTAssertEqual(forward(frontFullScreen: true), .fullScreen)
    }

    /// What can't change is said first, then whether the user is in the app, busy, or in a full-screen app; whether
    /// the front app is full screen is asked only when everything else allows it (it asks that app's accessibility).
    func testWhatIsAskedFirst() {
        XCTAssertEqual(forward(enabled: false, foreground: true, quiet: false), .off)
        XCTAssertEqual(forward(cover: .minimized, owner: .user, quiet: false), .notCovered)
        XCTAssertEqual(forward(owner: .user, appFront: true), .notOwn)
        XCTAssertEqual(forward(sinceLast: 5, appFront: true, quiet: false), .recently)
        XCTAssertEqual(forward(appFront: true, quiet: false, frontFullScreen: true), .appInFront)
        XCTAssertEqual(forward(quiet: false, frontFullScreen: true), .busy)
        var asked = 0
        func fullScreen() -> Bool {
            asked += 1
            return false
        }
        _ = H.forward(cover: .covered, owner: .agent, enabled: true, foreground: false, drawsCovered: false, onScreen: true,
                      otherAgent: false, sinceLast: nil, appFront: false, quiet: false, frontFullScreen: fullScreen())
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(H.forward(cover: .covered, owner: .agent, enabled: true, foreground: false, drawsCovered: false,
                                 onScreen: true, otherAgent: false, sinceLast: nil, appFront: false, quiet: true,
                                 frontFullScreen: fullScreen()), .go)
        XCTAssertEqual(asked, 1)
    }

    /// Only the user being busy, in the app or in a full-screen app is told; the rest is the agent's to know already,
    /// or nothing it could act on.
    func testWhyItWasntBroughtForwardIsToldOnlyWhenItsTheUsers() {
        XCTAssertEqual(H.forwardWhy(.busy, app: "Firefox"), "the user is busy")
        XCTAssertEqual(H.forwardWhy(.appInFront, app: "Firefox"), "the user is in Firefox")
        XCTAssertEqual(H.forwardWhy(.fullScreen, app: "Firefox"), "the user's front app is full screen")
        for d: H.Forward in [.go, .off, .foreground, .notCovered, .notOwn, .drawsOn, .otherSpace, .otherAgent, .recently] {
            XCTAssertNil(H.forwardWhy(d, app: "Firefox"), "\(d)")
        }
    }

    /// The setting as a request carries it: on unless it says "never".
    func testTheSetting() {
        XCTAssertTrue(H.forwardSetting(nil), "on by default")
        XCTAssertTrue(H.forwardSetting("when-needed"))
        XCTAssertTrue(H.forwardSetting(true))
        XCTAssertFalse(H.forwardSetting("never"))
        XCTAssertFalse(H.forwardSetting(" Never "))
    }

    /// A front window is full screen when its accessibility says so, or it's exactly a display (give or take a point);
    /// a window zoomed to fill what's below the menu bar isn't.
    func testAFullScreenFrontWindow() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
        XCTAssertTrue(H.fullScreen(ax: true, frame: nil, displays: displays))
        XCTAssertTrue(H.fullScreen(ax: nil, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), displays: displays))
        XCTAssertTrue(H.fullScreen(ax: false, frame: CGRect(x: 0.5, y: 0, width: 1512, height: 982), displays: displays))
        XCTAssertFalse(H.fullScreen(ax: false, frame: CGRect(x: 0, y: 33, width: 1512, height: 949), displays: displays),
                       "zoomed, under the menu bar")
        XCTAssertFalse(H.fullScreen(ax: nil, frame: nil, displays: displays))
        XCTAssertFalse(H.fullScreen(ax: nil, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), displays: []))
    }

    /// A page's tree back, loaded or loading, shows the window draws again; none, an empty one or one not known doesn't.
    func testAPageTreeBackShowsItDrawsAgain() {
        XCTAssertTrue(H.drawnAgain(tree: .shown))
        XCTAssertTrue(H.drawnAgain(tree: .loading))
        XCTAssertFalse(H.drawnAgain(tree: .missing))
        XCTAssertFalse(H.drawnAgain(tree: .empty))
        XCTAssertFalse(H.drawnAgain(tree: nil))
    }

    /// The note says what was brought forward, for how long, for which window and why, and that focus went back to
    /// the user's app; or how it went otherwise.
    func testTheNoteOnAFlash() {
        func note(_ r: H.Flash) -> String { H.flashNote(r, app: "Firefox", wid: 31, back: "Kea") }
        let what = "Firefox forward for 0.6 s to redraw your window #31 (it had stopped drawing while covered)"
        XCTAssertEqual(note(H.Flash(drawn: true, seconds: 0.63)), "brought \(what), then gave focus back to Kea")
        XCTAssertEqual(note(H.Flash(drawn: false, seconds: 0.61)),
                       "brought \(what), but it didn't draw again; gave focus back to Kea")
        XCTAssertEqual(note(H.Flash(drawn: false, userCame: true, seconds: 0.58)),
                       "brought \(what), but the user started using the keyboard or mouse, so it stopped at once; gave "
                           + "focus back to Kea")
        XCTAssertTrue(note(H.Flash(drawn: true, userCame: true, seconds: 0.6)).contains("stopped at once (it had drawn again);"))
        XCTAssertEqual(note(H.Flash(key: false, seconds: 0.6)),
                       "tried to bring \(what), but #31 didn't come forward; gave focus back to Kea")
        XCTAssertTrue(note(H.Flash(drawn: true, seconds: 0.6, gaveBack: false))
            .hasSuffix("then couldn't give focus back to Kea: Firefox may still be in front, so tell the user"))
    }

    /// Which way a flash brought the app forward and gave the user's app back goes in the helper's trace, not the
    /// agent's note: as apps are asked to, through accessibility once that hadn't taken, or not at all.
    func testTheTraceSaysWhichWayAFlashWent() {
        XCTAssertEqual(H.way(asked: true, fallback: false), .activation)
        XCTAssertEqual(H.way(asked: true, fallback: true), .activation)
        XCTAssertEqual(H.way(asked: false, fallback: true), .accessibility)
        XCTAssertEqual(H.way(asked: false, fallback: false), .none)
        let r = H.Flash(drawn: true, seconds: 0.6304, gaveBack: true, cameBy: .accessibility, backBy: .activation)
        let line = H.flashTrace(r, pid: 87611, wid: 31)
        XCTAssertEqual(line["k"] as? String, "flash")
        XCTAssertEqual(line["came"] as? String, "accessibility")
        XCTAssertEqual(line["back"] as? String, "activation")
        XCTAssertEqual(line["pid"] as? Int, 87611)
        XCTAssertEqual(line["wid"] as? Int, 31)
        XCTAssertEqual(line["drawn"] as? Bool, true)
        XCTAssertEqual(line["ms"] as? Int, 630)
        XCTAssertEqual(H.flashNote(r, app: "Firefox", wid: 31, back: "Kea"), H.flashNote(H.Flash(drawn: true, seconds: 0.6304),
                                                                                         app: "Firefox", wid: 31, back: "Kea"),
                       "the note doesn't say")
    }

    /// When the app wasn't brought forward because of the user, the not-drawn note, error and stop say so beside why
    /// it isn't drawing; otherwise they're as before.
    func testTheNotDrawnMessagesSayWhyItWasntBroughtForward() {
        var f = H.Frozen(unread: false, title: nil, cover: .covered, key: false)
        XCTAssertEqual(H.frozenReasons(f, app: "Firefox"), "it's covered")
        f.notForward = "the user is busy"
        XCTAssertEqual(H.frozenNote(f, app: "Firefox", wid: 7, last: true),
                       "Firefox isn't drawing #7 (it's covered; not brought forward: the user is busy): your last picture of "
                           + "it may be old")
        XCTAssertTrue(H.frozenError(f, app: "Firefox", wid: 7)
            .hasPrefix("Firefox isn't drawing #7 (it's covered; not brought forward: the user is busy): its picture"))
        XCTAssertTrue(H.staleAim(f, app: "Firefox", wid: 7).why
            .contains("(Firefox isn't drawing it: it's covered; not brought forward: the user is busy)"))
        XCTAssertEqual(H.frozenReasons(H.Frozen(cover: .inView, notForward: "the user is in Firefox"), app: "Firefox"),
                       "not brought forward: the user is in Firefox")
        XCTAssertNil(H.frozenReasons(H.Frozen(cover: .inView), app: "Firefox"))
        XCTAssertEqual(H.redrawnSince(app: "Firefox", wid: 7),
                       "the last picture of #7 may be old (Firefox wasn't drawing it then), and #7 has been drawn again "
                           + "since, so coordinates from it can't be trusted")
    }

    /// The app's coming forward is puter-use's own until the time given, so a hold on it isn't dropped for it.
    func testItsOwnBringingForwardIsntTheUsers() {
        let pid: pid_t = 999_991
        defer { Hold.flashing[pid] = nil }
        XCTAssertFalse(Hold.ownActivation(pid))
        Hold.flashing[pid] = .infinity
        XCTAssertTrue(Hold.ownActivation(pid))
        Hold.flashing[pid] = ProcessInfo.processInfo.systemUptime + 1
        XCTAssertTrue(Hold.ownActivation(pid))
        Hold.flashing[pid] = ProcessInfo.processInfo.systemUptime - 0.1
        XCTAssertFalse(Hold.ownActivation(pid), "its notices are the user's again")
    }

    /// A look cut short by a redraw says to look again, should it ever reach the agent.
    func testARedrawSaysToLookAgain() {
        XCTAssertEqual(Redrawn().description, "the window was just drawn again: look again")
    }
}
