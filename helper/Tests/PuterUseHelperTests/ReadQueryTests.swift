import XCTest

@testable import PuterUseHelper

/// Reading the end of a long text (a negative offset) and searching it (`query`) instead of paging through
/// it all: where each part or match is, in characters counted from the start, as pages count them.
final class ReadQueryTests: XCTestCase {
    let invoice = "Subtotal: $40\nTotal: $44.20\nPaid"  // 32 characters; "total" at 3 (in Subtotal) and 14

    /// -2000 is the last 2,000 characters, and the part says where that is in the whole; reading on from each
    /// part's end comes to the end with nothing missed. Further back than the start is from the start.
    func testATailReadSaysWhereItIsInTheWhole() {
        let s = (1...1000).map { String(format: "%04d line of the log, é👍🏽 ok", $0) }.joined(separator: "\n")
        let total = s.count
        let tail = Handlers.textPart(s, offset: -2000, limit: 10_000)
        XCTAssertEqual(tail.text, String(s.suffix(2000)))
        XCTAssertEqual([tail.start, tail.end, tail.total], [total - 2000, total, total])

        var offset = -20_000, parts: [String] = [], starts: [Int] = []
        while true {
            let p = Handlers.textPart(s, offset: offset, limit: 6_000)
            parts.append(p.text)
            starts.append(p.start)
            if p.end >= p.total { break }
            offset = p.end
        }
        XCTAssertEqual(parts.joined(), String(s.suffix(20_000)))
        XCTAssertEqual(starts, [total - 20_000, total - 14_000, total - 8_000, total - 2_000])

        XCTAssertTrue(Handlers.textPart("hello", offset: -50, limit: 10) == ("hello", 0, 5, 5))
        XCTAssertTrue(Handlers.textPart("é👍🏽ab", offset: -3, limit: 2) == ("👍🏽a", 1, 3, 4), "characters, not bytes")
        XCTAssertEqual(Handlers.startOffset(-5, total: 3), 0)
        XCTAssertEqual(Handlers.startOffset(7, total: 3), 7, "0 and above as given, past the end too")
    }

    /// The reply's read_range gives a tail read's real start, so the agent can read on from its end.
    func testATailReadsReplyGivesItsRealRange() {
        let s = String(repeating: "0123456789", count: 3_000)
        let tail = Handlers.readReply(s, "[4] textarea", ["offset": -2000])
        XCTAssertEqual(tail["read"] as? String, String(s.suffix(2000)))
        XCTAssertEqual(tail["read_range"] as? [Int], [28_000, 30_000, 30_000])
        XCTAssertEqual(tail["read_of"] as? String, "[4] textarea")
        XCTAssertNil(tail["read_query"])
        let back = Handlers.readReply(s, "[4] textarea", ["offset": -25_000, "limit": 1_000])
        XCTAssertEqual(back["read_range"] as? [Int], [5_000, 6_000, 30_000])
    }

    /// With neither offset below 0 nor a query, a read is as it was: from 0, 10,000 at a time, on from the end.
    func testWithNeitherAReadIsUnchanged() {
        let s = String(repeating: "0123456789", count: 3_000)
        XCTAssertEqual(Handlers.readReply(s, "x", [:])["read_range"] as? [Int], [0, 10_000, 30_000])
        XCTAssertEqual(Handlers.readReply(s, "x", ["offset": 10_000])["read_range"] as? [Int], [10_000, 20_000, 30_000])
        XCTAssertEqual(Handlers.readReply(s, "x", ["offset": 40_000])["read_range"] as? [Int], [40_000, 40_000, 30_000])
        let empty = Handlers.readReply(s, "x", ["query": ""])
        XCTAssertNil(empty["read_query"], "an empty query is no query")
        XCTAssertEqual(empty["read_range"] as? [Int], [0, 10_000, 30_000])
        for (offset, limit) in [(0, 10_000), (9_990, 50), (29_999, 10)] {
            let p = Handlers.page(s, offset: offset, limit: limit), q = Handlers.textPart(s, offset: offset, limit: limit)
            XCTAssertTrue(p == (q.text, q.end, q.total))
            XCTAssertEqual(q.start, offset)
        }
    }

    /// Each match is a line at its offset, case-insensitively, with the text around it on one line; a read
    /// from that offset starts at the match.
    func testAQueryListsEachMatchAtItsOffset() {
        let found = Handlers.textMatches(invoice, query: "TOTAL", from: 0, limit: 10_000)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.text, "@3: Subtotal: $40⏎Total: $44.20⏎Paid\n@14: Subtotal: $40⏎Total: $44.20⏎Paid")
        XCTAssertEqual(Handlers.textPart(invoice, offset: 14, limit: 5).text, "Total")

        let reply = Handlers.readReply(invoice, "[4] textarea \"Invoice\"", ["query": "total"])
        XCTAssertEqual(reply["read"] as? String, found.text)
        XCTAssertEqual(reply["read_query"] as? String, "total")
        XCTAssertEqual(reply["read_matches"] as? Int, 2)
        XCTAssertEqual(reply["read_range"] as? [Int], [0, 32, 32], "the part searched: all of it")

        let tail = Handlers.readReply(invoice, "x", ["query": "total", "offset": -20])
        XCTAssertEqual(tail["read"] as? String, "@14: Subtotal: $40⏎Total: $44.20⏎Paid", "only from offset 12 on")
        XCTAssertEqual(tail["read_matches"] as? Int, 1)
        XCTAssertEqual(tail["read_range"] as? [Int], [12, 32, 32])
    }

    /// About 150 characters of context: 75 each side, with … where it's cut off.
    func testTheTextAroundAMatchIsCut() {
        let s = String(repeating: "a", count: 200) + "Needle" + String(repeating: "b", count: 200)
        let found = Handlers.textMatches(s, query: "needle", from: 0, limit: 10_000)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.text, "@200: …" + String(repeating: "a", count: 75) + "Needle" + String(repeating: "b", count: 75) + "…")
    }

    /// Ten are listed, then how many more and where to search on from (the end of the last one listed); the
    /// search from there lists the next.
    func testAQueryListsTenThenSaysHowManyMore() {
        let s = String(repeating: "x key ", count: 25)  // "key" at 2, 8, 14, … 146
        let found = Handlers.textMatches(s, query: "KEY", from: 0, limit: 10_000)
        let lines = found.text.components(separatedBy: "\n")
        XCTAssertEqual(found.count, 25)
        XCTAssertEqual(lines.count, 11)
        XCTAssertTrue(lines[0].hasPrefix("@2: x key"))
        XCTAssertTrue(lines[9].hasPrefix("@56: x key"), "75 before it is before the start: nothing cut there")
        XCTAssertTrue(lines[9].hasSuffix("…"))
        XCTAssertEqual(lines[10], "+15 more (search on with offset 59)")
        let on = Handlers.textMatches(s, query: "key", from: 59, limit: 10_000)
        XCTAssertEqual(on.count, 15)
        XCTAssertTrue(on.text.hasPrefix("@62: "))
    }

    /// The listing keeps within limit: fewer lines, and how many more; a limit shorter than one line cuts it.
    func testAQueryKeepsWithinTheLimit() {
        let s = String(repeating: "x key ", count: 25)
        let found = Handlers.textMatches(s, query: "key", from: 0, limit: 300)
        let lines = found.text.components(separatedBy: "\n")
        XCTAssertEqual(found.count, 25)
        XCTAssertLessThanOrEqual(found.text.count, 300)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("@8: "))
        XCTAssertEqual(lines[2], "+23 more (search on with offset 11)")

        let tiny = Handlers.textMatches(s, query: "key", from: 0, limit: 20)
        XCTAssertEqual(tiny.text, "@2: x key x key x ke")
        XCTAssertEqual(tiny.count, 25)
    }

    /// Counting stops at 10,000, and says there may be more.
    func testCountingStops() {
        let found = Handlers.textMatches(String(repeating: "a", count: 10_050), query: "a", from: 0, limit: 10_000)
        XCTAssertEqual(found.count, Handlers.queryCount)
        XCTAssertEqual(found.text.components(separatedBy: "\n").last, "+9990 or more (search on with offset 10)")
    }

    /// No match is one line saying so, and how much was searched.
    func testNoMatchIsOneLine() {
        XCTAssertTrue(Handlers.textMatches(invoice, query: "zebra", from: 0, limit: 10_000) == ("no match for \"zebra\" in 32 characters", 0))
        XCTAssertTrue(Handlers.textMatches(invoice, query: "total", from: 20, limit: 10_000)
            == ("no match for \"total\" from offset 20 of 32 characters", 0))
        XCTAssertTrue(Handlers.textMatches(invoice, query: "total", from: 40, limit: 10_000)
            == ("no match for \"total\" from offset 40 of 32 characters", 0), "past the end")
        let reply = Handlers.readReply(invoice, "x", ["query": "zebra"])
        XCTAssertEqual(reply["read"] as? String, "no match for \"zebra\" in 32 characters")
        XCTAssertEqual(reply["read_matches"] as? Int, 0)
    }

    /// Offsets count characters (an accent, an emoji with its skin tone: one each), as pages do, not UTF-16;
    /// case and composed or decomposed accents don't matter; part of a character is no match.
    func testAQueryCountsCharacters() {
        let s = "\u{E9}👍🏽 caf\u{E9}, \u{C9}COLE\nTotal 👍🏽 total"  // é0 👍🏽1 … É9 … T15 … t23
        let school = Handlers.textMatches(s, query: "\u{E9}cole", from: 0, limit: 10_000)
        XCTAssertEqual(school.count, 1)
        XCTAssertTrue(school.text.hasPrefix("@9: "))
        XCTAssertEqual(Handlers.textPart(s, offset: 9, limit: 5).text, "\u{C9}COLE")

        let totals = Handlers.textMatches(s, query: "total", from: 0, limit: 10_000)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.text, "@15: \u{E9}👍🏽 caf\u{E9}, \u{C9}COLE⏎Total 👍🏽 total\n@23: \u{E9}👍🏽 caf\u{E9}, \u{C9}COLE⏎Total 👍🏽 total")
        XCTAssertEqual(Handlers.textPart(s, offset: 23, limit: 5).text, "total")

        let decomposed = "Cafe\u{301} and tea"  // C0 a1 f2 é3 (e and its accent) …, e10
        let cafe = Handlers.textMatches(decomposed, query: "caf\u{E9}", from: 0, limit: 10_000)
        XCTAssertEqual(cafe.count, 1)
        XCTAssertTrue(cafe.text.hasPrefix("@0: "))
        let e = Handlers.textMatches(decomposed, query: "e", from: 0, limit: 10_000)
        XCTAssertEqual(e.count, 1, "the e under the accent is part of é")
        XCTAssertTrue(e.text.hasPrefix("@10: "))
    }

    /// A region's text comes whole: a read of one can't search it (an empty query is no query).
    func testARegionReadTakesNoQuery() throws {
        XCTAssertThrowsError(try Handlers.readSource(["type": "read", "region": [0, 0, 10, 10], "query": "Total"])) { e in
            XCTAssertTrue("\(e)".contains("search"))
        }
        guard case .region = try Handlers.readSource(["type": "read", "region": [0, 0, 10, 10], "query": ""]) else {
            return XCTFail("an empty query is no query")
        }
        guard case .element(3) = try Handlers.readSource(["type": "read", "element": 3, "query": "Total", "offset": -2000]) else {
            return XCTFail("an element's text is searched")
        }
    }
}
