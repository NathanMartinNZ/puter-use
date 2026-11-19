import XCTest

@testable import PuterUseHelper

/// The messages and checks of the outline, window and menu fixes that don't need Accessibility
/// permission (there is none under `swift test`).
@MainActor
final class Tier4Tests: XCTestCase {
    /// A gone element number lists the ones like it, with where they are when that's known.
    func testGoneListsTheElementsLikeIt() {
        let none = AX.Gone(index: 46, was: "button \"Delete\"", like: [])
        XCTAssertEqual(none.description, "element 46 (button \"Delete\") is gone or changed: look again (outline or find) for its new number")
        let two = AX.Gone(index: 46, was: "button \"Delete\"",
                          like: [(47, CGRect(x: 10, y: 20, width: 30, height: 10)), (52, nil)])
        let text = two.text { r in "(\(Int(r.midX)),\(Int(r.midY)))" }
        XCTAssertEqual(text, "element 46 (button \"Delete\") is gone or changed; the window now shows 2 like it: [47] at (25,25), "
            + "[52]. If that's what you meant, use its number (it isn't picked for you)")
        XCTAssertTrue(two.description.contains("[47], [52]"), "without positions: numbers only")
    }

    /// A typed address that's the page's own isn't expected to change it.
    func testSameAddressIgnoresSchemeWwwAndSlash() {
        XCTAssertTrue(Handlers.sameAddress("https://www.example.com/", "example.com"))
        XCTAssertTrue(Handlers.sameAddress("http://example.com/a/", "https://example.com/a"))
        XCTAssertFalse(Handlers.sameAddress("https://example.com/", "example.com/b"))
        XCTAssertFalse(Handlers.sameAddress(nil, "example.com"))
    }

    /// Text that isn't there but was in a menu of this window closed in this call or the last: the error says
    /// so; from another window, or older, it doesn't.
    func testMenuHintNamesTheClosedMenusItem() {
        let s = Session(id: "t-menu-hint", ordinal: 7)
        let w = WinInfo(id: 77, pid: 1, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        let other = WinInfo(id: 78, pid: 1, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        Session.$current.withValue(s) {
            XCTAssertNil(Handlers.menuHint(Handlers.Spec(text: "Blue"), .window(w)))
            s.acts = 5
            s.lastClosedMenu = (["Red", "Blue", "More Colours >"], 77, 5)
            XCTAssertEqual(Handlers.menuHint(Handlers.Spec(text: "blue"), .window(w)),
                "nothing shows \"blue\": \"Blue\" was in a menu closed earlier in this call (an open menu takes the user's "
                + "typing). Open it again and choose in the same click, with item: \"Blue\"")
            XCTAssertTrue(Handlers.menuHint(Handlers.Spec(text: "More Colours"), .window(w))?.hasSuffix("item: \"More Colours\"") == true)
            XCTAssertNil(Handlers.menuHint(Handlers.Spec(text: "Green"), .window(w)))
            XCTAssertNil(Handlers.menuHint(Handlers.Spec(text: "Blue"), .window(other)), "another window's menu")
            s.acts = 6
            XCTAssertTrue(Handlers.menuHint(Handlers.Spec(text: "Blue"), .window(w))?.contains("closed in your last call") == true)
            s.acts = 7
            XCTAssertNil(Handlers.menuHint(Handlers.Spec(text: "Blue"), .window(w)), "older than the last call")
        }
    }

    /// A window that's gone names its app and that app's windows now; one never used names nothing.
    func testAGoneWindowNamesItsApp() {
        let s = Session(id: "t-gone-window", ordinal: 7)
        Session.$current.withValue(s) {
            XCTAssertEqual(Handlers.appWindows(999_999), "")
            s.windowApps[999_999] = ("No Such App Here", 999_999)
            XCTAssertEqual(Handlers.appWindows(999_999), " (it was No Such App Here's, which has no windows now)")
        }
    }
}
