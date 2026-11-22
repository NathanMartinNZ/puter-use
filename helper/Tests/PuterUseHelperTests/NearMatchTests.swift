import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// A target's text the same but for case, spacing and "..." vs "…" is a whole-label match; and a target that
/// matches nothing lists what's near it (`AX.Near`), from its own window and what's open over it only. Made-up
/// windows and match lists (no app needed).
@MainActor
final class NearMatchTests: XCTestCase {
    final class Fake {
        let element: AXUIElement
        let role: String
        let title: String?
        let help: String?
        let frame: CGRect
        var kids: [Fake]
        init(_ id: Int, _ role: String, title: String? = nil, help: String? = nil, frame: CGRect, kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(940_000 + id))  // a distinct element; never asked anything
            (self.role, self.title, self.help, self.frame, self.kids) = (role, title, help, frame, kids)
        }
    }

    var byElement: [AXUIElement: Fake] = [:]
    var id = 0

    func read(_ el: AXUIElement) -> [AnyObject]? {
        guard let f = byElement[el] else { return nil }
        var pos = f.frame.origin, size = f.frame.size
        let none = NSNull()
        return [f.role as NSString, none, (f.title as NSString?) ?? none, none, none, f.kids.map(\.element) as NSArray,
                AXValueCreate(.cgPoint, &pos)!, AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, none, none,
                (f.help as NSString?) ?? none, none]
    }

    func make(_ role: String, _ title: String?, y: CGFloat = 10, help: String? = nil, _ kids: [Fake] = []) -> Fake {
        id += 1
        let f = Fake(id, role, title: title, help: help, frame: CGRect(x: 10, y: y, width: 80, height: 20), kids: kids)
        byElement[f.element] = f
        return f
    }

    func window(_ kids: [Fake], x: CGFloat = 0) -> Fake {
        id += 1
        let f = Fake(id, "AXWindow", title: "W", frame: CGRect(x: x, y: 0, width: 400, height: 400), kids: kids)
        byElement[f.element] = f
        return f
    }

    func search(_ roots: [Fake], _ q: String, role: String? = nil, near: AX.Near? = nil) -> [AX.Match] {
        AX.search(in: roots.map { ($0.element, $0.frame) }, menus: [], query: q, role: role, limit: 50, budget: 1.5,
                  offScreen: near != nil, near: near, now: { 0 }, read: read).matches
    }

    // MARK: - the same label

    /// Case, runs of spaces and "..." vs "…" don't matter: a whole-label match.
    func testTheSameButForCaseSpacingAndDotsIsAWholeLabelMatch() {
        let win = window([make("AXButton", "New Window"), make("AXButton", "Save…", y: 40), make("AXButton", "Export...", y: 70)])
        for q in ["new window", "NEW WINDOW", "New  Window", " New\tWindow "] {
            let got = search([win], q)
            XCTAssertEqual(got.map(\.label), ["New Window"], q)
            XCTAssertEqual(got.map(\.exact), [true], q)
        }
        XCTAssertEqual(search([win], "Save...").map(\.label), ["Save…"])
        XCTAssertEqual(search([win], "Save...").map(\.exact), [true])
        XCTAssertEqual(search([win], "export…").map(\.label), ["Export..."])
        XCTAssertEqual(search([win], "export…").map(\.exact), [true])
    }

    /// What matched before matches as before: a part of a label is still a part (and nothing that only contains
    /// the text once normalised becomes a match).
    func testWhatMatchedBeforeIsUnchanged() {
        let win = window([make("AXButton", "Save draft"), make("AXButton", "Save", y: 40), make("AXButton", "Save... As", y: 70)])
        let got = search([win], "save")
        XCTAssertEqual(got.map(\.label), ["Save draft", "Save", "Save... As"])
        XCTAssertEqual(got.map(\.exact), [false, true, false])
        XCTAssertEqual(Handlers.narrowed(got, Handlers.Spec(text: "save")).map(\.label), ["Save"])
        XCTAssertTrue(search([win], "Save…").isEmpty)  // in "Save... As" but for "...": only whole labels are normalised
        XCTAssertEqual(search([win], "Save… As").map(\.exact), [true])
        XCTAssertTrue(search([win], "Savedraft").isEmpty)  // near it, not it
    }

    // MARK: - what's near

    func testParts() {
        XCTAssertEqual(AX.Near.parts("Log in…").squashed, "login")
        XCTAssertEqual(AX.Near.parts("Log in…").words, ["log"])  // "in" says nothing
        XCTAssertEqual(AX.Near.parts("OpenSheet").words, ["open", "sheet"])
        XCTAssertEqual(AX.Near.parts("Sign-in with Google").words, ["sign", "google"])
        XCTAssertEqual(AX.Near.parts("save button").words, ["save"])
        XCTAssertEqual(AX.Near.parts("Row 9").words, ["row", "9"])
        XCTAssertEqual(AX.Near.parts("Café").squashed, "café")
    }

    func testRanks() {
        let login = AX.Near("Login")
        XCTAssertEqual(login.rank("Log in")?.tier, 0)
        XCTAssertEqual(login.rank("Log-In…")?.tier, 0)
        XCTAssertEqual(login.rank("Log in with Google")?.tier, 1)
        XCTAssertNil(login.rank("Sign in"))
        XCTAssertEqual(AX.Near("save button").rank("Save")?.tier, 2)
        XCTAssertEqual(AX.Near("OpenSheet").rank("Open Sheet")?.tier, 0)
        XCTAssertEqual(AX.Near("OpenSheet").rank("Sheet Later")?.tier, 2)
        XCTAssertNil(AX.Near("Frobnicate").rank("Save"))
        XCTAssertNil(AX.Near("Frobnicate").rank("Frob"))  // part of it isn't near
        // One word in common with a long label isn't enough.
        XCTAssertNil(AX.Near("Submit order").rank("Your order will ship in three to five days"))
        XCTAssertNil(AX.Near("ok").rank("Booking"))  // too short to be found inside a word
        XCTAssertNil(AX.Near("Save").rank(String(repeating: "save ", count: 40)))  // long text never is
        XCTAssertTrue(AX.Near("save button").rank("Save")! < AX.Near("save button").rank("Save Draft")!)  // less else said
        XCTAssertTrue(AX.Near("open the file").rank("Open File")! < AX.Near("open the file").rank("Open Sheet")!)
    }

    func m(_ label: String, role: String = "button", _ n: Int) -> AX.Match {
        AX.Match(element: AXUIElementCreateApplication(pid_t(950_000 + n)), role: role, label: label, frame: nil, exact: false)
    }

    func seen(_ near: AX.Near, _ ms: [AX.Match]) -> [(rank: AX.Near.Rank, match: AX.Match)] {
        ms.compactMap { x in near.rank(x.label).map { ($0, x) } }
    }

    /// The same but for spaces and punctuation beats sharing words, wherever it is; and when there is one, only
    /// those are listed.
    func testTheSameButForSpacingBeatsSharedWords() {
        let near = AX.Near("Log in now")
        let ms = [m("Log in", 1), m("Log out", 2), m("Login now", 3)]
        XCTAssertEqual(AX.Near.best(seen(near, ms), 3).map(\.label), ["Login now"])
        let some = AX.Near("save draft")
        XCTAssertEqual(AX.Near.best(seen(some, [m("Draft", 1), m("Save draft copy", 2), m("Save", 3)]), 3).map(\.label),
                       ["Save draft copy", "Draft", "Save"])  // contains it, then words, fewest others first
    }

    func testAtMostThree() {
        let near = AX.Near("Open item")
        let apps = ["Mail", "Notes", "Maps", "Photos", "Music"].enumerated().map { m("Open \($0.element)", $0.offset) }
        XCTAssertEqual(AX.Near.best(seen(near, apps), 3).map(\.label), ["Open Mail", "Open Notes", "Open Maps"])
    }

    /// A word with an ending added is the same word; a different number is a different thing.
    func testEndingsAndNumbers() {
        let boxes = AX.Near("Far Boxes")
        XCTAssertEqual(AX.Near.best(seen(boxes, [m("Delete Far", 1), m("Far Field", 2), m("Far Box", 3)]), 3).map(\.label),
                       ["Far Box", "Far Field", "Delete Far"])
        XCTAssertNil(AX.Near("Login").rank("Log out"))  // "log" + "in" isn't an ending
        XCTAssertNotNil(AX.Near("saved drafts").rank("Save Draft"))
        XCTAssertNil(AX.Near("Row 99").rank("Row 9"))
        XCTAssertNil(AX.Near("Row 99").rank("Row 98"))
        XCTAssertNotNil(AX.Near("Row 99").rank("Rows 99"))
        XCTAssertNotNil(AX.Near("Page 2").rank("Next Page"))  // no number there to differ
    }

    /// Controls before bare labels; a bare label repeating one listed is left out; `ok` is asked only as far as
    /// needed, and what it refuses (behind a sheet) is skipped.
    func testControlsFirstNoRepeatsAndOk() {
        let near = AX.Near("Login")
        let ms = [m("Log in", role: "text", 1), m("Log in", 2), m("Log  in", role: "link", 3), m("Log-in", 4), m("Log in", 5)]
        XCTAssertEqual(AX.Near.best(seen(near, ms), 3).map(\.role), ["button", "link", "button"])
        var asked = 0
        let got = AX.Near.best(seen(near, ms), 2) { x in asked += 1; return !CFEqual(x.element, ms[1].element) }
        XCTAssertEqual(got.map(\.label), ["Log  in", "Log-in"])
        XCTAssertEqual(asked, 3)
        XCTAssertTrue(AX.Near.best(seen(AX.Near("Frobnicate"), ms), 3).isEmpty)
    }

    // MARK: - in the walk

    /// What's near comes from the windows searched only (the target's and what's open over it), never from the
    /// app's other windows, though one of those has the best match; matches aren't listed as near; and what's
    /// out of view is tagged.
    func testNearComesOnlyFromTheWindowsSearched() {
        let target = window([make("AXButton", "Sign in"), make("AXButton", "Login help", y: 40),
                             make("AXButton", "Log in later", y: 900)])
        let sheet = window([make("AXButton", "Log In Now", y: 60)], x: 20)
        let other = window([make("AXButton", "Log in", y: 60)], x: 500)  // another of the app's windows: not searched
        _ = other
        let near = AX.Near("Login")
        let found = search([target, sheet], "Login", near: near)
        XCTAssertTrue(found.isEmpty)  // "Login help" is shown: not an off-screen match
        XCTAssertEqual(near.best(3).map(\.label), ["Log In Now", "Log in later"])  // less else said first
        XCTAssertEqual(near.best(3).map(\.offScreen), [false, true])
        XCTAssertFalse(near.seen.contains { $0.match.label == "Login help" })  // it's a match, not near
    }

    /// A role that rules out the element with the text makes that element near, not a match.
    func testAnotherRoleIsNear() {
        let win = window([make("AXButton", "Save")])
        let near = AX.Near("Save")
        XCTAssertTrue(search([win], "Save", role: "link", near: near).isEmpty)
        XCTAssertEqual(near.best(3).map(\.role), ["button"])
    }

    /// A miss ends in the same error wherever the target was used (an action, a read): what's off screen showing
    /// the text, then what's near it.
    func testAMissSaysWhatsOffScreenAndNear() throws {
        let w = WinInfo(id: 424_401, pid: 424_401, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        let e = Handlers.NotFound(description: "nothing shows \"Note pad\" in the window", offScreen: "; off screen: [3] …",
                                  near: "; similar: [4] textarea \"Notes\" (…)")
        XCTAssertEqual("\(try Handlers.missError(e, "Note pad", .window(w)))",
                       "nothing shows \"Note pad\" in the window; off screen: [3] …; similar: [4] textarea \"Notes\" (…)")
        let bare = Handlers.NotFound(description: "nothing shows \"X\" in the window")
        XCTAssertEqual("\(try Handlers.missError(bare, "X", .window(w)))", "nothing shows \"X\" in the window")
    }

    /// A label's tooltip counts too, but the label is what's listed when it's the nearer.
    func testTheNearestTextIsListed() {
        let win = window([make("AXButton", "Save", help: "Saves nothing: a test button")])
        let near = AX.Near("save button")
        _ = search([win], "save button", near: near)
        XCTAssertEqual(near.best(3).map(\.label), ["Save"])
    }
}
