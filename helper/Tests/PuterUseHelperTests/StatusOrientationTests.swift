import XCTest

@testable import PuterUseHelper

/// Where the agent is in a window, beside the picture (`Handlers.orient`): the page's address, the focus,
/// what's selected and where a scroll left the scroll bar. Which actions make each worth saying, and how
/// each is worded.
final class StatusOrientationTests: XCTestCase {
    // MARK: - the page's address

    /// Scheme, host and path as they are; never the user name or password an address may carry.
    func testAnAddressKeepsItsSchemeHostAndPath() {
        XCTAssertEqual(Handlers.shortURL("https://example.com/docs/intro"), "https://example.com/docs/intro")
        XCTAssertEqual(Handlers.shortURL("https://ann:secret@example.com/inbox"), "https://example.com/inbox")
        XCTAssertEqual(Handlers.shortURL("http://localhost:8080/admin"), "http://localhost:8080/admin")
        XCTAssertEqual(Handlers.shortURL("about:blank"), "about:blank")
        XCTAssertEqual(Handlers.shortURL("file:///Users/me/page.html"), "file:///Users/me/page.html")
        XCTAssertEqual(Handlers.shortURL("https://mail.example.com/#/inbox"), "https://mail.example.com/#/inbox")
        XCTAssertEqual(Handlers.shortURL("https://example.com/search?"), "https://example.com/search", "an empty query")
        XCTAssertEqual(Handlers.shortURL("https://example.com/a?q=cats"), Handlers.shortURL("https://example.com/a?q=cats"),
                       "the same address reads the same each time (so an unchanged one isn't said again)")
    }

    /// A long query (an OAuth code, a tracking string) is cut short: the path stays whole.
    func testALongQueryIsClipped() {
        let code = String(repeating: "x7Q", count: 40)
        let url = Handlers.shortURL("https://accounts.example.com/oauth/callback?code=\(code)&state=abc#token=\(code)")
        XCTAssertTrue(url.hasPrefix("https://accounts.example.com/oauth/callback?code=x7Q"), url)
        XCTAssertTrue(url.hasSuffix("…"))
        let query = url.dropFirst("https://accounts.example.com/oauth/callback".count)
        XCTAssertLessThanOrEqual(query.count, Handlers.queryClip + 1, "the query, with its ?")
        XCTAssertFalse(url.contains("state="), "what's past the clip isn't shown")
    }

    /// However long the path, the whole is at most `urlClip` characters.
    func testALongAddressIsClippedWhole() {
        let path = (1...40).map { "segment\($0)" }.joined(separator: "/")
        let url = Handlers.shortURL("https://example.com/\(path)?page=2")
        XCTAssertEqual(url.count, Handlers.urlClip)
        XCTAssertTrue(url.hasSuffix("…"))
        XCTAssertTrue(url.hasPrefix("https://example.com/segment1/"))
    }

    /// What isn't an address at all is clipped as it is.
    func testWhatIsntAnAddressIsClippedAsItIs() {
        let odd = String(repeating: "not a url ", count: 30)
        XCTAssertEqual(Handlers.shortURL(odd).count, Handlers.urlClip)
    }

    /// The address is looked up after what may go to another page, not after what stays on it.
    func testWhatMayGoToAnotherPage() {
        let goes: [[String: Any]] = [
            ["type": "click", "target": "Next"], ["type": "left_click", "x": 10, "y": 20], ["type": "double_click", "element": 4],
            ["type": "keypress", "keys": "Return"], ["type": "keypress", "keys": "cmd+["], ["type": "key", "key": "cmd+r"],
            ["type": "type", "text": "cats\n"], ["type": "type", "text": "cats", "submit": true],
            ["type": "fill", "fields": [], "submit": true], ["type": "fill", "fields": [], "submit": ["target": "Go"]],
            ["type": "navigate", "url": "example.com"], ["type": "open", "url": "https://example.com"],
            ["type": "menu", "item": "History > Back"], ["type": "select", "target": "Country", "option": "NZ"],
            ["type": "wait_for", "text": "Total"], ["type": "ax", "element": 3, "name": "press"],
        ]
        for a in goes { XCTAssertTrue(Handlers.mayNavigate(a), "\(a)") }
        let stays: [[String: Any]] = [
            ["type": "right_click", "target": "Link"], ["type": "keypress", "keys": "Tab"], ["type": "keypress", "keys": "shift+Down"],
            ["type": "type", "text": "cats"], ["type": "fill", "fields": [], "submit": false], ["type": "scroll", "scroll_y": 300],
            ["type": "move", "x": 1, "y": 2], ["type": "wait", "ms": 100], ["type": "clipboard"], ["type": "read"],
        ]
        for a in stays { XCTAssertFalse(Handlers.mayNavigate(a), "\(a)") }
    }

    // MARK: - the focus

    /// The focus is looked at after keys, typing, a click or a press, a menu command; not after a scroll,
    /// a wait or a read.
    func testWhatMayMoveTheFocus() {
        let moves: [[String: Any]] = [
            ["type": "keypress", "keys": "Tab"], ["type": "type", "text": "a"], ["type": "click", "target": "Name"],
            ["type": "right_click", "x": 1, "y": 1], ["type": "focus", "element": 2], ["type": "set_value", "element": 2, "value": "x"],
            ["type": "menu", "item": "Edit > Find…"], ["type": "fill", "fields": []], ["type": "paste", "text": "x"],
            ["type": "navigate", "url": "example.com"], ["type": "activate"], ["type": "key_down", "keys": "shift"],
        ]
        for a in moves { XCTAssertTrue(Handlers.movesFocus(a), "\(a)") }
        let stays: [[String: Any]] = [
            ["type": "scroll", "scroll_y": 300], ["type": "wait", "ms": 10], ["type": "wait_for", "text": "Done"],
            ["type": "move", "x": 1, "y": 1], ["type": "clipboard"], ["type": "read", "target": "Notes"], ["type": "screenshot"],
        ]
        for a in stays { XCTAssertFalse(Handlers.movesFocus(a), "\(a)") }
    }

    // MARK: - what's selected

    /// After a gesture that selects text, the reply says what's selected.
    func testWhatSelectsText() {
        let selecting: [[String: Any]] = [
            ["type": "double_click", "target": "word"], ["type": "triple_click", "x": 1, "y": 2],
            ["type": "click", "x": 1, "y": 2, "count": 2], ["type": "left_click", "x": 1, "y": 2, "clicks": 3],
            ["type": "click", "x": 1, "y": 2, "keys": "shift"], ["type": "left_click", "x": 1, "y": 2, "text": "shift"],
            ["type": "drag", "path": [[1, 2], [30, 2]]], ["type": "left_click_drag", "start_coordinate": [1, 2], "coordinate": [9, 9]],
            ["type": "keypress", "keys": "shift+Right"], ["type": "keypress", "keys": "shift+cmd+Left"],
            ["type": "keypress", "keys": ["shift", "Down"]], ["type": "keypress", "keys": "shift+End"],
            ["type": "keypress", "keys": "cmd+a"], ["type": "hotkey", "keys": "command+A"],
            ["type": "keypress", "keys": "Tab shift+Right shift+Right"],
            ["type": "menu", "item": "Edit > Select All"], ["type": "menu", "item": ["Edit", "Select All"]],
        ]
        for a in selecting { XCTAssertTrue(Handlers.selects(a), "\(a)") }
        let not: [[String: Any]] = [
            ["type": "click", "x": 1, "y": 2], ["type": "click", "x": 1, "y": 2, "keys": "cmd"], ["type": "keypress", "keys": "Right"],
            ["type": "keypress", "keys": "cmd+shift+a"], ["type": "keypress", "keys": "ctrl+a"], ["type": "keypress", "keys": "shift+Tab"],
            ["type": "menu", "item": "Edit > Copy"], ["type": "type", "text": "a"], ["type": "scroll", "scroll_y": 100],
        ]
        for a in not { XCTAssertFalse(Handlers.selects(a), "\(a)") }
    }

    /// The text in quotes, then its length; one line; short enough for a status line.
    func testHowASelectionIsSaid() {
        XCTAssertEqual(Handlers.selectedText("hello", count: 5), "\"hello\" (5 chars)")
        XCTAssertEqual(Handlers.selectedText("a", count: 1), "\"a\" (1 char)")
        XCTAssertEqual(Handlers.selectedText("two\nlines\there", count: 15), "\"two lines here\" (15 chars)")
        XCTAssertEqual(Handlers.selectedText("", count: 12), "(12 chars)", "the app gave where it is, not the text")
        XCTAssertEqual(Handlers.selectedText("   ", count: 3), "(3 chars)")
        let long = String(repeating: "All work and no play. ", count: 500)
        let said = Handlers.selectedText(long, count: long.count)
        XCTAssertLessThanOrEqual(said.count, 80, said)
        XCTAssertTrue(said.hasPrefix("\"All work and no play."))
        XCTAssertTrue(said.hasSuffix("…\" (\(long.count) chars)"), said)
    }

    // MARK: - where a scroll left the scroll bar

    /// The ends by name, else how far along (1-99%), down or across.
    func testWhereTheScrollBarIs() {
        XCTAssertEqual(ScrollWatch.place(0, vertical: true), "top")
        XCTAssertEqual(ScrollWatch.place(1, vertical: true), "bottom")
        XCTAssertEqual(ScrollWatch.place(0.9995, vertical: true), "bottom")
        XCTAssertEqual(ScrollWatch.place(0.45, vertical: true), "45% down")
        XCTAssertEqual(ScrollWatch.place(0.45, vertical: false), "45% across")
        XCTAssertEqual(ScrollWatch.place(0, vertical: false), "left end")
        XCTAssertEqual(ScrollWatch.place(1, vertical: false), "right end")
        XCTAssertEqual(ScrollWatch.place(0.004, vertical: true), "1% down", "not at the top, so not 0%")
        XCTAssertEqual(ScrollWatch.place(0.996, vertical: true), "99% down", "not at the bottom, so not 100%")
    }

    /// The note for a scroll that ran into the end says which end.
    func testWhichEndAScrollRanInto() {
        XCTAssertEqual(ScrollWatch.end(vertical: true, forward: true), "the bottom")
        XCTAssertEqual(ScrollWatch.end(vertical: true, forward: false), "the top")
        XCTAssertEqual(ScrollWatch.end(vertical: false, forward: true), "the right end")
        XCTAssertEqual(ScrollWatch.end(vertical: false, forward: false), "the left end")
    }
}
