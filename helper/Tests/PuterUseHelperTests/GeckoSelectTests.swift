import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// Picking from a web page's pop-up whose list opens apart from it (Firefox draws a `<select>`'s list in a window
/// of its own, so the pop-up has no options among its children): which open menu is its list, how its options are
/// read, and the fallback of typing an option's first letters, which only ever goes to the pop-up itself.
final class GeckoSelectTests: XCTestCase {
    // MARK: - which menu is its list

    let popup = CGRect(x: 239, y: 637, width: 67, height: 16)

    /// Its list opens over it, or just below or above it, overlapping it across.
    func testAListBelowAboveOrOverThePopupIsItsList() {
        XCTAssertTrue(AX.dropdownFits(menu: CGRect(x: 239, y: 655, width: 120, height: 80), control: popup), "just below")
        XCTAssertTrue(AX.dropdownFits(menu: CGRect(x: 230, y: 560, width: 120, height: 75), control: popup), "just above")
        XCTAssertTrue(AX.dropdownFits(menu: CGRect(x: 235, y: 600, width: 120, height: 90), control: popup), "over it")
        XCTAssertTrue(AX.dropdownFits(menu: CGRect(x: 280, y: 690, width: 120, height: 80), control: popup), "a little lower, overlapping across")
    }

    /// A menu elsewhere (a context menu at the other side of the window, one far below) isn't; nor one whose frame,
    /// or the pop-up's, isn't known.
    func testAMenuElsewhereIsNotItsList() {
        XCTAssertFalse(AX.dropdownFits(menu: CGRect(x: 600, y: 640, width: 120, height: 80), control: popup), "beside it")
        XCTAssertFalse(AX.dropdownFits(menu: CGRect(x: 239, y: 760, width: 120, height: 80), control: popup), "far below")
        XCTAssertFalse(AX.dropdownFits(menu: CGRect(x: 239, y: 400, width: 120, height: 80), control: popup), "far above")
        XCTAssertFalse(AX.dropdownFits(menu: nil, control: popup))
        XCTAssertFalse(AX.dropdownFits(menu: CGRect(x: 239, y: 655, width: 120, height: 80), control: nil))
        XCTAssertFalse(AX.dropdownFits(menu: CGRect(x: 239, y: 655, width: 0, height: 0), control: popup))
    }

    // MARK: - a click when its press opens nothing

    /// Firefox opens a web page's pop-up list in a window that hasn't had a click yet only for a click: when the press
    /// opened no list, one click on it. Not outside a web page or Firefox (the press is what opens those), not with a
    /// list read already, and never with a menu of the app open, from before (not its list) or since (on its way up:
    /// a click would close it again).
    func testAClickOpensItsListOnlyWhenItsPressOpenedNothingInFirefox() {
        XCTAssertTrue(AX.clicksOpen(web: true, gecko: true, menuBefore: false, menuNow: false, listed: false))
        XCTAssertFalse(AX.clicksOpen(web: true, gecko: true, menuBefore: false, menuNow: false, listed: true), "its list is read")
        XCTAssertFalse(AX.clicksOpen(web: false, gecko: true, menuBefore: false, menuNow: false, listed: false), "Firefox's own pop-up")
        XCTAssertFalse(AX.clicksOpen(web: true, gecko: false, menuBefore: false, menuNow: false, listed: false), "another browser")
        XCTAssertFalse(AX.clicksOpen(web: true, gecko: true, menuBefore: true, menuNow: true, listed: false), "a menu was open already")
        XCTAssertFalse(AX.clicksOpen(web: true, gecko: true, menuBefore: false, menuNow: true, listed: false), "a list on its way up")
    }

    // MARK: - reading its options

    final class Fake {
        let element: AXUIElement
        let attrs: [String: String]
        let kids: [Fake]
        init(_ id: Int, _ attrs: [String: String] = [:], kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(932_000 + id))  // a distinct element; never asked anything
            (self.attrs, self.kids) = (attrs, kids)
        }
    }

    func items(_ menu: Fake) -> [String] {
        var all: [AXUIElement: Fake] = [:]
        func add(_ f: Fake) {
            all[f.element] = f
            f.kids.forEach(add)
        }
        add(menu)
        return AX.optionItems(menu.element, read: { all[$0]?.attrs[$1] }, kids: { all[$0]?.kids.map(\.element) ?? [] }).map(\.1)
    }

    /// Menu items by their titles (as Firefox gives its list's), a list of texts by their values, an item named only
    /// by the text in it; separators (no text at all) are left out.
    func testOptionsAreReadByTitleValueOrTheTextInThem() {
        let menu = Fake(1, kids: [
            Fake(2, [kAXTitleAttribute: "Flooding"]), Fake(3, [kAXTitleAttribute: "Wildlife"]), Fake(4),
            Fake(5, [kAXTitleAttribute: " ", kAXValueAttribute: "Transport"]),
            Fake(6, kids: [Fake(7, [kAXValueAttribute: "Other"])]),
        ])
        XCTAssertEqual(items(menu), ["Flooding", "Wildlife", "Transport", "Other"])
        XCTAssertEqual(items(Fake(10)), [], "an empty list")
    }

    // MARK: - typing its first letters

    let options = ["Flooding", "Wildlife", "Transport", "Travel", "Other", "Aardvark", "Abacus", "New York", "New Jersey"]

    /// The shortest start no other option has: one letter where it's alone in starting with it, more where others
    /// share it, case aside.
    func testTheShortestStartThatPicksItAlone() {
        XCTAssertEqual(AX.typeAheadPrefix("Wildlife", among: options), "w")
        XCTAssertEqual(AX.typeAheadPrefix("Flooding", among: options), "f")
        XCTAssertEqual(AX.typeAheadPrefix("Transport", among: options), "tran")
        XCTAssertEqual(AX.typeAheadPrefix("Travel", among: options), "trav")
        XCTAssertEqual(AX.typeAheadPrefix("abacus", among: options), "ab")
    }

    /// One letter again ("aa") steps through the options starting with it one at a time, so it's never typed alone;
    /// a start of other characters (a space, punctuation), one other options share whole, an option twice or one
    /// not among them: nothing is typed.
    func testNoLettersWhenTypingCouldPickAnother() {
        XCTAssertEqual(AX.typeAheadPrefix("Aardvark", among: options), "aar")
        XCTAssertNil(AX.typeAheadPrefix("New York", among: options), "the start that tells them apart has a space")
        XCTAssertNil(AX.typeAheadPrefix("Other", among: options + ["Other (say what)"]), "another starts with all of it")
        XCTAssertNil(AX.typeAheadPrefix("Other", among: options + ["Other"]), "twice")
        XCTAssertNil(AX.typeAheadPrefix("Unknown", among: options))
        XCTAssertNil(AX.typeAheadPrefix("AAA", among: ["AAA", "AB"]), "only the same letter again tells it apart")
        XCTAssertEqual(AX.typeAheadPrefix("AAA", among: ["AAA", "B"]), "a", "once is fine: no other starts with it")
        XCTAssertNil(AX.typeAheadPrefix("Éclair", among: ["Éclair", "Tea"]), "not a key to type")
    }

    /// Letters go only to the pop-up itself, with the focus on it: never to a text field (they'd be typed in),
    /// nor to anything else that has the focus.
    func testLettersGoOnlyToThePopupItself() {
        XCTAssertTrue(AX.canTypeAhead(focusRole: "AXPopUpButton", onControl: true))
        XCTAssertFalse(AX.canTypeAhead(focusRole: "AXPopUpButton", onControl: false), "another pop-up has the focus")
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea", "AXButton"] {
            XCTAssertFalse(AX.canTypeAhead(focusRole: role, onControl: true), role)
            XCTAssertFalse(AX.canTypeAhead(focusRole: role, onControl: false), role)
        }
        XCTAssertFalse(AX.canTypeAhead(focusRole: nil, onControl: true), "focus not known")
    }
}
