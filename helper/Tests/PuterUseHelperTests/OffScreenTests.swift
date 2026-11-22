import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// `target` and `find` reach elements scrolled out of view: the off-screen search finds only what the on-screen
/// one skips, a target takes only a single whole-label match there, and an element is acted on only once it's
/// in view. A made-up window (no app needed).
@MainActor
final class OffScreenTests: XCTestCase {
    final class Fake {
        let element: AXUIElement
        let role: String
        let title: String?
        let frame: CGRect
        var kids: [Fake]
        init(_ id: Int, _ role: String, title: String? = nil, frame: CGRect, kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(910_000 + id))  // a distinct element; never asked anything
            (self.role, self.title, self.frame, self.kids) = (role, title, frame, kids)
        }
    }

    var byElement: [AXUIElement: Fake] = [:]
    var clock: TimeInterval = 0

    func read(_ el: AXUIElement) -> [AnyObject]? {
        clock += 0.01
        guard let f = byElement[el] else { return nil }
        var pos = f.frame.origin, size = f.frame.size
        let none = NSNull()
        return [f.role as NSString, none, (f.title as NSString?) ?? none, none, none, f.kids.map(\.element) as NSArray,
                AXValueCreate(.cgPoint, &pos)!, AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, none, none, none, none]
    }

    /// A 400 pt window: buttons "Row 1"…"Row 20" every 30 pt (rows 1–13 inside it), a "Save draft" button
    /// inside, and below it a "Save" button and a group whose "Pinned" button is drawn inside the window.
    func window() -> Fake {
        var id = 0
        func make(_ role: String, _ title: String?, _ frame: CGRect, _ kids: [Fake] = []) -> Fake {
            id += 1
            return Fake(id, role, title: title, frame: frame, kids: kids)
        }
        var kids = (1...20).map { make("AXButton", "Row \($0)", CGRect(x: 10, y: CGFloat($0) * 30, width: 60, height: 20)) }
        kids.append(make("AXButton", "Save draft", CGRect(x: 100, y: 40, width: 80, height: 20)))
        kids.append(make("AXButton", "Save", CGRect(x: 100, y: 700, width: 80, height: 20)))
        kids.append(make("AXGroup", nil, CGRect(x: 0, y: 900, width: 300, height: 100),
                         [make("AXButton", "Pinned", CGRect(x: 100, y: 100, width: 80, height: 20))]))
        let win = make("AXWindow", "W", CGRect(x: 0, y: 0, width: 400, height: 400), kids)
        var all: [Fake] = []
        func collect(_ f: Fake) { all.append(f); f.kids.forEach(collect) }
        collect(win)
        byElement = Dictionary(uniqueKeysWithValues: all.map { ($0.element, $0) })
        return win
    }

    func search(_ win: Fake, _ q: String, offScreen: Bool, limit: Int = 50, budget: TimeInterval = 1.5) -> (matches: [AX.Match], complete: Bool) {
        AX.search(in: [(win.element, win.frame)], menus: [], query: q, role: nil, limit: limit, budget: budget,
                  offScreen: offScreen, now: { self.clock }, read: read)
    }

    // MARK: - the search

    /// The off-screen search finds exactly what the on-screen one skips, tagged; the on-screen one is unchanged.
    func testTheOffScreenSearchFindsOnlyWhatTheOtherSkips() {
        let win = window()
        let shown = search(win, "Row", offScreen: false)
        XCTAssertEqual(shown.matches.map(\.label), (1...13).map { "Row \($0)" })
        XCTAssertTrue(shown.matches.allSatisfy { !$0.offScreen })
        XCTAssertTrue(shown.complete)
        let away = search(win, "Row", offScreen: true)
        XCTAssertEqual(away.matches.map(\.label), (14...20).map { "Row \($0)" })
        XCTAssertTrue(away.matches.allSatisfy(\.offScreen))
        XCTAssertTrue(away.complete)
    }

    /// A list scrolled partway, inside a window: rows in the window but outside the list's scroll area (above
    /// or below its visible part) are found by the on-screen search, tagged off screen (find lists them so, after
    /// those shown, with no place in the window: theirs would land on other controls); the off-screen search still
    /// finds only what's outside the window. So does a role-only search.
    func testRowsScrolledOutOfAListInsideTheWindowAreTaggedOffScreen() {
        var id = 100
        func make(_ role: String, _ title: String?, _ frame: CGRect, _ kids: [Fake] = []) -> Fake {
            id += 1
            return Fake(id, role, title: title, frame: frame, kids: kids)
        }
        // Rows every 30 pt from y 10: the list shows y 110-250 (rows 4-8, row 4 partly); rows 9-13 are below it, in the
        // 380 pt window.
        let rows = (1...20).map { make("AXButton", "Row \($0)", CGRect(x: 300, y: CGFloat($0) * 30 - 20, width: 60, height: 22)) }
        let list = make("AXScrollArea", nil, CGRect(x: 300, y: 110, width: 80, height: 140), rows)
        let win = make("AXWindow", "W", CGRect(x: 0, y: 0, width: 400, height: 380),
                       [make("AXButton", "Sheet Later", CGRect(x: 100, y: 40, width: 100, height: 30)), list])
        var all: [Fake] = []
        func collect(_ f: Fake) { all.append(f); f.kids.forEach(collect) }
        collect(win)
        byElement = Dictionary(uniqueKeysWithValues: all.map { ($0.element, $0) })

        let shown = search(win, "Row", offScreen: false).matches
        XCTAssertEqual(shown.map(\.label), (1...13).map { "Row \($0)" })
        XCTAssertEqual(shown.filter { !$0.offScreen }.map(\.label), (4...8).map { "Row \($0)" })
        XCTAssertEqual(Handlers.shownFirst(shown).map(\.label), ([4, 5, 6, 7, 8, 1, 2, 3, 9, 10, 11, 12, 13]).map { "Row \($0)" })
        XCTAssertEqual(search(win, "Row", offScreen: true).matches.map(\.label), (14...20).map { "Row \($0)" })
        let byRole = AX.search(in: [(win.element, win.frame)], menus: [], query: "", role: "button", limit: 50, budget: 1.5,
                               offScreen: false, now: { self.clock }, read: read).matches
        XCTAssertEqual(byRole.filter { !$0.offScreen }.map(\.label), ["Sheet Later"] + (4...8).map { "Row \($0)" })
        let row1 = byRole.first { $0.label == "Row 1" }!
        XCTAssertEqual(Handlers.describe(row1, id: 9, .screen), "[9] button \"Row 1\" (off screen)")
        // A row half shown at the list's edge is shown (4 pt of it each way, as acting on it goes by).
        XCTAssertFalse(shown.first { $0.label == "Row 4" }!.offScreen)
    }

    /// What's in a container outside the window counts as off screen, even where its own frame says otherwise
    /// (the on-screen search never looks inside it).
    func testInsideAContainerOutsideTheWindowIsOffScreen() {
        let win = window()
        XCTAssertTrue(search(win, "Pinned", offScreen: false).matches.isEmpty)
        XCTAssertEqual(search(win, "Pinned", offScreen: true).matches.map(\.label), ["Pinned"])
    }

    /// A visible match that only contains the text is what a target gets (as before): the off-screen search,
    /// run only when nothing on screen matches, isn't needed for the whole-label "Save" below.
    func testAVisibleMatchWins() {
        let win = window()
        let shown = search(win, "Save", offScreen: false).matches
        XCTAssertEqual(shown.map(\.label), ["Save draft"])
        XCTAssertEqual(Handlers.narrowed(shown, Handlers.Spec(text: "Save")).map(\.label), ["Save draft"])
        XCTAssertEqual(search(win, "Save", offScreen: true).matches.map(\.label), ["Save"])
    }

    /// It says when it didn't look everywhere: out of time, or at its limit.
    func testIncompleteSearchesSaySo() {
        let win = window()
        XCTAssertFalse(search(win, "Row", offScreen: true, limit: 3).complete)
        XCTAssertEqual(search(win, "Row", offScreen: true, limit: 3).matches.count, 3)
        clock = 0
        let slow = search(win, "Save", offScreen: true, budget: 0.1)  // 10 reads
        XCTAssertFalse(slow.complete)
        XCTAssertTrue(slow.matches.isEmpty)
    }

    /// Nothing off screen shows it either: a clean miss (an optional step is skipped for it) only when that search
    /// looked everywhere. One that ran out of time with nothing found says so, and is an error, never skipped.
    func testAMissAfterAnOffScreenSearchThatStoppedEarlyIsntClean() throws {
        let sp = Handlers.Spec(text: "Accept all")
        let step: [String: Any] = ["type": "click", "target": "Accept all", "optional": true]
        let whole = Handlers.offScreenMiss(sp, complete: true, near: "")
        XCTAssertTrue(whole.clean)
        XCTAssertEqual(whole.description, "nothing shows \"Accept all\" in the window")
        let skipped = try Handlers.missError(whole, "Accept all", .screen)
        XCTAssertTrue(skipped is Handlers.Missing)
        XCTAssertTrue(Handlers.skipsOptional(step, skipped, found: false))

        let win = window()
        clock = 0
        let slow = search(win, "Accept all", offScreen: true, budget: 0.1)  // out of time, nothing found
        XCTAssertTrue(slow.matches.isEmpty)
        let cut = Handlers.offScreenMiss(sp, complete: slow.complete, near: "; similar (…): [3] button \"Allow\"")
        XCTAssertFalse(cut.complete)
        XCTAssertFalse(cut.clean)
        let e = try Handlers.missError(cut, "Accept all", .screen)
        XCTAssertTrue(e is HelperError, "not everything was looked at")
        XCTAssertFalse(Handlers.skipsOptional(step, e, found: false))
        XCTAssertEqual("\(e)", "nothing shows \"Accept all\" in the window; the search off screen stopped early (the app "
            + "answered slowly), so part of the window wasn't looked at; similar (…): [3] button \"Allow\"")
        // The flag alone is enough.
        XCTAssertFalse(Handlers.NotFound(description: "nothing shows \"X\" in the window", complete: false).clean)
    }

    // MARK: - what a target takes off screen

    func match(_ label: String, role: String = "button", exact: Bool = true, _ id: Int) -> AX.Match {
        AX.Match(element: AXUIElementCreateApplication(pid_t(920_000 + id)), role: role, label: label, frame: nil,
                 exact: exact, offScreen: true)
    }

    /// Where the picks are: below a 400 pt list, unless said otherwise.
    func pick(_ open: [AX.Match], _ sp: Handlers.Spec, complete: Bool = true,
              seen: AX.Sight? = AX.Sight(frame: CGRect(x: 905, y: 2300, width: 54, height: 13),
                                         view: CGRect(x: 900, y: 500, width: 80, height: 400))) -> AX.Match? {
        Handlers.offScreenPick(open, sp, complete: complete, sight: { _ in seen })
    }

    func testASingleWholeLabelMatchIsTaken() {
        let sp = Handlers.Spec(text: "Row 70")
        let one = match("Row 70", 1)
        let got = pick([one, match("Row 700", exact: false, 2)], sp)
        XCTAssertTrue(got.map { CFEqual($0.element, one.element) } == true)
    }

    /// A control and a bare label saying the same (a button and its text): the control, as on screen.
    func testAControlBeatsItsLabel() {
        let button = match("Agree", 1)
        let got = pick([match("Agree", role: "text", 2), button], Handlers.Spec(text: "Agree"))
        XCTAssertTrue(got.map { CFEqual($0.element, button.element) } == true)
    }

    func testAmbiguousPartialOrUnsureMatchesAreNotTaken() {
        let sp = Handlers.Spec(text: "Save")
        XCTAssertNil(pick([match("Save", 1), match("Save", 2)], sp))  // two
        XCTAssertNil(pick([match("Save draft", exact: false, 3)], sp))  // only part
        XCTAssertNil(pick([match("Save", 4)], sp, complete: false))  // may be more: not looked everywhere
        XCTAssertNil(pick([match("Save", 5)], Handlers.Spec(text: "Save", nth: 2)))
        XCTAssertNotNil(pick([match("Save", 6)], Handlers.Spec(text: "Save", nth: 1)))
    }

    /// Taken only when it's known to be off screen: not with no sight (no frame, in a menu), under a point, nothing
    /// around it, or in view after all.
    func testAPickWhereItIsCantBeToldIsNotTaken() {
        let sp = Handlers.Spec(text: "Save")
        let view = CGRect(x: 900, y: 500, width: 80, height: 400)
        XCTAssertNil(pick([match("Save", 1)], sp, seen: nil))
        XCTAssertNil(pick([match("Save", 2)], sp, seen: AX.Sight(frame: CGRect(x: 905, y: 2300, width: 54, height: 0), view: view)))
        XCTAssertNil(pick([match("Save", 3)], sp, seen: AX.Sight(frame: CGRect(x: 905, y: 2300, width: 54, height: 13), view: nil)))
        XCTAssertNil(pick([match("Save", 4)], sp, seen: AX.Sight(frame: CGRect(x: 905, y: 600, width: 54, height: 13), view: view)))
        XCTAssertTrue(Handlers.unknown(nil))
        XCTAssertTrue(Handlers.unknown(AX.Sight(frame: CGRect(x: 0, y: 0, width: 0.5, height: 20), view: view)))
        XCTAssertFalse(Handlers.unknown(AX.Sight(frame: CGRect(x: 905, y: 2300, width: 54, height: 13), view: view)))
    }

    /// A node numbered by an off-screen search whose place can't be told is refused before anything; one that
    /// wasn't is left alone (no sight there still means "in view", as before).
    func testAnOffScreenNumberWhereItIsCantBeToldIsRefused() async throws {
        let el = AXUIElementCreateApplication(930_010)  // no app: no sight
        let away = AX.Node(element: el, frame: CGRect(x: 905, y: 2300, width: 54, height: 13), role: "AXButton", label: "Save",
                           name: "button", away: true)
        do {
            _ = try await Handlers.reveal(away, "element 7")
            XCTFail("it should be refused")
        } catch let e as HelperError {
            XCTAssertTrue(e.description.hasPrefix("element 7 was found off screen, but where it is can't be told"))
        }
        var shown = away
        shown.away = false
        let got = try await Handlers.reveal(shown, "element 7")
        XCTAssertNil(got)
    }

    // MARK: - part of a label on screen, a whole one off screen

    func shown(_ label: String, exact: Bool, _ id: Int) -> AX.Match {
        AX.Match(element: AXUIElementCreateApplication(pid_t(940_000 + id)), role: "link", label: label,
                 frame: CGRect(x: 10, y: 10, width: 100, height: 20), exact: exact)
    }

    func testAPartialOnScreenConflictsWithAWholeLabelOffScreen() {
        let feedback = shown("Submit feedback", exact: false, 1)
        XCTAssertTrue(Handlers.conflicts([feedback], [match("Submit", 2)]))
        XCTAssertFalse(Handlers.conflicts([feedback], [match("Submit form", exact: false, 3)]))  // only part there too
        XCTAssertFalse(Handlers.conflicts([feedback], []))  // nothing off screen (or not found in the quick look)
        XCTAssertFalse(Handlers.conflicts([shown("Submit", exact: true, 4)], [match("Submit", 5)]))  // a whole one shown wins
        XCTAssertFalse(Handlers.conflicts([], [match("Submit", 6)]))  // nothing shown: the off-screen pick's rules
        XCTAssertEqual(Handlers.conflictBudget, 0.3)
    }

    // MARK: - macros

    /// A step saved from an element number: by name and place when it's in view; by name alone when it's out of
    /// view (its place then is no use), marked `spot` when the name isn't its alone, so a replay doesn't guess.
    func testAStepOnAnOffScreenElementIsSavedByNameAlone() {
        let p = CGPoint(x: 932, y: 2306)
        let far = Macros.byName(label: "Row 70", role: "button", alone: true, away: true, at: p)
        XCTAssertEqual(far.target?["text"] as? String, "Row 70")
        XCTAssertFalse(far.spot)
        XCTAssertNil(far.place)
        let farTwin = Macros.byName(label: "Twin", role: "button", alone: false, away: true, at: p)
        XCTAssertTrue(farTwin.spot)  // one of several, with no place: not replayed (`noSpot`)
        XCTAssertNil(farTwin.place)
        let near = Macros.byName(label: "Twin", role: "button", alone: false, away: false, at: p)
        XCTAssertTrue(near.spot)
        XCTAssertEqual(near.place, p)  // in view: picked out by its place, as before
        let unnamed = Macros.byName(label: nil, role: "button", alone: false, away: true, at: p)
        XCTAssertNil(unnamed.target)
        XCTAssertNil(unnamed.place)
    }

    /// The step is saved without puter-use's own `_` keys a client sent.
    func testASavedStepHasNoInternalKeys() {
        let step = Macros.record(Handlers.external(["type": "click", "target": "Row 70", "_pointer": true, "_last": true]), .screen)
        XCTAssertFalse(step.keys.contains { $0.hasPrefix("_") })
        XCTAssertEqual(step["target"] as? String, "Row 70")
    }

    /// Whether a name picks out the element alone, on screen or off.
    func testANameIsTheElementsAloneOnlyWhenNothingElseHasIt() {
        let sp = Handlers.Spec(text: "Save")
        let mine = shown("Save", exact: true, 10)
        XCTAssertTrue(Handlers.alone(mine.element, shown: [mine], away: [], complete: true, sp))
        XCTAssertFalse(Handlers.alone(mine.element, shown: [mine], away: [match("Save", 11)], complete: true, sp))
        XCTAssertFalse(Handlers.alone(mine.element, shown: [mine], away: [], complete: false, sp))
        let off = match("Save", 12)
        XCTAssertTrue(Handlers.alone(off.element, shown: [shown("Save draft", exact: false, 13)], away: [off], complete: true, sp))
        XCTAssertFalse(Handlers.alone(off.element, shown: [mine], away: [], complete: true, sp))
    }

    /// A step saved as one of several with no place (it was out of view) isn't replayed: no search, nothing done.
    func testAStepWithNoPlaceToPickItOutIsNotReplayed() async throws {
        let w = WinInfo(id: 424_321, pid: 424_321, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        let step: [String: Any] = ["type": "click", "target": ["text": "Row 70", "role": "button"], "spot": true]
        for attempt in 0..<2 {
            do {
                if attempt == 0 { _ = try await Handlers.actionPoint(step, .window(w)) } else { _ = try Handlers.elementNode(step, .window(w)) }
                XCTFail("it should be refused")
            } catch let e as HelperError {
                XCTAssertTrue(e.description.contains("was one of several with that name when the macro was saved"), e.description)
            }
        }
    }

    /// find tags them instead of giving a place.
    func testFindTagsThem() {
        let w = WinInfo(id: 424_311, pid: 424_311, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        XCTAssertEqual(Handlers.describe(match("Row 70", 1), id: 71, .window(w)), "[71] button \"Row 70\" (off screen)")
    }

    // MARK: - the policy before any scroll

    struct Stop: Error {}
    let far = AX.Node(element: AXUIElementCreateApplication(930_001), frame: CGRect(x: 905, y: 2600, width: 54, height: 13),
                      role: "AXButton", label: "Delete Far", name: "button")

    /// The element's checks (`vet`) run once it's found and before it's aimed at (scrolled to): a stop returns no
    /// point, and is the error the action ends with.
    func testAStopComesBeforeTheElementIsAimedAt() async throws {
        let w = WinInfo(id: 424_312, pid: 424_312, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        var vetted: AX.Node?
        do {
            _ = try await Handlers.actionPoint(["type": "click", "_node": far], .window(w), vet: { vetted = $0; throw Stop() })
            XCTFail("the stop should end it")
        } catch is Stop {}
        XCTAssertTrue(vetted.map { CFEqual($0.element, far.element) } == true)
        let got = try await Handlers.actionPoint(["type": "click", "_node": far], .window(w), vet: { _ in })
        XCTAssertEqual(got?.0, CGPoint(x: 932, y: 2606.5))  // no app to ask: where it was numbered
    }

    /// A click's checks, from the element alone: a risky label stops a left click (unless confirmed), and so
    /// do a risky item and Services.
    func testClickChecksNeedNoPoint() throws {
        try XCTSkipUnless(Policy.config.confirm.contains("delete"), "the user's policy file has no \"delete\" confirm")
        XCTAssertThrowsError(try Handlers.clickChecks(["type": "click"], far, button: "left")) { XCTAssertTrue($0 is Policy.NeedsOK) }
        XCTAssertNoThrow(try Handlers.clickChecks(["type": "click", "confirm": true], far, button: "left"))
        XCTAssertNoThrow(try Handlers.clickChecks(["type": "right_click"], far, button: "right"))
        let row = AX.Node(element: AXUIElementCreateApplication(930_002), frame: nil, role: "AXButton", label: "Row 3", name: "button")
        XCTAssertNoThrow(try Handlers.clickChecks(["type": "click"], row, button: "left"))
        XCTAssertThrowsError(try Handlers.clickChecks(["type": "right_click", "item": "Delete"], row, button: "right")) {
            XCTAssertTrue($0 is Policy.NeedsOK)
        }
        XCTAssertThrowsError(try Handlers.clickChecks(["type": "right_click", "item": "Services > Mail"], row, button: "right"))
    }

    // MARK: - in view or not

    let list = CGRect(x: 900, y: 500, width: 80, height: 400)  // a scroll area's visible part

    func sight(_ y: CGFloat, height: CGFloat = 13, width: CGFloat = 54) -> AX.Sight {
        AX.Sight(frame: CGRect(x: 905, y: y, width: width, height: height), view: list)
    }

    func testInViewAndOffScreen() {
        XCTAssertTrue(Handlers.inView(sight(600)))
        XCTAssertFalse(Handlers.offScreen(sight(600)))
        XCTAssertTrue(Handlers.offScreen(sight(2300)))  // further down the list
        XCTAssertTrue(Handlers.offScreen(sight(400)))  // above it
        XCTAssertTrue(Handlers.offScreen(sight(898)))  // only a 2 pt sliver shows
        XCTAssertTrue(Handlers.inView(sight(890)))  // 10 of its 13 pt show
        XCTAssertTrue(Handlers.inView(sight(600, height: 1, width: 1)))  // tiny, and all of it shows
        XCTAssertTrue(Handlers.inView(sight(300, height: 2000)))  // taller than the list: part of it shows
        XCTAssertEqual(Handlers.shownPart(sight(890)), CGRect(x: 905, y: 890, width: 54, height: 10))
        XCTAssertNil(Handlers.shownPart(sight(2300)))
    }

    /// Can't tell (nothing around it, or no size): left alone, as before.
    func testUnknownIsNotOffScreen() {
        XCTAssertFalse(Handlers.offScreen(AX.Sight(frame: CGRect(x: 0, y: 5000, width: 50, height: 10), view: nil)))
        XCTAssertFalse(Handlers.offScreen(AX.Sight(frame: CGRect(x: 0, y: 5000, width: 0, height: 0), view: list)))
    }

    /// The check after scrolling: kept off screen (moved far left), it never comes into view.
    func testKeptOffScreenNeverComesIntoView() {
        let ghost = AX.Sight(frame: CGRect(x: -1078, y: 600, width: 52, height: 12), view: list)
        XCTAssertTrue(Handlers.offScreen(ghost))
        XCTAssertFalse(Handlers.inView(ghost))
        XCTAssertEqual(Handlers.side(ghost), "to the left of")
    }

    func testSides() {
        XCTAssertEqual(Handlers.side(sight(2300)), "below")
        XCTAssertEqual(Handlers.side(sight(100)), "above")
        XCTAssertEqual(Handlers.side(AX.Sight(frame: CGRect(x: 2000, y: 600, width: 50, height: 10), view: list)), "to the right of")
    }
}
