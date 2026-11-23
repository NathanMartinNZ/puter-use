import ApplicationServices
import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Windows their app has stopped drawing (`Handlers.Frozen`): the evidence for one, what's in the way of it, what a
/// new picture keeps of the last, the stop for coordinates read off an old picture, the words, and the size of the
/// window an image is of (`window_pt`).
@MainActor
final class FrozenTests: XCTestCase {
    static func sig(_ gray: CGFloat, mark: CGRect? = nil) -> Signature {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        if let mark {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(mark)
        }
        return Signature(ctx.makeImage()!)
    }

    // MARK: - the evidence

    /// A capture that's the last picture pixel for pixel though the title changed: the app isn't drawing the window
    /// (one that draws shows its new title too). Any pixel changed, the same title, or nothing kept says nothing.
    func testATitleThatChangedOverTheSamePictureIsEvidence() {
        let page = Self.sig(0.9), tab = Self.sig(0.9, mark: CGRect(x: 10, y: 4, width: 24, height: 6))
        XCTAssertTrue(Handlers.undrawn(title: "Dashboard | meertrack", drawn: "Problem loading page", sig: page, last: page))
        XCTAssertFalse(Handlers.undrawn(title: "Dashboard | meertrack", drawn: "Problem loading page", sig: tab, last: page),
                       "its tab shows the new title: it's drawn")
        XCTAssertFalse(Handlers.undrawn(title: "Docs", drawn: "Docs", sig: page, last: page), "nothing changed")
        XCTAssertFalse(Handlers.undrawn(title: "Docs", drawn: nil, sig: page, last: page))
        XCTAssertFalse(Handlers.undrawn(title: nil, drawn: "Docs", sig: page, last: page))
        XCTAssertFalse(Handlers.undrawn(title: "Docs", drawn: "Old", sig: page, last: nil))
    }

    /// A page with no tree (none, or an empty one that isn't loading) while the address bar names a page. A page
    /// loading, one with something in it, a tree not known, or an address bar with no address (a new tab, words being
    /// searched for, a blank page) says nothing.
    func testAPageWithNoTreeUnderAnAddressIsEvidence() {
        XCTAssertTrue(Handlers.treeMissing(.missing, address: "localhost:3000/dashboard"))
        XCTAssertTrue(Handlers.treeMissing(.empty, address: "https://example.com/"))
        XCTAssertFalse(Handlers.treeMissing(.loading, address: "example.com"))
        XCTAssertFalse(Handlers.treeMissing(.shown, address: "example.com"))
        XCTAssertFalse(Handlers.treeMissing(nil, address: "example.com"), "the walk ran out: not known")
        XCTAssertFalse(Handlers.treeMissing(.missing, address: nil))
        XCTAssertFalse(Handlers.treeMissing(.missing, address: ""))
        XCTAssertFalse(Handlers.treeMissing(.missing, address: "cats and dogs"))
        XCTAssertFalse(Handlers.treeMissing(.empty, address: "about:blank"))
    }

    /// Either evidence counts only while none of the window shows: a window in view is drawn, so a tree missing there
    /// is late, and a title that changed with nothing else is one the app doesn't show. Cover alone isn't evidence.
    func testEvidenceCountsOnlyWhileTheWindowIsOutOfView() {
        for cover in [Handlers.Cover.covered, .minimized, .otherSpace, .hidden] {
            XCTAssertTrue(Handlers.notDrawn(undrawn: true, treeMissing: false, cover: cover))
            XCTAssertTrue(Handlers.notDrawn(undrawn: false, treeMissing: true, cover: cover))
            XCTAssertFalse(Handlers.notDrawn(undrawn: false, treeMissing: false, cover: cover), "cover alone: \(cover)")
        }
        XCTAssertFalse(Handlers.notDrawn(undrawn: true, treeMissing: false, cover: .inView))
        XCTAssertFalse(Handlers.notDrawn(undrawn: false, treeMissing: true, cover: .inView))
        XCTAssertFalse(Handlers.notDrawn(undrawn: true, treeMissing: true, cover: .inView))
    }

    /// An address bar's text is an address when it's one word with a scheme, or a host first; words being searched
    /// for aren't. A blank page names none.
    func testWhatLooksLikeAnAddress() {
        for s in ["https://example.com/a?b=c", "http://localhost:8000", "file:///Users/x/a.html", "about:config",
                  "example.com", "example.com/docs?q=cats", "sub.example.co.uk/x", "localhost:3000/dashboard",
                  "127.0.0.1:8000/a.html", "[::1]:8080/", "moz-extension://abc/page.html", " example.com "] {
            XCTAssertTrue(Handlers.looksLikeAddress(s), s)
        }
        for s in ["", "   ", "cats", "cats and dogs", "how to fix example.com", "3.14", "1.2.3", "e.g.", "a..b", "about:"] {
            XCTAssertFalse(Handlers.looksLikeAddress(s), s)
        }
        XCTAssertTrue(Handlers.namesPage("example.com"))
        XCTAssertFalse(Handlers.namesPage("about:blank"))
        XCTAssertFalse(Handlers.namesPage(" About:Blank "))
        XCTAssertFalse(Handlers.namesPage("search words"))
    }

    // MARK: - what's in the way

    /// The app hidden, the window minimized, off screen otherwise (another Space), else whether what's over it hides
    /// every part of it that's on a display.
    func testWhatsInTheWay() {
        let win = CGRect(x: 100, y: 100, width: 800, height: 600), screen = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        func cover(onScreen: Bool = true, minimized: Bool = false, hidden: Bool = false, above: [CGRect]) -> Handlers.Cover {
            Handlers.cover(onScreen: onScreen, minimized: minimized, appHidden: hidden, frame: win, above: above, displays: screen)
        }
        XCTAssertEqual(cover(hidden: true, above: []), .hidden)
        XCTAssertEqual(cover(onScreen: false, minimized: true, above: []), .minimized)
        XCTAssertEqual(cover(onScreen: false, above: []), .otherSpace)
        XCTAssertEqual(cover(above: []), .inView)
        XCTAssertEqual(cover(above: [CGRect(x: 0, y: 0, width: 1000, height: 800)]), .covered)
        XCTAssertEqual(cover(above: [CGRect(x: 0, y: 0, width: 1000, height: 400)]), .inView, "its bottom shows")
    }

    /// A window of an app that draws its covered windows on is in view when only covered; minimized, on another Space
    /// or with its app hidden, it's out of view as any.
    func testACoveredWindowOfAnAppThatDrawsItOnIsInView() {
        let win = CGRect(x: 100, y: 100, width: 800, height: 600), screen = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let over = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        func cover(onScreen: Bool = true, minimized: Bool = false, hidden: Bool = false, above: [CGRect] = over) -> Handlers.Cover {
            Handlers.cover(onScreen: onScreen, minimized: minimized, appHidden: hidden, frame: win, above: above, displays: screen,
                           drawsCovered: true)
        }
        XCTAssertEqual(cover(), .inView)
        XCTAssertEqual(cover(above: []), .inView)
        XCTAssertEqual(cover(onScreen: false, minimized: true), .minimized)
        XCTAssertEqual(cover(onScreen: false), .otherSpace)
        XCTAssertEqual(cover(hidden: true), .hidden)
        XCTAssertFalse(Handlers.notDrawn(undrawn: true, treeMissing: true, cover: cover()), "covered, yet drawn")
    }

    /// A Firefox draws its covered windows on when its environment has MOZ_WINDOW_OCCLUSION set to anything but "1"
    /// (read from its process's record: the strings after its arguments); unset or "1", it stops drawing them. The
    /// first such string counts, as the process reads it; an argument saying it, or a name like it, doesn't.
    func testAFirefoxsEnvironmentSaysWhetherItDrawsCoveredWindows() {
        let argv = ["/Applications/Firefox.app/Contents/MacOS/firefox", "-foreground"]
        func draws(_ env: [String], argv more: [String] = []) -> Bool {
            let parsed = AgentBrowser.procArgs(AgentBrowserTests.record(argv + more, env: env))
            XCTAssertEqual(parsed?.argv, argv + more)
            XCTAssertEqual(parsed?.env, env)
            return Handlers.drawsCovered(env: parsed?.env ?? [])
        }
        XCTAssertFalse(draws(["HOME=/Users/ada", "PATH=/usr/bin:/bin"]), "unset")
        XCTAssertFalse(draws(["HOME=/Users/ada", "MOZ_WINDOW_OCCLUSION=1"]))
        XCTAssertTrue(draws(["HOME=/Users/ada", "MOZ_WINDOW_OCCLUSION=0"]))
        XCTAssertTrue(draws(["MOZ_WINDOW_OCCLUSION="]), "set, empty")
        XCTAssertTrue(draws(["MOZ_WINDOW_OCCLUSION=false"]))
        XCTAssertFalse(draws(["MOZ_WINDOW_OCCLUSION=1", "MOZ_WINDOW_OCCLUSION=0"]), "the first counts")
        XCTAssertFalse(draws(["MOZ_WINDOW_OCCLUSION_X=0", "XMOZ_WINDOW_OCCLUSION=0"]))
        XCTAssertFalse(draws(["HOME=/Users/ada"], argv: ["MOZ_WINDOW_OCCLUSION=0"]), "an argument isn't the environment")
        XCTAssertTrue(Handlers.drawsCovered(env: AgentBrowser.launchEnvironment.map { "\($0.key)=\($0.value)" }),
                      "the agent's own Firefox is one")
        XCTAssertFalse(Handlers.drawsCovered(ProcessInfo.processInfo.processIdentifier), "not a Firefox")
    }

    /// Covered when the windows over it hide it together, a point of rounding aside; a sliver showing is in view.
    /// Only the parts on a display count: off every display, it doesn't show either.
    func testCoverIsWorkedOutOnTheDisplays() {
        let win = CGRect(x: 100, y: 100, width: 800, height: 600)
        let screen = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let halves = [CGRect(x: 100, y: 100, width: 400, height: 600), CGRect(x: 500, y: 100, width: 400, height: 600)]
        XCTAssertTrue(Handlers.under(win, halves, displays: screen), "two windows side by side")
        XCTAssertTrue(Handlers.under(win, [win.insetBy(dx: 0.5, dy: 0.5)], displays: screen), "a rounding apart")
        XCTAssertFalse(Handlers.under(win, [CGRect(x: 100, y: 100, width: 790, height: 600)], displays: screen),
                       "a 10 pt sliver shows")
        XCTAssertFalse(Handlers.under(win, [], displays: screen))
        // Half off the screen's right edge: only the half on it needs covering.
        let edge = CGRect(x: 1040, y: 100, width: 800, height: 600)
        XCTAssertTrue(Handlers.under(edge, [CGRect(x: 1000, y: 0, width: 440, height: 900)], displays: screen))
        XCTAssertTrue(Handlers.under(CGRect(x: 2000, y: 100, width: 300, height: 200), [], displays: screen), "on no display")
        // Across two displays: covered on one, showing on the other.
        let two = screen + [CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let across = CGRect(x: 1200, y: 100, width: 600, height: 400)
        XCTAssertFalse(Handlers.under(across, [CGRect(x: 1100, y: 0, width: 340, height: 900)], displays: two))
        XCTAssertTrue(Handlers.under(across, [CGRect(x: 1100, y: 0, width: 340, height: 900),
                                              CGRect(x: 1440, y: 50, width: 500, height: 600)], displays: two))
    }

    /// What's over a window hides it only as an ordinary window that's drawn: not a menu, the menu bar, an invisible
    /// window, the window itself, or puter-use's own pointer.
    func testOnlyOrdinaryWindowsOfOthersCover() {
        func w(_ id: CGWindowID, pid: pid_t = 50, layer: Int = 0, alpha: Double = 1) -> WinInfo {
            WinInfo(id: id, pid: pid, app: "", title: "", frame: CGRect(x: Int(id), y: 0, width: 10, height: 10), layer: layer,
                    onScreen: true, alpha: alpha)
        }
        let above = [w(1), w(2, layer: 101), w(3, layer: 25), w(4, alpha: 0), w(5, pid: 99), w(7), w(9, alpha: 0.4)]
        XCTAssertEqual(Handlers.covering(above, of: 7, own: 99).map(\.minX), [1, 9])
    }

    // MARK: - what a new picture keeps

    /// A new picture that's the last one pixel for pixel keeps that one's title (the one it shows) and what showed its
    /// app wasn't drawing it; one that changed starts afresh with the title now.
    func testANewPictureKeepsTheLastOnesTitleOnlyWhenNothingWasDrawn() {
        let page = Self.sig(0.9), other = Self.sig(0.5)
        let frozen = Handlers.Frozen(unread: true, title: nil, cover: .covered, key: false)
        let old = Meta(offset: .zero, size: CGSize(width: 400, height: 300), width: 400, height: 300, sig: page,
                       title: "Problem loading page", frozen: frozen)
        let same = Handlers.kept(old, sig: page, title: "Dashboard")
        XCTAssertEqual(same.title, "Problem loading page")
        XCTAssertEqual(same.frozen, frozen)
        let drawn = Handlers.kept(old, sig: other, title: "Dashboard")
        XCTAssertEqual(drawn.title, "Dashboard")
        XCTAssertNil(drawn.frozen)
        XCTAssertEqual(Handlers.kept(nil, sig: page, title: "Docs").title, "Docs")
        var untitled = old
        untitled.title = nil
        XCTAssertEqual(Handlers.kept(untitled, sig: page, title: "Docs").title, "Docs")
    }

    // MARK: - coordinates

    /// Only coordinates read off the picture are checked: they stop when the window wasn't being drawn at that
    /// picture, and ask whether it is now when its title has changed since. Element or target aims (accessibility),
    /// window points (a macro step), the guard off, foreground mode and a window the batch moved to go ahead.
    func testCoordinatesStopOnAPictureThatMayBeOld() {
        let click: [String: Any] = ["type": "click", "x": 40, "y": 60]
        func check(_ a: [String: Any], guarded: Bool = true, foreground: Bool = false, moved: Bool = false, then: Bool = false,
                   changed: Bool = false) -> Handlers.AimCheck {
            Handlers.aimCheck(a, guarded: guarded, foreground: foreground, moved: moved, frozenThen: then, titleChanged: changed)
        }
        XCTAssertEqual(check(click, then: true), .stop)
        XCTAssertEqual(check(click, then: true, changed: true), .stop)
        XCTAssertEqual(check(click, changed: true), .look)
        XCTAssertEqual(check(click), .go)
        XCTAssertEqual(check(["type": "drag", "path": [[1, 2], [30, 40]]], then: true), .stop)
        XCTAssertEqual(check(["type": "scroll", "x": 200, "y": 300, "scroll_y": 3], then: true), .stop)
        XCTAssertEqual(check(["type": "click", "target": "Save"], then: true), .go)
        XCTAssertEqual(check(["type": "click", "element": 12], then: true), .go)
        XCTAssertEqual(check(["type": "scroll", "scroll_y": 3], then: true), .go, "the middle of the window: no coordinates")
        XCTAssertEqual(check(["type": "click", "x": 40, "y": 60, "units": "pt"], then: true), .go)
        XCTAssertEqual(check(click, guarded: false, then: true), .go)
        XCTAssertEqual(check(click, foreground: true, then: true), .go)
        XCTAssertEqual(check(click, moved: true, then: true), .go)
    }

    // MARK: - words

    /// The note says what isn't drawing which window and why, that the picture may be old (with the title now when it
    /// shows another), and that the page can't be read when it can't. Whether the window is its app's key window isn't
    /// said: making it key doesn't bring back one that's covered.
    func testTheNoteOnAPictureThatMayBeOld() {
        let f = Handlers.Frozen(unread: true, title: "Dashboard | meertrack", cover: .covered, key: false)
        XCTAssertEqual(Handlers.frozenNote(f, app: "Firefox", wid: 26972, last: false),
                       "Firefox isn't drawing #26972 (it's covered): this picture may be old "
                       + "(the title is now \"Dashboard | meertrack\"), and the page can't be read")
        let key = Handlers.Frozen(unread: false, title: nil, cover: .covered, key: true)
        XCTAssertEqual(Handlers.frozenNote(key, app: "Firefox", wid: 7, last: true),
                       "Firefox isn't drawing #7 (it's covered): your last picture of it may be old")
        XCTAssertEqual(Handlers.frozenWhy(Handlers.Frozen(cover: .minimized), app: "Safari"), "it's minimized")
        XCTAssertEqual(Handlers.frozenWhy(Handlers.Frozen(cover: .otherSpace), app: "Safari"), "it's on another Space")
        XCTAssertEqual(Handlers.frozenWhy(Handlers.Frozen(cover: .hidden), app: "Safari"), "Safari is hidden")
        XCTAssertNil(Handlers.frozenWhy(Handlers.Frozen(cover: .inView), app: "Safari"))
    }

    /// A look that found nothing fails saying why and what to do; a stop for coordinates says aim by element or target
    /// where the page can still be read.
    func testTheErrorAndTheStopSayWhatToDo() {
        let unread = Handlers.Frozen(unread: true, title: nil, cover: .covered, key: false)
        let error = Handlers.frozenError(unread, app: "Firefox", wid: 9)
        XCTAssertEqual(error, "Firefox isn't drawing #9 (it's covered): its page can't be read, and its picture may be old. "
            + "Ask the user to bring #9 into view (even partly), or use activate (raises it to just below the user's front window, so it shows) if they agree")
        XCTAssertEqual(NotDrawn(frozen: unread, app: "Firefox", wid: 9).missing("\"Save\"").description,
                       "nothing shows \"Save\" by accessibility, and " + error)
        let stop = Handlers.staleAim(unread, app: "Firefox", wid: 9)
        XCTAssertEqual(stop.why, "the last picture of #9 may be old (Firefox isn't drawing it: it's covered), so coordinates "
            + "from it can't be trusted")
        XCTAssertTrue(stop.next.hasPrefix("Ask the user to bring #9 into view"), stop.next)
        XCTAssertTrue(stop.next.hasSuffix(". Take a new screenshot once it's in view."), stop.next)
        let readable = Handlers.staleAim(Handlers.Frozen(unread: false, title: "B", cover: .minimized), app: "Notes", wid: 3)
        XCTAssertTrue(readable.next.hasPrefix("Aim by element or target instead, or ask the user"), readable.next)
        XCTAssertTrue(readable.next.hasSuffix(". Take a new screenshot once it's in view."), readable.next)
        XCTAssertEqual(Handlers.unseenSinceInView(app: "Firefox", wid: 9),
                       "the last picture of #9 may be old (Firefox wasn't drawing it then), and #9 has come into view since, so "
                           + "coordinates from it can't be trusted")
    }

    /// A covered window of a Firefox started without MOZ_WINDOW_OCCLUSION off says how the user can stop it, in the
    /// note, the error and the stop alike; a minimized one, or another app's, doesn't (it wouldn't help).
    func testAFirefoxsCoveredWindowSaysHowTheUserCanStopIt() {
        let tip = "; the user can stop this by starting Firefox with MOZ_WINDOW_OCCLUSION=0 (see puter-use's docs)"
        let f = Handlers.Frozen(unread: false, title: nil, cover: .covered, key: false, firefox: true)
        XCTAssertEqual(Handlers.frozenNote(f, app: "Firefox", wid: 7, last: true),
                       "Firefox isn't drawing #7 (it's covered): your last picture of it may be old" + tip)
        var unread = f
        unread.unread = true
        XCTAssertTrue(Handlers.frozenNote(unread, app: "Firefox", wid: 7, last: false)
            .hasSuffix("and the page can't be read" + tip))
        XCTAssertTrue(Handlers.frozenError(f, app: "Firefox", wid: 7).hasSuffix("if they agree" + tip))
        let stop = Handlers.staleAim(unread, app: "Firefox", wid: 7)
        XCTAssertTrue(stop.next.hasSuffix("if they agree" + tip + ". Take a new screenshot once it's in view."), stop.next)
        XCTAssertEqual(Handlers.occlusionTip(f, app: "Zen"),
                       "; the user can stop this by starting Zen with MOZ_WINDOW_OCCLUSION=0 (see puter-use's docs)")
        var minimized = f
        minimized.cover = .minimized
        XCTAssertEqual(Handlers.occlusionTip(minimized, app: "Firefox"), "")
        XCTAssertFalse(Handlers.frozenError(minimized, app: "Firefox", wid: 7).contains("MOZ_WINDOW_OCCLUSION"))
        var safari = f
        safari.firefox = false
        XCTAssertEqual(Handlers.occlusionTip(safari, app: "Safari"), "")
        XCTAssertFalse(Handlers.frozenNote(safari, app: "Safari", wid: 7, last: true).contains("MOZ_WINDOW_OCCLUSION"))
    }

    /// A target's miss in a window that isn't drawn is its own kind of error, so what's like the target (the browser's
    /// own buttons, there) isn't added to it; and a look that found the text only in a browser's own controls says so.
    func testAMissInAWindowNotDrawnSaysOnlyThat() {
        let miss = NotDrawn(frozen: Handlers.Frozen(unread: true, cover: .covered), app: "Firefox", wid: 9).missing("\"Open report\"")
        XCTAssertFalse((miss as Error) is HelperError, "not a HelperError: the miss's own catch adds nothing to it")
        XCTAssertTrue(miss.description.hasPrefix("nothing shows \"Open report\" by accessibility, and Firefox isn't drawing #9"))
        XCTAssertFalse(miss.description.contains("similar"))
        XCTAssertEqual(Handlers.notInPage(app: "Firefox"), "it shows only in Firefox's tabs or toolbar, not in the page")
    }

    /// A reply whose error (a wait_for or a target that stopped for it) or note (navigate's page wait) says the window
    /// isn't drawn gets no not-drawn note saying it again; one about another window, or none, still does.
    func testTheNotDrawnNoteIsntRepeated() {
        let f = Handlers.Frozen(unread: true, cover: .covered)
        let error = "action 1 (wait_for): wait_for: \"Done\" can't be waited for: " + Handlers.frozenError(f, app: "Firefox", wid: 12)
        XCTAssertTrue(Handlers.saysNotDrawn([error], app: "Firefox", wid: 12))
        XCTAssertTrue(Handlers.saysNotDrawn(["can't tell whether the page loaded: " + Handlers.frozenError(f, app: "Firefox", wid: 12)],
                                            app: "Firefox", wid: 12))
        XCTAssertFalse(Handlers.saysNotDrawn([error], app: "Firefox", wid: 1), "another window")
        XCTAssertFalse(Handlers.saysNotDrawn([Handlers.frozenError(f, app: "Firefox", wid: 120)], app: "Firefox", wid: 12),
                       "#120 isn't #12")
        XCTAssertFalse(Handlers.saysNotDrawn(["action 1 (click): no \"Done\" found"], app: "Firefox", wid: 12))
        XCTAssertFalse(Handlers.saysNotDrawn([], app: "Firefox", wid: 12))
    }

    /// A window the window server lists but not on screen can't be used, and says why: minimized (un-minimizing it would
    /// put it in front of the user), on another Space, or its app hidden; each the user's to change. Nothing for one on
    /// screen.
    func testAWindowOffScreenSaysWhyItCantBeUsed() {
        XCTAssertEqual(Handlers.unseen(.minimized, app: "Firefox", wid: 27934),
                       "window #27934 is minimized, so it can't be seen or used: un-minimizing it would bring it to the front, "
                           + "so ask the user to bring it back, or work in another window")
        XCTAssertEqual(Handlers.unseen(.otherSpace, app: "Firefox", wid: 5),
                       "window #5 is on another Space, so it can't be seen or used from here: ask the user to bring it to this one")
        XCTAssertEqual(Handlers.unseen(.hidden, app: "Notes", wid: 6),
                       "window #6 can't be seen or used while Notes is hidden: showing Notes would bring it to the front, so ask "
                           + "the user to show Notes, or work in another window")
        XCTAssertNil(Handlers.unseen(.inView, app: "Notes", wid: 6))
        XCTAssertNil(Handlers.unseen(.covered, app: "Notes", wid: 6))
    }

    /// A coordinate action stopped on a picture judged not drawn asks what's in the way again first: still out of
    /// view, it stops; in view, it goes when the window still looks as that picture does (a false verdict, or nothing
    /// changed), and stops for a new picture when it doesn't, or that can't be told.
    func testAStopOnAnOldPictureLooksAgainAtTheWindow() {
        for cover: Handlers.Cover in [.covered, .minimized, .otherSpace, .hidden] {
            XCTAssertEqual(Handlers.recheckAim(cover: cover, holds: nil), .stop)
            XCTAssertEqual(Handlers.recheckAim(cover: cover, holds: true), .stop, "out of view, its picture can't be trusted")
        }
        XCTAssertEqual(Handlers.recheckAim(cover: .inView, holds: true), .go)
        XCTAssertEqual(Handlers.recheckAim(cover: .inView, holds: false), .retake)
        XCTAssertEqual(Handlers.recheckAim(cover: .inView, holds: nil), .retake)
    }

    // MARK: - the window's size

    /// The window's size in points goes with an image whose scale isn't that of the last image of the window the agent
    /// was shown (as the reply rounds it), never with the first one or a zoom.
    func testTheWindowsSizeComesWhenTheScaleChanges() {
        XCTAssertTrue(Handlers.tellsWindowSize(scale: 0.64, last: 0.75, zoom: false))
        XCTAssertTrue(Handlers.tellsWindowSize(scale: 0.75, last: 0.4, zoom: false))
        XCTAssertFalse(Handlers.tellsWindowSize(scale: 0.75, last: 0.75, zoom: false))
        XCTAssertFalse(Handlers.tellsWindowSize(scale: 0.6362, last: 0.6449, zoom: false), "both 0.64 as given")
        XCTAssertFalse(Handlers.tellsWindowSize(scale: 0.64, last: nil, zoom: false), "the first image")
        XCTAssertFalse(Handlers.tellsWindowSize(scale: 2, last: 0.75, zoom: true), "a zoom")
    }

    /// An address bar's address as a reply gives a page's: shown without its scheme, given without it, its query cut
    /// short as a page's is.
    func testTheAddressBarsAddressAsARepliesGivesIt() {
        XCTAssertEqual(Handlers.shortAddress("localhost:3000/dashboard"), "localhost:3000/dashboard")
        XCTAssertEqual(Handlers.shortAddress("example.com/docs?q=cats"), "example.com/docs?q=cats")
        XCTAssertEqual(Handlers.shortAddress("https://example.com/a"), "https://example.com/a")
        XCTAssertEqual(Handlers.shortAddress("about:config"), "about:config")
        let long = Handlers.shortAddress("example.com/cb?token=" + String(repeating: "x", count: 80))
        XCTAssertTrue(long.hasPrefix("example.com/cb?token=") && long.hasSuffix("…") && long.count < 70, long)
    }
}

/// Finding a browser window's address bar and its page in its accessibility tree, with made-up elements.
@MainActor
final class BrowserChromeTests: XCTestCase {
    /// A made-up accessibility element: a role, a value and children.
    final class Fake {
        let element: AXUIElement
        let role: String
        let value: String?
        var kids: [Fake]
        init(_ id: Int, _ role: String, value: String? = nil, kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(951_000 + id))  // a distinct element; never asked anything
            (self.role, self.value, self.kids) = (role, value, kids)
        }
    }

    func everything(_ f: Fake) -> [Fake] { [f] + f.kids.flatMap(everything) }

    /// An element's `AX.attrs` as the app would give them.
    func attrs(_ el: AXUIElement, _ all: [Fake]) -> [AnyObject]? {
        guard let f = all.first(where: { CFEqual($0.element, el) }) else { return nil }
        let none = NSNull()
        return [f.role as NSString, none, none, none, (f.value as NSString?) ?? none, f.kids.map(\.element) as NSArray,
                none, none, none, kCFBooleanTrue, none, none, none, none]
    }

    /// The text input in a toolbar whose value is an address: not a search box's words, a field in the page, or a
    /// field outside the toolbars.
    func testTheAddressBarIsTheToolbarsFieldWithAnAddress() throws {
        let urlbar = Fake(4, "AXComboBox", value: "localhost:3000/dashboard")
        let toolbar = Fake(2, "AXToolbar", kids: [Fake(3, "AXButton"), Fake(5, "AXGroup", kids: [urlbar]),
                                                  Fake(6, "AXSearchField", value: "cats and dogs")])
        let page = Fake(7, "AXWebArea", kids: [Fake(8, "AXTextField", value: "example.com")])
        let win = Fake(1, "AXWindow", kids: [Fake(9, "AXTextField", value: "example.org"), page, toolbar])
        let all = everything(win)
        let found = try XCTUnwrap(AX.addressBar(in: win.element, read: { self.attrs($0, all) }))
        XCTAssertTrue(CFEqual(found.field, urlbar.element))
        XCTAssertEqual(found.address, "localhost:3000/dashboard")
        urlbar.kids = []
        let empty = Fake(10, "AXComboBox", value: "")  // a new tab's
        let bare = Fake(11, "AXWindow", kids: [Fake(12, "AXToolbar", kids: [empty])])
        XCTAssertNil(AX.addressBar(in: bare.element, read: { self.attrs($0, self.everything(bare)) }))
        XCTAssertNil(AX.addressBar(in: win.element, visits: 3, read: { self.attrs($0, all) }), "past its visits")
    }

    /// The page as accessibility shows it: a web area with something in it, an empty one (or one loading), none in the
    /// whole window, or not known when the walk runs out first.
    func testThePagesTreeAsAccessibilityShowsIt() {
        func tree(_ win: Fake, visits: Int = 600, loading: Bool = false) -> Handlers.PageTree? {
            AX.pageTree(in: win.element, visits: visits, read: { self.attrs($0, self.everything(win)) }, loading: { _ in loading })
        }
        let toolbar = Fake(21, "AXToolbar", kids: [Fake(22, "AXButton"), Fake(23, "AXComboBox", value: "example.com")])
        let page = Fake(24, "AXWebArea", kids: [Fake(25, "AXHeading")])
        let win = Fake(20, "AXWindow", kids: [toolbar, Fake(26, "AXGroup", kids: [page])])
        XCTAssertEqual(tree(win), .shown)
        page.kids = []
        XCTAssertEqual(tree(win), .empty)
        XCTAssertEqual(tree(win, loading: true), .loading)
        win.kids = [toolbar, Fake(27, "AXGroup")]
        XCTAssertEqual(tree(win), .missing, "only the toolbar: the page has no tree")
        XCTAssertNil(tree(win, visits: 2), "ran out before it could tell")
    }

    /// What a browser window's address bar holds as it is: an address, or nothing on a new tab; nil with no text input
    /// in a toolbar.
    func testTheAddressBarsTextAsItIs() {
        let urlbar = Fake(31, "AXComboBox", value: "")
        let win = Fake(30, "AXWindow", kids: [Fake(32, "AXTextField", value: "outside"), Fake(33, "AXToolbar", kids: [urlbar])])
        XCTAssertEqual(AX.addressText(in: win.element, read: { self.attrs($0, self.everything(win)) }), "")
        let page = Fake(34, "AXComboBox", value: "localhost:3000/a")
        let other = Fake(35, "AXWindow", kids: [Fake(36, "AXToolbar", kids: [page])])
        XCTAssertEqual(AX.addressText(in: other.element, read: { self.attrs($0, self.everything(other)) }), "localhost:3000/a")
        let bare = Fake(37, "AXWindow", kids: [Fake(38, "AXTextField", value: "outside")])
        XCTAssertNil(AX.addressText(in: bare.element, read: { self.attrs($0, self.everything(bare)) }))
    }

    /// A match in a page is marked in it, one in the window's tabs or toolbar (which carry the page's title) isn't, and
    /// a search of the page alone finds only the first: none at all when the window has no page tree.
    func testAMatchInTheTabsIsntInThePage() {
        let tab = Fake(41, "AXRadioButton", value: "Dashboard | test")
        let heading = Fake(44, "AXStaticText", value: "Dashboard")
        let page = Fake(43, "AXWebArea", kids: [heading])
        let win = Fake(40, "AXWindow", kids: [Fake(42, "AXTabGroup", kids: [tab]), Fake(45, "AXGroup", kids: [page])])
        func search(_ w: Fake, pageOnly: Bool = false) -> [AX.Match] {
            let all = everything(w)
            return AX.search(in: [(w.element, CGRect(x: 0, y: 0, width: 1000, height: 800))], menus: [], query: "Dashboard",
                             role: nil, limit: 10, budget: 1, offScreen: false, pageOnly: pageOnly, now: { 0 },
                             read: { self.attrs($0, all) }).matches
        }
        let both = search(win)
        XCTAssertEqual(both.map(\.label), ["Dashboard | test", "Dashboard"])
        XCTAssertEqual(both.map(\.inPage), [false, true])
        XCTAssertEqual(search(win, pageOnly: true).map(\.label), ["Dashboard"])
        let frozen = Fake(46, "AXWindow", kids: [Fake(47, "AXTabGroup", kids: [Fake(48, "AXRadioButton", value: "Dashboard")])])
        XCTAssertEqual(search(frozen).map(\.inPage), [false])
        XCTAssertEqual(search(frozen, pageOnly: true).count, 0)
    }
}
