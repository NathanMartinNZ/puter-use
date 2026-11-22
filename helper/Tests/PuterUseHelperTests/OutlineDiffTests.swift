import XCTest

@testable import PuterUseHelper

/// What changed in an outline since the agent's: elements gone as ranges, lines with no number by what they say (a
/// banner that comes or goes shows, text that only moved doesn't), the whole outline when the changes come to most
/// of it, and an outline cut at its caps compared only as far as it goes, keeping its note.
final class OutlineDiffTests: XCTestCase {
    typealias Line = OutlineDiff.Line
    typealias Outline = OutlineDiff.Outline

    /// An element's line, `#id body`.
    func el(_ id: Int, _ body: String, inline: Bool = false, interactive: Bool = true) -> Line {
        Line(.id(id), "#\(id) " + body, inline: inline, interactive: interactive)
    }

    /// A line with no number; `n`: the how-manieth with these words.
    func text(_ s: String, _ n: Int = 1) -> Line { Line(.text(n == 1 ? s : "\(s) (\(n))"), s) }

    func buttons(_ ids: ClosedRange<Int>) -> [Line] { ids.map { el($0, "button \"Button number \($0)\"") } }
    func links(_ ids: ClosedRange<Int>) -> [Line] { ids.map { el($0, "link \"Story number \($0), with a title long enough to matter\"") } }
    var rest: [Line] { buttons(10...30) }

    /// The whole outline as it would be sent: its lines but for the elements in a line of text, then the note.
    func whole(_ o: Outline) -> String {
        (o.lines.filter { !$0.inline }.map(\.text) + (o.truncated ? [AX.truncatedNote] : [])).joined(separator: "\n")
    }

    func changes(_ old: Outline, _ new: Outline) -> OutlineDiff.Changes? { OutlineDiff.changes(old, new, full: whole(new)) }
    func lines(_ old: Outline, _ new: Outline) -> [String] { changes(old, new)?.text.components(separatedBy: "\n") ?? [] }

    func header(_ same: Int) -> String {
        "outline changes since your last outline (+ new, ~ changed, - gone; \(same) elements unchanged):"
    }

    // MARK: - what's gone

    /// Elements gone are their numbers, as ranges, on one line; a new one is its line.
    func testGoneElementsAreRanges() {
        XCTAssertEqual(OutlineDiff.ranges([12, 13, 14, 19, 23, 24]), "#12–#14, #19, #23, #24")
        XCTAssertEqual(OutlineDiff.ranges([5, 3, 4, 4]), "#3–#5", "in order, each once")
        XCTAssertEqual(OutlineDiff.ranges([]), "")

        let old = Outline(buttons(1...30), interactive: false)
        let new = Outline(buttons(1...10) + buttons(20...22) + buttons(24...30) + [el(31, "button \"New\"")], interactive: false)
        XCTAssertEqual(lines(old, new), [header(20), "+ #31 button \"New\"", "- #11–#19, #23"])
    }

    /// A few gone say what they were (a toast closed); many lines with no number gone are a count.
    func testAFewGoneKeepTheirLines() {
        let old = Outline([el(1, "button \"Save\""), el(2, "button \"Dismiss\""), text("Your file was saved"),
                           el(3, "link \"Help\"")] + rest, interactive: false)
        let new = Outline([el(1, "button \"Save\""), el(3, "link \"Help\"")] + rest, interactive: false)
        XCTAssertEqual(lines(old, new), [header(23), "- #2 button \"Dismiss\"", "- Your file was saved"])

        let paragraphs = ["Paragraph one", "Paragraph two", "Paragraph three", "Paragraph four", "Paragraph five"]
        let read = Outline(rest + paragraphs.map { text($0) }, interactive: false)
        XCTAssertEqual(lines(read, Outline(rest, interactive: false)),
                       [header(21), "- 5 lines with no number, \"Paragraph one\" to \"Paragraph five\""])
    }

    // MARK: - lines with no number

    /// A banner with no number shows when it comes, and when it goes.
    func testABannerShowsWhenItComesAndGoes() {
        let form = Outline([el(1, "field \"Password\""), el(2, "button \"Sign in\"")] + rest, interactive: false)
        let banner = Outline([el(1, "field \"Password\""), text("Invalid password"), el(2, "button \"Sign in\"")] + rest,
                             interactive: false)
        XCTAssertEqual(lines(form, banner), [header(23), "+ Invalid password"])
        XCTAssertEqual(lines(banner, form), [header(23), "- Invalid password"])
    }

    /// Text that only moved isn't news, a line repeated included; the same line once more is.
    func testTextThatMovedIsntNews() {
        let old = Outline([text("Total"), el(1, "button \"Pay\""), text("Total", 2), text("Shipping")] + rest, interactive: false)
        let moved = Outline([text("Shipping"), text("Total"), el(1, "button \"Pay\""), text("Total", 2)] + rest, interactive: false)
        let c = changes(old, moved)
        XCTAssertEqual(c?.unchanged, true)
        XCTAssertEqual(c?.text, "outline: nothing changed since your last outline (22 elements)")
        XCTAssertTrue(OutlineDiff.unchanged(old, moved))

        let again = Outline(moved.lines + [text("Total", 3)], interactive: false)
        XCTAssertEqual(lines(old, again), [header(22), "+ Total"])
    }

    /// A new line of text says the elements in it: their own lines aren't said again. An element in a line of text
    /// that's the same, whose own line changed, is.
    func testANewLineOfTextShowsItsElements() {
        let old = Outline([el(1, "button \"Save\"")] + rest, interactive: false)
        let new = Outline([el(1, "button \"Save\""), text("Read the [guide](#40) first."),
                           el(40, "link \"guide\"", inline: true)] + rest, interactive: false)
        XCTAssertEqual(lines(old, new), [header(22), "+ Read the [guide](#40) first."])

        let see = Outline([text("See [docs](#7)"), el(7, "link \"docs\"", inline: true)] + rest, interactive: false)
        let moved = Outline([text("See [docs](#7)"), el(7, "link \"docs\" =\"https://example.com/b\"", inline: true)] + rest,
                            interactive: false)
        XCTAssertEqual(lines(see, moved), [header(21), "~ #7 link \"docs\" =\"https://example.com/b\""])
    }

    /// Unchanged: the same elements with the same lines and the same lines with no number, in any order.
    func testUnchangedCountsText() {
        let old = Outline([el(1, "button \"Pay\""), text("Total: $3")] + rest, interactive: false)
        let new = Outline([el(1, "button \"Pay\""), text("Total: $4")] + rest, interactive: false)
        XCTAssertFalse(OutlineDiff.unchanged(old, new), "a text changed")
        XCTAssertEqual(lines(old, new), [header(22), "+ Total: $4", "- Total: $3"])
        XCTAssertTrue(OutlineDiff.unchanged(old, Outline(rest + [text("Total: $3"), el(1, "button \"Pay\"")], interactive: false)))

        let keys = Outline([el(1, "button \"7\""), el(2, "button \"8\""), el(3, "button \"+\"")], interactive: true)
        func with(_ l: [Line]) -> Outline { Outline(l, interactive: true) }
        XCTAssertTrue(OutlineDiff.unchanged(keys, with(keys.lines.reversed())))
        XCTAssertFalse(OutlineDiff.unchanged(keys, with([el(1, "button \"7\""), el(2, "button \"8\""), el(3, "button \"-\"")])))
        XCTAssertFalse(OutlineDiff.unchanged(keys, with(Array(keys.lines.prefix(2)))))
        XCTAssertFalse(OutlineDiff.unchanged(keys, with(keys.lines + [el(4, "button \"=\"")])))
        XCTAssertFalse(OutlineDiff.unchanged(keys, with([el(1, "button \"7\""), el(2, "button \"8\""), el(5, "button \"+\"")])),
                       "the same line under another number is another element")
    }

    // MARK: - the whole outline instead

    /// The changes go when they come to no more than `share` of the whole outline: a half-page scroll still does
    /// (its gone elements are one range), a page that changed whole doesn't. Nothing changed always goes.
    func testTheWholeOutlineWhenTheChangesAreMostOfIt() {
        let scrolled = lines(Outline(links(1...100), interactive: false), Outline(links(51...150), interactive: false))
        XCTAssertEqual(scrolled.count, 52)
        XCTAssertEqual(scrolled.first, header(50))
        XCTAssertEqual(scrolled.last, "- #1–#50")
        XCTAssertNil(changes(Outline(links(1...100), interactive: false), Outline(links(201...300), interactive: false)))

        let old = Outline(buttons(1...30), interactive: false), new = Outline(buttons(1...25), interactive: false)
        let size = OutlineDiff.changes(old, new, full: String(repeating: "x", count: 100_000))!.text.count
        let enough = Int((Double(size) / OutlineDiff.share).rounded(.up))
        XCTAssertNotNil(OutlineDiff.changes(old, new, full: String(repeating: "x", count: enough + 1)))
        XCTAssertNil(OutlineDiff.changes(old, new, full: String(repeating: "x", count: enough - 2)))
        XCTAssertNotNil(OutlineDiff.changes(old, old, full: ""), "nothing changed")
    }

    // MARK: - an outline cut at its caps

    /// Cut at its caps, the new outline keeps its note, and what the agent had past where it stops isn't gone: the
    /// agent keeps it. What's gone above the cut still shows.
    func testACutOutlineKeepsItsNoteAndCallsNothingPastTheCutGone() {
        let old = Outline(buttons(1...20) + [text("© 2026 Example")], interactive: false)
        let longer = el(1, "button \"Button number 1, now longer\"")
        let cut = Outline([longer] + buttons(2...15), interactive: false, truncated: true)
        let c = changes(old, cut)
        XCTAssertEqual(c?.text.components(separatedBy: "\n"), [header(14), "~ " + longer.text, AX.truncatedNote])
        XCTAssertEqual(c?.baseline.lines.compactMap(\.id), Array(1...20), "what's past the cut stays the agent's")
        XCTAssertEqual(c?.baseline.lines.last?.text, "© 2026 Example")

        let fiveGone = Outline(buttons(1...4) + buttons(6...15), interactive: false, truncated: true)
        XCTAssertEqual(lines(old, fiveGone), [header(14), "- #5 button \"Button number 5\"", AX.truncatedNote])
    }

    /// The cut moving up (a field above it grew) calls nothing gone; moving back, what comes back isn't news; moving
    /// further down, what the agent never had is new.
    func testTheCutMoving() {
        let longer = el(1, "button \"Button number 1, now longer\"")
        let up = changes(Outline(buttons(1...15), interactive: false, truncated: true),
                         Outline([longer] + buttons(2...12), interactive: false, truncated: true))
        XCTAssertEqual(up?.text.components(separatedBy: "\n"), [header(11), "~ " + longer.text, AX.truncatedNote])
        guard let had = up?.baseline else { return XCTFail("no changes") }
        XCTAssertEqual(had.lines.compactMap(\.id), Array(1...15))

        let back = changes(had, Outline([longer] + buttons(2...15), interactive: false, truncated: true))
        XCTAssertEqual(back?.unchanged, true)
        XCTAssertEqual(back?.text, "outline: nothing changed since your last outline (15 elements)\n" + AX.truncatedNote)
        guard let now = back?.baseline else { return XCTFail("no changes") }

        let down = Outline([longer] + buttons(2...18), interactive: false, truncated: true)
        XCTAssertEqual(lines(now, down), [header(15)] + buttons(16...18).map { "+ " + $0.text } + [AX.truncatedNote])
    }

    // MARK: - the two kinds

    /// An interactive outline the agent had isn't compared with a full one (most of it would be new). A full one is
    /// with an interactive one, on what that shows: its elements that can be acted on, and the lines with no number
    /// that weren't there. A text or an image it leaves out isn't gone.
    func testTheTwoKinds() {
        let keys = [el(1, "button \"Save\"")] + rest
        XCTAssertNil(OutlineDiff.changes(Outline(keys, interactive: true), Outline(keys, interactive: false), full: whole(Outline(keys, interactive: false))))
        XCTAssertFalse(OutlineDiff.unchanged(Outline(keys, interactive: true), Outline(keys, interactive: false)))

        let full = Outline([el(1, "button \"Save\""), el(2, "image \"Logo\"", interactive: false), text("Welcome back"),
                            el(3, "link \"Docs\"")] + rest, interactive: false)
        let across = "outline changes since your last full outline, in what this interactive one shows "
            + "(+ new, ~ changed, - gone; 22 elements unchanged):"
        let interactive = Outline([text("heading \"Account\""), el(1, "button \"Save\""), el(3, "link \"Docs (new)\"")] + rest,
                                  interactive: true)
        let c = changes(full, interactive)
        XCTAssertEqual(c?.text.components(separatedBy: "\n"), [across, "+ heading \"Account\"", "~ #3 link \"Docs (new)\""])
        XCTAssertEqual(c?.baseline.interactive, true)
        XCTAssertEqual(lines(full, Outline(keys, interactive: true)), [across, "- #3 link \"Docs\""])
    }

    // MARK: - from an outline

    /// An outline's lines in the order written, each with its key: a line of text, then the elements in it.
    func testAnOutlinesLinesAndKeys() {
        let f = OutlineTreeFakes()
        let at = { (x: CGFloat, w: CGFloat) in CGRect(x: x, y: 200, width: w, height: 16) }
        let row = f.el("AXGroup", kids: [
            f.el("AXStaticText", value: "380 points by ", frame: at(10, 90)),
            f.el("AXLink", "alice", frame: at(100, 30)),
            f.el("AXStaticText", value: " | ", frame: at(130, 10)),
            f.el("AXLink", "hide", frame: at(140, 30)),
        ])
        let reg = AX.Registry()
        let written = f.outline(f.window([row]), reg)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(reg.keyed.map(\.key), [.text(written[0]), .id(1), .id(2)])
        XCTAssertEqual(reg.keyed.map(\.inline), [false, true, true])
        XCTAssertEqual(reg.keyed.dropFirst().map(\.interactive), [true, true], "links show in an interactive outline")
        XCTAssertEqual(reg.keyed.dropFirst().map(\.text), ["#1 link \"alice\"", "#2 link \"hide\""])
        XCTAssertFalse(reg.truncated)
    }

    /// An outline past its caps is marked so; one that isn't, not.
    func testACutOutlineIsMarked() {
        let f = OutlineTreeFakes()
        let many = (1...20).map { f.el("AXButton", "B\($0)") }
        let reg = AX.Registry()
        _ = f.outline(f.window(many), reg, maxElements: 5)
        XCTAssertTrue(reg.truncated)
        XCTAssertTrue(OutlineDiff.Outline(reg, interactive: false).truncated)
        XCTAssertEqual(reg.keyed.compactMap(\.id), [1, 2, 3, 4, 5])
        _ = f.outline(f.window(many), reg)
        XCTAssertFalse(reg.truncated)
    }

    /// Cut at its caps, as the registry says, the outline can't stand in for a picture; not cut, it can, whatever its
    /// last line says. Not said, its last lines tell.
    func testACutOutlineIsAProblemAsTheRegistrySays() {
        let outline = "#1 button \"Save\"\n#2 field \"Name\" =\"Ann\""
        XCTAssertNotNil(Handlers.outlineProblem(outline, interactive: false, cutShort: false, truncated: true))
        XCTAssertNil(Handlers.outlineProblem(outline + "\n" + AX.truncatedNote, interactive: false, cutShort: false, truncated: false))
        XCTAssertNotNil(Handlers.outlineProblem(outline + "\n" + AX.truncatedNote, interactive: false, cutShort: false))
        XCTAssertNotNil(Handlers.outlineProblem("", interactive: false, cutShort: false, truncated: false), "empty")
    }

    // MARK: - element numbers

    /// An element's number as an outline writes it (`#12`) is that number; a `#` with anything but digits after it
    /// isn't a number, nor is text.
    func testAnElementNumberAsWritten() {
        XCTAssertEqual(Handlers.num("#12"), 12)
        XCTAssertEqual(Handlers.num(" #12 "), 12)
        XCTAssertEqual(Handlers.num("12"), 12)
        XCTAssertEqual(Handlers.num(12), 12)
        XCTAssertEqual(Handlers.num(NSNumber(value: 3.5)), 3.5)
        XCTAssertNil(Handlers.num("#"))
        XCTAssertNil(Handlers.num("#12a"))
        XCTAssertNil(Handlers.num("#-3"))
        XCTAssertNil(Handlers.num("#1.5"))
        XCTAssertNil(Handlers.num("# 12"))
        XCTAssertNil(Handlers.num("##12"))
        XCTAssertNil(Handlers.num("Issue #12"))
        XCTAssertNil(Handlers.num(nil))
        XCTAssertEqual(Handlers.int("#7", 0), 7)
    }

    /// A status text that comes up (it has no number) is in the changes.
    func testAStatusTextShowsInTheChanges() {
        let f = OutlineTreeFakes()
        let save = f.el("AXButton", "Save"), help = f.el("AXLink", "Help")
        let tools = (1...20).map { f.el("AXButton", "Tool \($0)") }
        let reg = AX.Registry()
        _ = f.outline(f.window([save, help] + tools), reg)
        let old = OutlineDiff.Outline(reg, interactive: false)
        let status = f.el("AXStaticText", value: "status: ready")
        let written = f.outline(f.window([save, status, help] + tools), reg)
        let new = OutlineDiff.Outline(reg, interactive: false)
        XCTAssertEqual(new.lines.map(\.text), written)
        let c = OutlineDiff.changes(old, new, full: written.joined(separator: "\n"))
        XCTAssertEqual(c?.text.components(separatedBy: "\n"), [header(22), "+ status: ready"])
    }
}
