import XCTest

@testable import PuterUseHelper

/// What `find` says, apart from the accessibility search: the texts it looks for (`query` and `queries`), how
/// many matches each lists, how a find by role alone says it was cut short, and the text of one query (as it
/// always was) and of several (a part for each).
final class FindQueriesTests: XCTestCase {
    /// `query`, then `queries` (a list, or one text), without blank ones or repeats; anything not text is left out.
    func testTheTextsAFindLooksFor() {
        XCTAssertEqual(Handlers.findQueries(["query": "Save"]), ["Save"])
        XCTAssertEqual(Handlers.findQueries(["queries": ["Email", "Password", "Sign in"]]), ["Email", "Password", "Sign in"])
        XCTAssertEqual(Handlers.findQueries(["query": "Email", "queries": ["Password", "Email", "", "  ", "Sign in"]]),
                       ["Email", "Password", "Sign in"])
        XCTAssertEqual(Handlers.findQueries(["queries": "Email"]), ["Email"])
        XCTAssertEqual(Handlers.findQueries(["query": "", "role": "field"]), [], "a role alone")
        XCTAssertEqual(Handlers.findQueries(["query": NSNull(), "queries": [1, "x", NSNull()]]), ["x"])
        XCTAssertEqual(Handlers.findQueries([:]), [])
    }

    /// One text lists `limit` (20 by default, 1-100); several share 40 between them, 5 each by default.
    func testHowManyMatchesEachTextLists() {
        XCTAssertEqual(Handlers.findCap(count: 1, limit: nil), 20)
        XCTAssertEqual(Handlers.findCap(count: 1, limit: 50), 50)
        XCTAssertEqual(Handlers.findCap(count: 1, limit: "7"), 7)
        XCTAssertEqual(Handlers.findCap(count: 1, limit: 500), 100)
        XCTAssertEqual(Handlers.findCap(count: 1, limit: 0), 1)
        XCTAssertEqual(Handlers.findCap(count: 2, limit: nil), 5)
        XCTAssertEqual(Handlers.findCap(count: 3, limit: nil), 5)
        XCTAssertEqual(Handlers.findCap(count: 10, limit: nil), 4, "an even share of 40")
        XCTAssertEqual(Handlers.findCap(count: 5, limit: 20), 8)
        XCTAssertEqual(Handlers.findCap(count: 2, limit: 1), 1)
        XCTAssertEqual(Handlers.findCap(count: Handlers.findMaxQueries, limit: 100), Handlers.findShared / Handlers.findMaxQueries)
    }

    /// A find by role alone says how many it lists of how many, and when it was cut short or stopped early.
    func testARoleAloneSaysWhenItsListIsCutShort() {
        XCTAssertTrue(Handlers.roleSummary("field", found: 7, listed: 7, complete: true) == ("role \"field\", all 7:", nil))
        XCTAssertTrue(Handlers.roleSummary("field", found: 7, listed: 7, complete: false)
            == ("role \"field\", 7 found (the search stopped early, so there may be more):", nil))
        XCTAssertTrue(Handlers.roleSummary("link", found: 37, listed: 20, complete: true)
            == ("role \"link\", the first 20 of 37 (add a query to narrow it):", "+17 more"))
        XCTAssertTrue(Handlers.roleSummary("link", found: 100, listed: 20, complete: false)
            == ("role \"link\", the first 20 of 100 or more (add a query to narrow it):", "+80 or more"))
    }

    /// One text: its lines as before (each still `[n] role "label" at (x,y)`), or that nothing shows it, with
    /// what's similar under it, and a note when the search off screen stopped early.
    func testOneTextReadsAsItAlwaysDid() {
        let hit = "[3] field \"Email\" at (120,340)", near = "[9] field \"E-mail\" at (120,380)"
        XCTAssertEqual(Handlers.findText("\"Email\"", lines: [hit], similar: [], complete: true), hit)
        XCTAssertEqual(Handlers.findText("\"Emial\"", lines: [], similar: [], complete: true), "(nothing shows \"Emial\")")
        XCTAssertEqual(Handlers.findText("\"Emial\"", lines: [], similar: [near], complete: true),
                       "(nothing shows \"Emial\") similar:\n" + near)
        XCTAssertEqual(Handlers.findText("button \"Go\"", lines: [hit], similar: [], complete: false),
                       hit + "\n(more may be off screen: the search there stopped early)")
    }

    /// Several texts: a header and the lines for each found; one line for each not found (with what's similar).
    func testEachOfSeveralTextsHasItsPart() {
        let hit = "[3] field \"Email\" at (120,340)", near = "[9] field \"E-mail\" at (120,380)"
        XCTAssertEqual(Handlers.findSection("\"Email\"", lines: [hit], similar: [], complete: true), ["\"Email\":", hit])
        XCTAssertEqual(Handlers.findSection("\"Remember me\"", lines: [], similar: [], complete: true), ["(nothing shows \"Remember me\")"])
        XCTAssertEqual(Handlers.findSection("\"Emial\"", lines: [], similar: [near, "[4] text \"Mail\""], complete: false),
                       ["(nothing shows \"Emial\"; similar: \(near); [4] text \"Mail\"; the search off screen stopped early)"])
        XCTAssertEqual(Handlers.findSection("button \"Go\"", lines: [hit], similar: [], complete: false),
                       ["button \"Go\":", hit, "(more may be off screen: the search there stopped early)"])
        for line in Handlers.findSection("\"Email\"", lines: [hit], similar: [], complete: false) where line != hit {
            XCTAssertFalse(line.hasPrefix("["), "only an element's line starts with its number: \(line)")
        }
    }
}
