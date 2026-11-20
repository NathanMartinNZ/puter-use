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

    private func win(_ id: CGWindowID, on: Bool = true) -> WinInfo {
        WinInfo(id: id, pid: 1, app: "App", title: "w\(id)", frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0, onScreen: on)
    }

    private func picked(_ wins: [WinInfo], current: CGWindowID? = nil, own: [CGWindowID] = []) -> String? {
        Handlers.pick(wins, current: current, own: own).map { "\($0.0.id) \($0.1)" }
    }

    /// An app name means: the window the session is on, else its own it used last, else the front one;
    /// on screen before minimized or hidden.
    func testAnAppNamePrefersTheSessionsOwnWindow() {
        let wins = [win(1), win(2), win(3), win(4, on: false)]  // front to back
        XCTAssertEqual(picked(wins), "1 front")  // nothing of its own: as before
        XCTAssertEqual(picked(wins, own: [9]), "1 front")  // its own windows are another app's, or gone
        XCTAssertEqual(picked(wins, current: 0), "1 front")  // on the screen
        XCTAssertEqual(picked(wins, current: 3), "3 current")
        XCTAssertEqual(picked(wins, current: 3, own: [2]), "3 current")  // the one it's on comes first
        XCTAssertEqual(picked(wins, current: 77, own: [2, 3]), "3 own")  // on another app's: its last one here
        XCTAssertEqual(picked(wins, current: 77, own: [3, 2, 9]), "2 own")  // 9 is gone
        // Minimized or on another Space: an on-screen window comes first.
        XCTAssertEqual(picked(wins, current: 4, own: [2]), "2 own")
        XCTAssertEqual(picked(wins, current: 4), "1 front")
        XCTAssertEqual(picked(wins, own: [4]), "1 front")
        // Nothing on screen: the same order among the rest.
        let hidden = [win(5, on: false), win(6, on: false), win(7, on: false)]
        XCTAssertEqual(picked(hidden), "5 front")
        XCTAssertEqual(picked(hidden, current: 7, own: [6]), "7 current")
        XCTAssertEqual(picked(hidden, own: [6]), "6 own")
        XCTAssertNil(picked([], current: 1, own: [1]))
    }

    /// Its own windows in the order it opened or last used them; sessions don't share them.
    func testOwnWindowsAreOrderedByUseAndPerSession() {
        let a = Session(id: "resolve-test-a", ordinal: 1), b = Session(id: "resolve-test-b", ordinal: 2)
        Session.$current.withValue(a) {
            Handlers.agentWindows.insert(11)
            Handlers.agentWindows.insert(12)
            Handlers.agentWindows.insert(11)  // already there: no change
            XCTAssertEqual(a.ownRecent, [11, 12])
            _ = Handlers.used(win(11))
            XCTAssertEqual(a.ownRecent, [12, 11])
            _ = Handlers.used(win(13))  // not its own
            XCTAssertEqual(a.ownRecent, [12, 11])
        }
        Session.$current.withValue(b) {
            _ = Handlers.used(win(11))
            XCTAssertEqual(b.ownRecent, [])
            XCTAssertEqual(b.agentWindows, [])
        }
    }

    /// An app with two windows on screen: the one the session is on, with a note naming the front one, said
    /// once per pair (as `handle` records it in `pickNoted`); none when it's on the front one.
    func testAnAppNameMeansTheWindowItsOnWithANote() throws {
        let front = WinInfo(id: 21, pid: 1, app: "App", title: "Inbox", frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                            layer: 0, onScreen: true)
        let other = win(22), wins = [front, other]  // front to back
        let first = try XCTUnwrap(Handlers.appWindow(wins, query: "app", current: other.id, own: [], noted: []))
        XCTAssertEqual(first.window.id, other.id)
        let note = try XCTUnwrap(first.note)
        XCTAssertEqual(note.text, "\"app\" is the window you're on, #22; App's front window is #21 \"Inbox\"")
        XCTAssertEqual(note.pair, [other.id, front.id])
        let again = try XCTUnwrap(Handlers.appWindow(wins, query: "app", current: other.id, own: [], noted: [note.pair]))
        XCTAssertEqual(again.window.id, other.id)
        XCTAssertNil(again.note)
        let onFront = try XCTUnwrap(Handlers.appWindow(wins, query: "app", current: front.id, own: [], noted: []))
        XCTAssertEqual(onFront.window.id, front.id)
        XCTAssertNil(onFront.note)
        // Its own window (it's on another app's): said so; an untitled front window has no title in the note.
        let untitled = WinInfo(id: 23, pid: 1, app: "App", title: "", frame: front.frame, layer: 0, onScreen: true)
        let own = try XCTUnwrap(Handlers.appWindow([untitled, other], query: "App", current: 99, own: [other.id], noted: []))
        XCTAssertEqual(own.window.id, other.id)
        XCTAssertEqual(own.note?.text, "\"App\" is your own window #22; App's front window is #23")
        XCTAssertNil(Handlers.appWindow([], query: "App", current: 1, own: [1], noted: []))
    }

    /// macOS's dictation orb, shown as an untitled window of the app (often its front one), is never what
    /// its name means while the app has another window; the one it's on (by id earlier) still is.
    func testAnAppNameSkipsTheDictationOrb() {
        let orb = WinInfo(id: 1, pid: 1, app: "App", title: "", frame: CGRect(x: 0, y: 0, width: 280, height: 168),
                          layer: 0, onScreen: true)
        let picked = { (wins: [WinInfo], current: CGWindowID?, own: [CGWindowID]) -> String? in
            Handlers.pick(wins, current: current, own: own, system: { $0.id == orb.id }).map { "\($0.0.id) \($0.1)" }
        }
        XCTAssertEqual(picked([orb, win(2), win(3)], nil, []), "2 front")
        XCTAssertEqual(picked([orb, win(2, on: false)], nil, []), "2 front")  // even minimized: the orb is no window to work in
        XCTAssertEqual(picked([orb, win(2)], 1, []), "1 current")
        XCTAssertEqual(picked([orb, win(2), win(3)], nil, [3]), "3 own")
        XCTAssertEqual(picked([orb], nil, []), "1 front")  // nothing else: as before
        XCTAssertNil(picked([], nil, []))
        // What makes one: an untitled non-standard window, not modal, holding at most one control.
        XCTAssertTrue(Handlers.systemWindow(subrole: "AXDialog", modal: false, children: 1))
        XCTAssertTrue(Handlers.systemWindow(subrole: nil, modal: false, children: 0))
        XCTAssertFalse(Handlers.systemWindow(subrole: "AXDialog", modal: true, children: 1))  // an app's modal alert
        XCTAssertFalse(Handlers.systemWindow(subrole: "AXDialog", modal: false, children: 3))  // text and buttons
        XCTAssertFalse(Handlers.systemWindow(subrole: "AXStandardWindow", modal: false, children: 1))
        // A titled window is never one, and its accessibility element isn't even looked up.
        XCTAssertFalse(Handlers.systemWindow(win(2), { XCTFail("looked up"); return nil }()))
    }

    /// What `windows` and a gone window's note list: an app's windows without the orb, but with its untitled
    /// dialogs, sheets and alerts, and untitled windows with no accessibility element.
    func testTheDictationOrbIsNotListed() {
        func untitled(_ id: CGWindowID) -> WinInfo {
            WinInfo(id: id, pid: 1, app: "App", title: "", frame: CGRect(x: 0, y: 0, width: 280, height: 168), layer: 0, onScreen: true)
        }
        let facts: [CGWindowID: (subrole: String?, modal: Bool, children: Int)] = [
            1: ("AXStandardWindow", false, 5),  // the main window
            2: ("AXDialog", false, 1),  // the orb: one button, "Siri Waveform Orb"
            3: ("AXDialog", false, 4),  // an untitled dialog: its text and buttons
            4: (nil, true, 3),  // a sheet (no subrole), modal
            5: ("AXDialog", true, 1),  // an alert with one control, modal
            6: ("AXFloatingWindow", false, 2),  // an untitled panel
        ]
        let wins = [win(1), untitled(2), untitled(3), untitled(4), untitled(5), untitled(6), untitled(7)]  // 7: no element
        let listed = wins.filter { w in !Handlers.systemWindow(w, facts: { facts[w.id] }) }
        XCTAssertEqual(listed.map(\.id), [1, 3, 4, 5, 6, 7])
    }

    func testAWindowIdStillResolves() throws {
        let w = try XCTUnwrap(Windows.all(onScreenOnly: true).first { Windows.info($0.id) != nil }, "no windows to look up")
        for v: Any in [NSNumber(value: w.id), "\(w.id)", NSNumber(value: Double(w.id))] {
            guard case .window(let got) = try Handlers.resolve(v) else { return XCTFail("\(v) resolved to the screen") }
            XCTAssertEqual(got.id, w.id)
        }
    }
}
