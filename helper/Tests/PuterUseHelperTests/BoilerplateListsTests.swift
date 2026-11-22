import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// Lists in notes and errors stay short and still name what to use: menu, suggestion and option titles clipped,
/// capped with "+N more", the nearest to what was asked for first; a clipped title still picks its item; `find`
/// says once that text was read off the screen; `macros` caps its lines. Made-up titles (no app needed).
@MainActor
final class BoilerplateListsTests: XCTestCase {
    // MARK: - clipping and capping

    func testListedClipsEachAndCapsWithACount() {
        XCTAssertEqual(AX.listed(["Red", "Green", "Blue"], max: 25, separator: " · "), "Red · Green · Blue")
        XCTAssertEqual(AX.listed([], max: 8), "")
        XCTAssertEqual(AX.listed(["two\nlines"], max: 8), "two lines")
        // Over 45 characters: the first 44 and "…", with no space left before it.
        XCTAssertEqual(AX.listed([String(repeating: "a", count: 60)], max: 8), String(repeating: "a", count: 44) + "…")
        XCTAssertEqual(AX.listed([String(repeating: "a", count: 43) + " " + String(repeating: "b", count: 10)], max: 8),
                       String(repeating: "a", count: 43) + "…")
        XCTAssertEqual(AX.listed([String(repeating: "a", count: 45)], max: 8), String(repeating: "a", count: 45))
        // At most `max` of them...
        XCTAssertEqual(AX.listed((1...30).map { "item \($0)" }, max: 8, separator: " · "),
                       (1...8).map { "item \($0)" }.joined(separator: " · ") + " · +22 more")
        // ...in about `chars` characters, though never none.
        let forty = String(repeating: "x", count: 40)
        XCTAssertEqual(AX.listed(Array(repeating: forty, count: 10), max: 8, chars: 100, separator: " · "),
                       "\(forty) · \(forty) · +8 more")
        XCTAssertEqual(AX.listed([forty], max: 8, chars: 10), forty)
    }

    /// A quoted name that's clipped keeps its "…" outside the quotes: what's quoted is the start of the name,
    /// which picks it.
    func testQuotedClipQuotesTheStartWhichStillPicksIt() {
        XCTAssertEqual(AX.listed(["Small", "Medium"], max: 20, quote: true), "\"Small\", \"Medium\"")
        let uk = "United Kingdom of Great Britain and Northern Ireland"
        XCTAssertEqual(AX.listed([uk], max: 20, quote: true), "\"United Kingdom of Great Britain and Northern\"…")
        XCTAssertEqual(AX.menuMatches(["United Kingdom", uk], "United Kingdom of Great Britain and Northern"), [1])
    }

    // MARK: - nearest first

    func testNearestFirstRanksNearOnesThenTheLongestSharedStart() {
        let countries = ["Afghanistan", "Albania", "Germany", "Uganda", "Ukraine", "United Arab Emirates", "United Kingdom",
                         "United States", "Uruguay", "Zambia"]
        XCTAssertEqual(Array(AX.nearestFirst(countries, to: "United Stats").prefix(6)),
                       ["United States", "United Kingdom", "United Arab Emirates", "Uganda", "Ukraine", "Uruguay"])
        // Nothing near and nothing in common: as they were.
        XCTAssertEqual(AX.nearestFirst(["Red", "Green", "Blue"], to: "Purple"), ["Red", "Green", "Blue"])
        XCTAssertEqual(AX.nearestFirst(["b", "a"], to: "…"), ["b", "a"])
    }

    /// Up to 20 options as they are; more, the nearest first, then "+N more".
    func testOptionListRanksOnlyWhenItHasToCap() {
        XCTAssertEqual(AX.optionList(["Small", "Medium", "Large"], near: "Large size", quote: true),
                       "\"Small\", \"Medium\", \"Large\"")
        let many = (1...60).map { "Item \($0)" } + ["Daylight Saving Time"]
        XCTAssertEqual(AX.optionList(many, near: "daylight saving"),
                       "Daylight Saving Time, " + (1...19).map { "Item \($0)" }.joined(separator: ", ") + ", +41 more")
    }

    // MARK: - a clipped title picks its item

    func testMenuMatchesTakesAClippedTitleByItsStart() {
        let titles = ["Open Link in New Tab", "Open Link in New Private Window With Work Profile", "Copy Link"]
        let clipped = AX.listed([titles[1]], max: 1)
        XCTAssertEqual(clipped, "Open Link in New Private Window With Work Pr…")
        XCTAssertEqual(AX.menuMatches(titles, clipped), [1])
        XCTAssertEqual(AX.menuMatches(titles, "Open Link in New Private Window With Work Pr..."), [1])  // "..." is "…"
        XCTAssertEqual(AX.menuMatches(titles, "Open Link…"), [0, 1])  // still ambiguous
        XCTAssertEqual(AX.menuMatches(titles, "…"), [])
        // The same title first, as before; then the start, then any part.
        XCTAssertEqual(AX.menuMatches(["Save…", "Save As…"], "Save…"), [0])
        XCTAssertEqual(AX.menuMatches(["Save As…", "Close"], "Save…"), [0])
        XCTAssertEqual(AX.menuMatches(titles, "copy"), [2])
        XCTAssertEqual(AX.menuMatches(titles, "private"), [1])
    }

    /// A target naming a long title as the note clipped it is pointed at the whole title, to choose with `item`.
    func testMenuHintKnowsAClippedTitle() {
        let s = Session(id: "t-clipped-hint", ordinal: 8)
        let w = WinInfo(id: 79, pid: 1, app: "Probe", title: "", frame: .zero, layer: 0, onScreen: true)
        let long = "Open Link in New Private Window With Work Profile"
        Session.$current.withValue(s) {
            s.acts = 3
            s.lastClosedMenu = (["Open Link in New Tab", long, "Copy Link"], 79, 3)
            XCTAssertEqual(Handlers.menuHint(Handlers.Spec(text: AX.listed([long], max: 1)), .window(w)),
                           "nothing shows \"Open Link in New Private Window With Work Pr…\": \"\(long)\" was in a menu closed "
                           + "earlier in this call (an open menu takes the user's typing). Open it again and choose in the "
                           + "same click, with item: \"\(long)\"")
            XCTAssertNil(Handlers.menuHint(Handlers.Spec(text: "Open Link…"), .window(w)), "too short to be a clipped one")
        }
    }

    // MARK: - menus and suggestions closed at the end of a batch

    func testMenuNoteListsTheMenuAndHowToChooseOnce() {
        XCTAssertEqual(Handlers.menuNote(["Red", "Green", "Blue"], closed: true),
                       "a menu opened (Red · Green · Blue) and was closed again; to choose from it, make the same click with "
                       + "item: \"…\"")
        XCTAssertTrue(Handlers.menuNote(["Bold", "Font >"], closed: true).hasSuffix("item: \"…\" (\"Font > Bold\" for a submenu)"))
        XCTAssertEqual(Handlers.menuNote(["Red"], closed: false),
                       "a menu opened (Red) and couldn't be closed: it takes the keyboard until it is (Escape)")
        XCTAssertTrue(Handlers.menuNote((1...40).map { "Item \($0)" }, closed: true).contains("Item 25 · +15 more)"))
    }

    func testSuggestionsNoteCapsAtEightAndListsNothingWhenClosedBeforeReturn() {
        let titles = (1...20).map { "Result \($0): a long suggestion title that goes on and on" }
        let list = (1...8).map { "Result \($0): a long suggestion title that goes…" }.joined(separator: " · ") + " · +12 more"
        XCTAssertEqual(Handlers.suggestionsNote(titles, closed: true),
                       "a suggestions list opened as you typed (\(list)); it's closed again, so your keys stay in the field")
        XCTAssertEqual(Handlers.suggestionsNote(titles, closed: false),
                       "a suggestions list opened as you typed (\(list)); it's still open: Down or Return may pick from it")
        XCTAssertEqual(Handlers.suggestionsNote(titles, closed: true, before: "Return"),
                       "closed a suggestions list before Return, so it didn't take it")
        XCTAssertEqual(Handlers.suggestionsNote(titles, closed: false, before: "Return"),
                       "a suggestions list (\(list)) was open before Return and couldn't be closed: it may have taken it")
    }

    // MARK: - find, read off the screen

    func testFindSaysOnceThatTextWasReadOffTheScreen() {
        let hits = [OCR.Hit(line: "Sign in", rect: CGRect(x: 10, y: 20, width: 40, height: 10), exact: true),
                    OCR.Hit(line: "Sign in with Google", rect: CGRect(x: 100, y: 60, width: 40, height: 10), exact: false)]
        XCTAssertEqual(Handlers.screenLines(hits) { [Int($0.x), Int($0.y)] },
                       ["(read off the screen: click these by x,y)", "text \"Sign in\" at (30,25)",
                        "text \"Sign in with Google\" at (120,65)"])
        XCTAssertEqual(Handlers.screenLines(Array(hits.prefix(1))) { _ in nil },
                       ["(read off the screen: click these by x,y)", "text \"Sign in\""])
        XCTAssertEqual(Handlers.screenLines([]) { _ in nil }, [])
    }

    // MARK: - macros

    func testMacroLinesNameTheAppOnlyInEveryAppsListAndClipDescriptions() {
        let e = Macros.Entry(name: "export pdf", app: "Preview", steps: 3, vars: ["file"], about: "saves it as a PDF")
        XCTAssertEqual(e.line(), "export pdf (Preview, 3 steps, vars: file): saves it as a PDF")
        XCTAssertEqual(e.line(app: false), "export pdf (3 steps, vars: file): saves it as a PDF")
        XCTAssertEqual(Macros.Entry(name: "tidy", app: "Finder", steps: 1).line(), "tidy (Finder, 1 step)")
        let long = Macros.Entry(name: "x", app: "A", steps: 2, about: String(repeating: "d", count: 100))
        XCTAssertEqual(long.line(clip: 80), "x (A, 2 steps): " + String(repeating: "d", count: 79) + "…")
    }

    func testMacrosListingCapsAtThirtyThenNamesTheRest() {
        let entries = (1...35).map { Macros.Entry(name: "m\($0)", app: "App", steps: 2, about: String(repeating: "d", count: 100)) }
        let lines = Macros.listing(entries, oneApp: true).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 31)
        XCTAssertEqual(lines[0], "m1 (2 steps): " + String(repeating: "d", count: 79) + "…")
        XCTAssertEqual(lines[30], "+5 more by name: m31, m32, m33, m34, m35")
        XCTAssertTrue(Macros.listing(entries, oneApp: false).hasPrefix("m1 (App, 2 steps): "))
        XCTAssertEqual(Macros.listing(Array(entries.prefix(2)), oneApp: true).components(separatedBy: "\n").count, 2)
    }
}
