import XCTest

@testable import PuterUseHelper

/// Which windows are the agent's: one it opened stays its own until there are signs the user took it over
/// (`Handlers.takeover`), or its session leaves it unused for two hours; replies say whose a window is; close_window
/// leaves alone one that may hold the user's tabs; and an address typed into a browser's page stops before typing.
@MainActor
final class OwnershipTests: XCTestCase {
    // MARK: - the takeover rule

    /// A change alone keeps the window, told only for another site or tab count (not a title alone: a clock or an
    /// unread count keeps changing one). With signs the user was in the window: another site or tab count makes it
    /// theirs, any other change marks it used by them. No change, nothing to tell, whoever was there.
    func testTheTakeoverRule() {
        func rule(title: Bool = false, tabs: Bool = false, host: Bool = false, there: Bool) -> Handlers.Takeover {
            Handlers.takeover(titleChanged: title, tabsChanged: tabs, hostChanged: host, userWasThere: there)
        }
        XCTAssertEqual(rule(there: false), .keep)
        XCTAssertEqual(rule(there: true), .keep, "the user was in the window, but it's as it was")
        XCTAssertEqual(rule(host: true, there: true), .keep, "the title and tabs are what tell a change")
        XCTAssertEqual(rule(title: true, there: false), .keep, "a live title, a page's own route change: not told")
        XCTAssertEqual(rule(title: true, host: true, there: false), .changed, "a redirect to another site")
        XCTAssertEqual(rule(host: true, there: false), .changed)
        XCTAssertEqual(rule(tabs: true, there: false), .changed)
        XCTAssertEqual(rule(title: true, there: true), .tag)
        XCTAssertEqual(rule(title: true, host: true, there: true), .drop)
        XCTAssertEqual(rule(tabs: true, there: true), .drop)
        XCTAssertEqual(rule(title: true, tabs: true, there: true), .drop)
    }

    /// A reading that couldn't be taken (no address yet, no tab group) is never a change.
    func testReadingsDifferOnlyWhenBothAreKnown() {
        XCTAssertTrue(Handlers.differs("a.com", "b.com"))
        XCTAssertFalse(Handlers.differs("a.com", "a.com"))
        XCTAssertFalse(Handlers.differs(nil as String?, "b.com"))
        XCTAssertFalse(Handlers.differs("a.com", nil as String?))
        XCTAssertTrue(Handlers.differs(1, 2))
        XCTAssertFalse(Handlers.differs(nil as Int?, nil as Int?))
    }

    /// Hosts are compared without case or "www."; a page with none (a new tab) has none to compare.
    func testAPagesHost() {
        XCTAssertEqual(Handlers.host(of: "https://WWW.Example.com/a?b"), "example.com")
        XCTAssertEqual(Handlers.host(of: "http://localhost:3000/admin"), "localhost")
        XCTAssertNil(Handlers.host(of: "about:blank"))
        XCTAssertNil(Handlers.host(of: nil))
        XCTAssertNil(Handlers.host(of: ""))
    }

    /// Two hours without its session using it, and a window is the user's again.
    func testOwnershipExpiresAfterTwoHours() {
        let now = Date()
        XCTAssertFalse(Handlers.expired(now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(Handlers.expired(now.addingTimeInterval(-2 * 3600 + 1), now: now))
        XCTAssertTrue(Handlers.expired(now.addingTimeInterval(-2 * 3600 - 1), now: now))
    }

    /// What the agent is told: another site or tab count, a window marked used by the user, or one given to them
    /// (with navigate's way out in a browser).
    func testWhatTheAgentIsToldAboutItsWindows() {
        func note(_ v: Handlers.Takeover, title: String = "Dashboard", browser: Bool = true, tagged: Bool = false,
                  host: String? = nil, tabs: (then: Int, now: Int)? = nil) -> String? {
            Handlers.ownershipNote(v, id: 7, title: title, browser: browser, tagged: tagged, host: host, tabs: tabs)
        }
        XCTAssertNil(note(.keep))
        XCTAssertEqual(note(.changed, host: "example.org"),
                       "#7 changed since your last call: it now shows example.org (\"Dashboard\")")
        XCTAssertEqual(note(.changed, tabs: (then: 1, now: 3)),
                       "#7 changed since your last call: it now has 3 tabs (it had 1) and shows \"Dashboard\"")
        XCTAssertEqual(note(.changed, host: "example.org", tabs: (then: 1, now: 2)),
                       "#7 changed since your last call: it now shows example.org (\"Dashboard\") and has 2 tabs (it had 1)")
        XCTAssertEqual(note(.changed, title: "", host: "example.org"), "#7 changed since your last call: it now shows example.org")
        XCTAssertNil(note(.changed), "a title alone isn't told")
        XCTAssertEqual(note(.tag), "#7 is still yours, but the user has used it since (it now shows \"Dashboard\")")
        XCTAssertEqual(note(.tag, tagged: true), "#7 now shows \"Dashboard\" (changed since your last call)",
                       "marked before: only the change is news")
        XCTAssertNil(note(.tag, title: "", tagged: true), "nothing to show")
        XCTAssertEqual(note(.drop), "#7 was yours, but the user has used it since (it now shows \"Dashboard\"): it's treated "
            + "as theirs now; navigate opens a new window")
        XCTAssertEqual(note(.drop, browser: false), "#7 was yours, but the user has used it since (it now shows \"Dashboard\"): "
            + "it's treated as theirs now")
    }

    // MARK: - the user's visits to an app

    typealias Span = Fronts.Span
    typealias Presses = Fronts.Presses

    func p(_ keys: UInt32, _ clicks: UInt32) -> Presses { Presses(keys: keys, clicks: clicks) }

    /// Each app that comes to the front closes the span of the one before, with that app's key window and the user's
    /// key presses and clicks then; the same app again changes nothing, and spans long over are let go.
    func testFrontSpans() {
        var spans = Fronts.after([], front: 1, at: 0, input: p(100, 50))
        XCTAssertEqual(spans, [Span(pid: 1, from: 0, start: p(100, 50))])
        XCTAssertEqual(Fronts.after(spans, front: 1, at: 5, input: p(120, 52), key: 70), spans)
        spans = Fronts.after(spans, front: 2, at: 10, input: p(130, 55), key: 70)
        XCTAssertEqual(spans, [Span(pid: 1, from: 0, to: 10, start: p(100, 50), end: p(130, 55), key: 70),
                               Span(pid: 2, from: 10, start: p(130, 55))])
        XCTAssertEqual(Fronts.after(spans, front: 1, at: 300, input: p(140, 60), key: 80, keep: 100),
                       [Span(pid: 2, from: 10, to: 300, start: p(130, 55), end: p(140, 60), key: 80),
                        Span(pid: 1, from: 300, start: p(140, 60))],
                       "app 1's first span is long over")
    }

    /// What can't show the user used a window is let go as its span closes (no key window known, or too little input
    /// in it), and of one window's spans only the newest is kept: switching apps hundreds of times loses nothing that
    /// does show it.
    func testSpansThatShowNothingAreLetGoAndEvidenceIsKept() {
        var spans = Fronts.after([], front: 1, at: 0, input: p(0, 0))
        spans = Fronts.after(spans, front: 2, at: 10, input: p(20, 3), key: 70)  // worked in #70
        spans = Fronts.after(spans, front: 1, at: 20, input: p(21, 3), key: 90)  // a Cmd-Tab through app 2
        XCTAssertEqual(spans.map(\.pid), [1, 1], "app 2's span showed nothing")
        spans = Fronts.after(spans, front: 3, at: 30, input: p(21, 3))  // its key window couldn't be told
        XCTAssertEqual(spans.map(\.pid), [1, 3])
        // Many switches through app 4 and back: the evidence for #70 stays.
        var input = p(21, 3), t = 30.0
        for _ in 0..<400 {
            t += 1; input.keys += 1
            spans = Fronts.after(spans, front: 4, at: t, input: input, key: 95)
            t += 1; input.keys += 1
            spans = Fronts.after(spans, front: 3, at: t, input: input, key: 96)
        }
        XCTAssertEqual(spans.count, 2)
        XCTAssertTrue(Fronts.userUsed(spans, pid: 1, window: 70, since: 5, input: p(10, 1), now: input, keyNow: nil))
        // Worked in #70 again later: only that newer span is kept for it.
        spans = Fronts.after(spans, front: 1, at: t + 1, input: input)
        spans = Fronts.after(spans, front: 3, at: t + 9, input: Presses(keys: input.keys + 2, clicks: input.clicks + 2), key: 70)
        XCTAssertEqual(spans.filter { $0.key == 70 }.map(\.from), [t + 1])
    }

    /// Leaving an app is a Tab or two of a Cmd-Tab, or one click elsewhere: not use. Three key presses, two clicks, or a
    /// key press and a click are. For the app still in front (nothing has left it yet): two key presses or a click.
    func testHowMuchInputIsUse() {
        XCTAssertFalse(Fronts.worked(p(0, 0), left: true))
        XCTAssertFalse(Fronts.worked(p(1, 0), left: true), "a Cmd-Tab out")
        XCTAssertFalse(Fronts.worked(p(2, 0), left: true), "a Cmd-Tab past an app")
        XCTAssertFalse(Fronts.worked(p(0, 1), left: true), "a click away")
        XCTAssertTrue(Fronts.worked(p(3, 0), left: true))
        XCTAssertTrue(Fronts.worked(p(0, 2), left: true))
        XCTAssertTrue(Fronts.worked(p(1, 1), left: true), "a click there, then a Cmd-Tab out")
        XCTAssertFalse(Fronts.worked(p(1, 0), left: false), "maybe a Cmd-Tab under way")
        XCTAssertTrue(Fronts.worked(p(2, 0), left: false))
        XCTAssertTrue(Fronts.worked(p(0, 1), left: false))
        XCTAssertEqual(Fronts.count(p(10, 5), p(14, 5)), p(4, 0))
        XCTAssertEqual(Fronts.count(p(10, 5), p(9, 6)), p(0, 1), "counts out of order are none")
    }

    /// The user used a window since a time when, after it, its app was their front app with that window its key
    /// window (as they left the app, or now), and they pressed keys or clicked enough while it was front, counted from
    /// that time for the span it falls in; what brought it forward and what left it don't count, nor input puter-use
    /// posted, nor being busy in another window of it.
    func testWhetherTheUserUsedAWindow() {
        let spans = [Span(pid: 1, from: 0, to: 10, start: p(0, 0), end: p(10, 2), key: 70),
                     Span(pid: 2, from: 10, to: 20, start: p(10, 2), end: p(11, 2), key: 90),
                     Span(pid: 1, from: 20, to: 30, start: p(11, 2), end: p(30, 4), key: 71),
                     Span(pid: 3, from: 30, start: p(30, 4))]
        func used(_ pid: pid_t, _ wid: CGWindowID, since: TimeInterval, at input: Presses, now: Presses = Presses(keys: 30, clicks: 4),
                  keyNow: CGWindowID? = nil) -> Bool {
            Fronts.userUsed(spans, pid: pid, window: wid, since: since, input: input, now: now, keyNow: keyNow)
        }
        XCTAssertTrue(used(1, 70, since: 5, at: p(4, 1)))
        XCTAssertFalse(used(1, 70, since: 9.5, at: p(9, 2)), "only its leaving came after")
        XCTAssertFalse(used(1, 70, since: 15, at: p(10, 2)), "its later span was in another of its windows")
        XCTAssertTrue(used(1, 71, since: 15, at: p(10, 2)))
        XCTAssertFalse(used(1, 71, since: 29, at: p(29, 4)), "in front after that, but only leaving since")
        XCTAssertFalse(used(2, 90, since: 0, at: p(0, 0)), "one key: a Cmd-Tab in and out")
        XCTAssertFalse(used(1, 71, since: 30, at: p(30, 4)), "not in front since")
        XCTAssertTrue(used(3, 95, since: 32, at: p(31, 4), now: p(31, 5), keyNow: 95), "in front now in this window, and clicked")
        XCTAssertFalse(used(3, 95, since: 32, at: p(31, 4), now: p(31, 5), keyNow: 96), "busy in another of its windows")
        XCTAssertFalse(used(3, 95, since: 32, at: p(31, 4), now: p(31, 5)), "its key window can't be told")
        XCTAssertFalse(used(3, 95, since: 32, at: p(31, 4), now: p(31, 4), keyNow: 95), "in front now, untouched since")
        XCTAssertFalse(used(4, 95, since: 0, at: p(0, 0), keyNow: 95))
    }

    /// The user Cmd-Tabs into Firefox, lands in the agent's window (its key window), and Cmd-Tabs out again: not use,
    /// so a title that changed meanwhile (a page that finished loading, a live title) keeps the window the agent's,
    /// with nothing to tell.
    func testACmdTabThroughTheAppIsNotUse() {
        let firefox: pid_t = 1, mine: CGWindowID = 70
        var spans = Fronts.after([], front: 2, at: 0, input: p(500, 40))
        // Cmd-Tab: the Tab goes down in the app before, then Firefox comes to the front.
        spans = Fronts.after(spans, front: firefox, at: 10, input: p(501, 40), key: 12)
        // Cmd-Tab out (one Tab), or two Tabs to pass an app in the switcher.
        for tabs: UInt32 in [1, 2] {
            let out = Fronts.after(spans, front: 3, at: 12, input: p(501 + tabs, 40), key: mine)
            let there = Fronts.userUsed(out, pid: firefox, window: mine, since: 5, input: p(500, 40), now: p(501 + tabs, 40),
                                        keyNow: nil)
            XCTAssertFalse(there, "\(tabs) Tab(s) out")
            XCTAssertEqual(Handlers.takeover(titleChanged: true, tabsChanged: false, hostChanged: false, userWasThere: there),
                           .keep)
        }
        // Clicked in it once, then a click away: still nothing beyond the leave.
        let clickedAway = Fronts.after(spans, front: 3, at: 12, input: p(501, 41), key: mine)
        XCTAssertFalse(Fronts.userUsed(clickedAway, pid: firefox, window: mine, since: 5, input: p(500, 40), now: p(501, 41),
                                       keyNow: nil))
        // Typed into it, then Cmd-Tabbed out: use.
        let typed = Fronts.after(spans, front: 3, at: 20, input: p(512, 40), key: mine)
        XCTAssertTrue(Fronts.userUsed(typed, pid: firefox, window: mine, since: 5, input: p(500, 40), now: p(512, 40), keyNow: nil))
    }

    /// The user busy in their own window of the app while the agent's window retitles itself (a live reload, an
    /// unread count): the agent's window stays its own, with nothing to tell, and a note only for another site;
    /// never marked used, never given away.
    func testTheUserBusyInAnotherWindowLeavesTheAgentsWindowAlone() {
        let mine: CGWindowID = 70, theirs: CGWindowID = 71
        let spans = [Span(pid: 1, from: 10, to: 60, start: p(0, 0), end: p(200, 30), key: theirs), Span(pid: 1, from: 80, start: p(200, 30))]
        for keyNow: CGWindowID? in [theirs, nil] {
            let there = Fronts.userUsed(spans, pid: 1, window: mine, since: 0, input: p(0, 0), now: p(260, 40), keyNow: keyNow)
            XCTAssertFalse(there)
            let v = Handlers.takeover(titleChanged: true, tabsChanged: false, hostChanged: false, userWasThere: there)
            XCTAssertEqual(v, .keep)
            XCTAssertNil(Handlers.ownershipNote(v, id: mine, title: "Dashboard", browser: true, tagged: false))
            XCTAssertEqual(Handlers.takeover(titleChanged: true, tabsChanged: false, hostChanged: true, userWasThere: there),
                           .changed, "even on another site")
        }
        // In the agent's window itself, it's theirs too.
        let there = Fronts.userUsed(spans, pid: 1, window: mine, since: 0, input: p(0, 0), now: p(260, 40), keyNow: mine)
        XCTAssertEqual(Handlers.takeover(titleChanged: true, tabsChanged: false, hostChanged: false, userWasThere: there), .tag)
    }

    /// A change to the title of a window marked used is told once: a title told lately (an unread count or a player's
    /// coming back) isn't told again; the window marked used, given away, or showing another site or tab count is told
    /// whatever its title.
    func testATitleIsToldOnce() {
        var told: [String] = []
        XCTAssertFalse(Handlers.toldBefore(.tag, tagged: true, title: "(1) Inbox", told: told))
        told = Handlers.telling(told, "(1) Inbox")
        told = Handlers.telling(told, "Inbox")
        XCTAssertTrue(Handlers.toldBefore(.tag, tagged: true, title: "(1) Inbox", told: told))
        XCTAssertTrue(Handlers.toldBefore(.tag, tagged: true, title: "Inbox", told: told), "marked before: only a title change")
        XCTAssertFalse(Handlers.toldBefore(.changed, tagged: false, title: "Inbox", told: told), "another site or tab count")
        XCTAssertFalse(Handlers.toldBefore(.tag, tagged: false, title: "Inbox", told: told), "marked used: news")
        XCTAssertFalse(Handlers.toldBefore(.drop, tagged: false, title: "Inbox", told: told))
        XCTAssertEqual(Handlers.telling(told, "(1) Inbox"), ["Inbox", "(1) Inbox"], "no repeats, newest last")
        XCTAssertEqual(Handlers.telling((1...8).map { "\($0)" }, "9"), (2...9).map { "\($0)" }, "the newest few")
    }

    // MARK: - tabs

    struct Node {
        var role: String
        var kids: [Node] = []
    }

    func tabs(_ root: Node, visits: Int = 150) -> Int? {
        Handlers.tabCount(in: root, role: { $0.role }, children: { $0.kids }, visits: visits)
    }

    /// The window's own tab group's tabs, nested a little or not; never a web page's tabs.
    func testATabCount() {
        let tab = Node(role: "AXRadioButton")
        let page = Node(role: "AXWebArea", kids: [Node(role: "AXTabGroup", kids: Array(repeating: tab, count: 5))])
        let strip = Node(role: "AXTabGroup", kids: [tab, tab, Node(role: "AXButton")])
        XCTAssertEqual(tabs(Node(role: "AXWindow", kids: [Node(role: "AXToolbar", kids: [strip]), page])), 2)
        XCTAssertEqual(tabs(Node(role: "AXWindow", kids: [Node(role: "AXTabGroup", kids: [Node(role: "AXScrollArea",
                                                                                              kids: [tab, tab, tab])])])), 3)
        XCTAssertNil(tabs(Node(role: "AXWindow", kids: [page])), "only the page's")
        XCTAssertNil(tabs(Node(role: "AXWindow", kids: [Node(role: "AXTabGroup")])), "no tabs in it")
        XCTAssertNil(tabs(Node(role: "AXWindow", kids: Array(repeating: Node(role: "AXButton"), count: 20)), visits: 10))
    }

    /// close_window stops on one of the agent's windows that has more tabs than when it last acted there, or one the
    /// user took over; not on fewer, the same, or a count it can't tell.
    func testCloseWindowLeavesTheUsersTabsAlone() {
        XCTAssertEqual(Handlers.closeRefusal(wid: 5, given: false, tabsThen: 1, tabsNow: 3),
                       "#5 has 3 tabs, 1 when you last acted there, and the others may be the user's: nothing was closed. Ask "
                           + "the user; if they agree, close it with \"confirm\": true")
        XCTAssertEqual(Handlers.closeRefusal(wid: 5, given: true, tabsThen: nil, tabsNow: nil),
                       "#5 is the user's now (they've used it since you opened it): nothing was closed. Ask the user; if they "
                           + "agree, close it with \"confirm\": true")
        XCTAssertNil(Handlers.closeRefusal(wid: 5, given: false, tabsThen: 2, tabsNow: 2))
        XCTAssertNil(Handlers.closeRefusal(wid: 5, given: false, tabsThen: 3, tabsNow: 1))
        XCTAssertNil(Handlers.closeRefusal(wid: 5, given: false, tabsThen: nil, tabsNow: 4))
        XCTAssertNil(Handlers.closeRefusal(wid: 5, given: false, tabsThen: 1, tabsNow: nil))
    }

    // MARK: - the session's windows

    /// A window is the agent's while it's in the session's own, "used" once the user has used it; replies say whose.
    func testWhoseAWindowIs() {
        let s = Session(id: "ownership-whose-test", ordinal: 4)
        let mine: CGWindowID = 4_000_000_101, used: CGWindowID = 4_000_000_102, theirs: CGWindowID = 4_000_000_103
        func describe(_ id: CGWindowID) -> [String: Any] {
            Handlers.describe(.window(WinInfo(id: id, pid: 1, app: "App", title: "t", frame: .zero, layer: 0, onScreen: true)))
        }
        Session.$current.withValue(s) {
            s.agentWindows = [mine, used]
            s.owned[used] = Owned(title: "t", since: 0, lastUsed: Date(), userUsed: true)
            XCTAssertEqual(Handlers.owner(mine), .agent)
            XCTAssertEqual(Handlers.owner(used), .shared)
            XCTAssertEqual(Handlers.owner(theirs), .user)
            XCTAssertEqual(describe(mine)["yours"] as? Bool, true)
            XCTAssertNil(describe(mine)["used"])
            XCTAssertEqual(describe(used)["yours"] as? Bool, true)
            XCTAssertEqual(describe(used)["used"] as? Bool, true)
            XCTAssertEqual(describe(theirs)["yours"] as? Bool, false)
        }
        XCTAssertEqual(Handlers.whose(.agent), "yours")
        XCTAssertEqual(Handlers.whose(.shared), "yours, used by the user")
        XCTAssertEqual(Handlers.whose(.user), "the user's")
    }

    /// The session lets go of its windows it hasn't used for two hours (the shared "default" one too, which is never
    /// swept), with what it kept of them; a window it has no record of gets one, and stays.
    func testUnusedWindowsAreLetGo() {
        let s = Session(id: "ownership-expiry-test", ordinal: 4)
        let old: CGWindowID = 4_000_000_201, recent: CGWindowID = 4_000_000_202, unrecorded: CGWindowID = 4_000_000_203
        Session.$current.withValue(s) {
            s.agentWindows = [old, recent, unrecorded]
            s.owned[old] = Owned(title: "a", since: 0, lastUsed: Date().addingTimeInterval(-3 * 3600))
            s.owned[recent] = Owned(title: "b", since: 0, lastUsed: Date().addingTimeInterval(-3600))
            s.current = old
            Handlers.reviewOwnership(1)
            XCTAssertEqual(s.agentWindows, [recent, unrecorded])
            XCTAssertNil(s.current, "it was the one let go")
            XCTAssertEqual(Set(s.ownRecent), [recent, unrecorded])
            XCTAssertNil(s.owned[old])
            XCTAssertNotNil(s.owned[unrecorded])
            XCTAssertEqual(Handlers.owner(old), .user)
        }
    }

    // MARK: - an address typed into a page

    /// A lone web address, as one is typed into an address bar (a final Return aside); not text with a space, an
    /// email address, a version number or a word.
    func testALoneAddress() {
        for s in ["https://example.com", "http://localhost:3000/admin\n", "example.com", "www.example.com/a?b=c#d",
                  "localhost:8080", "127.0.0.1:5000/x", "about:blank", "sub.domain.co.uk/path", "  example.com \r\n",
                  "file:///Users/ada/a.html", "EXAMPLE.COM"] {
            XCTAssertTrue(Handlers.loneAddress(s), s)
        }
        for s in ["hello world", "example", "e.g.", "v1.2", "ada@example.com", "localhost:", "localhost:abc", "https://", "",
                  "\n", "Hello. World", "http://exa mple.com", "999.1.1.1", "-foo.com", "foo..com", "about:", "go to example.com",
                  "index.html", "report.pdf", "README.md", "notes.txt", "main.swift", "photo.JPG"] {
            XCTAssertFalse(Handlers.loneAddress(s), s)
        }
        // A file name's ending with a scheme, "www." or a host before it is an address.
        for s in ["www.index.html", "https://example.com/index.html", "example.com/report.pdf", "file:///tmp/a.html",
                  "bun.sh", "claude.ai", "my.app"] {
            XCTAssertTrue(Handlers.loneAddress(s), s)
        }
    }

    /// A `type` with no field, in a browser, whose focus in the window isn't on a text input: stopped. A page's own
    /// field takes it; navigate's and fill's typing aren't this; a focus in another window is the keyboard guard's.
    func testAnAddressTypedIntoAPageStops() {
        let type: [String: Any] = ["type": "type", "text": "example.com"]
        XCTAssertTrue(Handlers.addressIntoPage(type, text: "example.com", browser: true, focusOnText: false))
        XCTAssertTrue(Handlers.addressIntoPage(type.merging(["submit": true]) { $1 }, text: "example.com", browser: true,
                                               focusOnText: false))
        XCTAssertTrue(Handlers.addressIntoPage(["type": "type_text"], text: "https://example.com\n", browser: true, focusOnText: false))
        XCTAssertFalse(Handlers.addressIntoPage(type, text: "example.com", browser: true, focusOnText: true), "a page's field")
        XCTAssertFalse(Handlers.addressIntoPage(type, text: "example.com", browser: true, focusOnText: nil), "another window")
        XCTAssertFalse(Handlers.addressIntoPage(type, text: "example.com", browser: false, focusOnText: false))
        XCTAssertFalse(Handlers.addressIntoPage(type, text: "hello there", browser: true, focusOnText: false))
        for aim: [String: Any] in [["element": 4], ["target": "URL"], ["x": 10, "y": 20], ["coordinate": [10, 20]]] {
            XCTAssertFalse(Handlers.addressIntoPage(type.merging(aim) { $1 }, text: "example.com", browser: true, focusOnText: false))
        }
        for kind in ["navigate", "fill", "paste"] {
            XCTAssertFalse(Handlers.addressIntoPage(["type": kind], text: "example.com", browser: true, focusOnText: false), kind)
        }
    }
}
