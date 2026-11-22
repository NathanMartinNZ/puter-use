import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The text in an area (a screenshot's region with no image): a text area gives just what it shows there,
/// the whole is capped with a note, the same text a point or two off is given once, and doubtful marks
/// read off the screen are left out. Made-up windows (no app needed); what a text area says it shows is
/// passed in.
final class RegionTextTests: XCTestCase {
    final class Fake {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let title: String?
        let value: String?
        let frame: CGRect
        let kids: [Fake]
        let fails: Bool  // asking for its children fails (no value), as a web view's host's does at first
        init(_ id: Int, _ role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, frame: CGRect,
             kids: [Fake] = [], fails: Bool = false) {
            element = AXUIElementCreateApplication(pid_t(910_000 + id))  // a distinct element; never asked anything
            (self.role, self.subrole, self.title, self.value, self.frame, self.kids, self.fails) =
                (role, subrole, title, value, frame, kids, fails)
        }
    }

    var clock: TimeInterval = 0
    var win: Fake!
    var all: [Fake] = []

    /// A 1000×3000 pt window holding `kids`.
    func window(_ kids: [Fake], title: String? = nil) -> Fake {
        win = Fake(0, "AXWindow", title: title, frame: CGRect(x: 0, y: 0, width: 1000, height: 3000), kids: kids)
        all = []
        func collect(_ f: Fake) { all.append(f); f.kids.forEach(collect) }
        collect(win)
        return win
    }

    func attrs(_ el: AXUIElement) -> [AnyObject]? {
        guard let f = all.first(where: { CFEqual($0.element, el) }) else { return nil }
        var pos = f.frame.origin, size = f.frame.size
        let none = NSNull()
        var noValue = AXError.noValue
        let kids: AnyObject = f.fails ? AXValueCreate(.axError, &noValue)! : f.kids.map(\.element) as NSArray
        return [f.role as NSString, (f.subrole as NSString?) ?? none, (f.title as NSString?) ?? none, none,
                (f.value as NSString?) ?? none, kids, AXValueCreate(.cgPoint, &pos)!,
                AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, none, none, none, none]
    }

    func text(_ area: CGRect, maxChars: Int = AX.textCap, cost: TimeInterval = 0,
              shown: (AXUIElement, CGRect, String) -> AX.Shown? = { _, _, _ in nil }) -> String {
        AX.text(of: win.element, within: area, maxChars: maxChars, now: { self.clock },
                read: { el in self.clock += cost; return self.attrs(el) }, shown: shown)
    }

    func areaText(_ area: CGRect, shown: (AXUIElement, CGRect, String) -> AX.Shown? = { _, _, _ in nil }) -> AX.AreaText {
        AX.areaText(of: win.element, within: area, now: { self.clock }, read: { el in self.attrs(el) }, shown: shown)
    }

    /// About 129,000 characters: "w1 w2 w3 …".
    let document = (1...20_000).map { "w\($0)" }.joined(separator: " ")

    // MARK: text areas

    /// A document's text area runs far past the area: only the characters it shows inside the area are given,
    /// though its centre (far down the document) isn't in the area.
    func testATextAreaGivesOnlyWhatItShowsInTheArea() {
        _ = window([Fake(1, "AXTextArea", value: document, frame: CGRect(x: 0, y: 0, width: 800, height: 3000))])
        let area = CGRect(x: 0, y: 100, width: 800, height: 200)
        var asked: [CGRect] = []
        let out = text(area) { _, box, whole in
            asked.append(box)
            XCTAssertEqual(whole, self.document)
            return .area("w12 w13\nw14  w15")
        }
        XCTAssertEqual(asked, [area])  // its part of the area
        XCTAssertEqual(out, "w12 w13\nw14 w15")  // its lines kept, spaces collapsed
    }

    /// Text that fits the area is given whole, as before (nothing asked of the app), line by line.
    func testAShortTextAreaIsGivenWholeLineByLine() {
        _ = window([Fake(1, "AXTextArea", value: "Dear Ada,\n\n\n\nThanks  for\r\nthe notes.\n",
                         frame: CGRect(x: 10, y: 10, width: 400, height: 200))])
        let out = text(CGRect(x: 0, y: 0, width: 500, height: 300)) { _, _, _ in
            XCTFail("a text area whose text fits isn't asked what it shows")
            return nil
        }
        XCTAssertEqual(out, "Dear Ada,\n\nThanks for\nthe notes.")  // one blank line at most
    }

    /// An app that doesn't say what's shown (as web engines answer, the whole text "in view"): the start of
    /// the text, as much as the area could show, cut at a word, with the note.
    func testATextAreaThatDoesntSayWhatsShownGivesItsStartWithTheNote() {
        _ = window([Fake(1, "AXTextArea", value: document, frame: CGRect(x: 0, y: 0, width: 400, height: 200))])
        let out = text(CGRect(x: 0, y: 0, width: 400, height: 200))  // room for 2000 characters
        XCTAssertEqual(AX.fits(CGSize(width: 400, height: 200)), 2000)
        XCTAssertTrue(out.hasPrefix("w1 w2 w3 "))
        XCTAssertTrue(out.hasSuffix("…\n" + AX.textCapNote))
        let body = out.dropLast(AX.textCapNote.count + 2)  // "…" and the line break
        XCTAssertLessThanOrEqual(body.count, 2000)
        XCTAssertTrue(document.hasPrefix(body + " "))  // whole words
    }

    /// Without the characters at the area's corners or where its lines are, a text area whose shown part is mostly
    /// outside the area gives none of what it shows (so the lines beside the area don't bleed in), whether the app
    /// tells what's in view or nothing; but that's never silent: the part is listed as missed, and the text says so.
    func testWithoutTheCornersOrLinesAPartlyCoveredTextAreaIsMissedNotSilent() {
        _ = window([Fake(1, "AXTextArea", value: document, frame: CGRect(x: 0, y: 0, width: 800, height: 3000))])
        let top = CGRect(x: 0, y: 0, width: 800, height: 300)
        XCTAssertEqual(text(top) { _, _, _ in .visible("w1 w2") }, "(no text in that area)\n" + AX.missedNote)
        XCTAssertEqual(text(top) { _, _, _ in nil }, "(no text in that area)\n" + AX.missedNote)
        XCTAssertEqual(areaText(top) { _, _, _ in nil }, AX.AreaText(text: "(no text in that area)", missed: [top]))
        let middle = CGRect(x: 0, y: 1400, width: 800, height: 300)
        XCTAssertEqual(text(middle) { _, _, _ in .visible("w9000 w9001") }, "w9000 w9001")
        // A sliver of its edge (under a line's height) isn't counted as missed.
        XCTAssertEqual(areaText(CGRect(x: 0, y: 2995, width: 800, height: 40)) { _, _, _ in nil }.missed, [])
    }

    /// The probe's Notes: a text view in a scroll area, its frame all of its 300 lines (its middle far above
    /// the window), scrolled to the bottom. A region over the status label and the top of what Notes shows gives
    /// the label, then the lines shown in the region, from where the app says each line is.
    func testATextViewInAScrollAreaGivesTheLinesShownInTheRegion() {
        let notes = Fake(3, "AXTextArea", value: document, frame: CGRect(x: 16, y: 146 - 3000, width: 670, height: 4200))
        _ = window([
            Fake(1, "AXStaticText", value: "status: Save pressed", frame: CGRect(x: 16, y: 118, width: 400, height: 20)),
            Fake(2, "AXScrollArea", frame: CGRect(x: 16, y: 146, width: 688, height: 150), kids: [notes]),
        ])
        let shownLines = (0..<10).map { k in
            AX.ShownLine(text: "Line \(291 + k): the quick brown fox\n", rect: CGRect(x: 21, y: 146 + CGFloat(k) * 14, width: 300, height: 14))
        }
        let region = CGRect(x: 10, y: 115, width: 700, height: 75)
        var asked: [CGRect] = []
        let out = text(region) { el, box, _ in
            XCTAssertTrue(CFEqual(el, notes.element))
            asked.append(box)
            return .lines(shownLines)
        }
        XCTAssertEqual(asked, [CGRect(x: 16, y: 146, width: 670, height: 44)], "what it shows, in the region")
        XCTAssertEqual(out, "status: Save pressed\nLine 291: the quick brown fox\nLine 292: the quick brown fox\n"
            + "Line 293: the quick brown fox")
        // The corners' characters, where the app gives them, as before.
        XCTAssertEqual(text(region) { _, _, _ in .area("Line 291: the quick\nLine 292") }, "status: Save pressed\nLine 291: the quick\nLine 292")
        // All of what it shows in the region: every line in view.
        let whole = CGRect(x: 0, y: 140, width: 720, height: 200)
        XCTAssertEqual(text(whole) { _, _, _ in .lines(shownLines) }.components(separatedBy: "\n").count, 10)
        XCTAssertEqual(text(whole) { _, _, _ in .visible("Line 291\nLine 292") }, "Line 291\nLine 292", "its middle isn't the frame's")
    }

    /// What a scroll area has scrolled out of its view isn't shown in the region, though it's inside the window.
    func testWhatsScrolledOutOfAScrollAreaIsntRead() {
        _ = window([
            Fake(1, "AXButton", frame: CGRect(x: 600, y: 100, width: 100, height: 30), kids: [
                Fake(2, "AXStaticText", value: "Sheet Later", frame: CGRect(x: 610, y: 105, width: 80, height: 20)),
            ]),
            Fake(3, "AXScrollArea", frame: CGRect(x: 716, y: 146, width: 80, height: 426), kids: [
                Fake(4, "AXStaticText", value: "Row 67", frame: CGRect(x: 716, y: 104, width: 64, height: 22)),
                Fake(5, "AXStaticText", value: "Row 69", frame: CGRect(x: 716, y: 150, width: 64, height: 22)),
            ]),
        ])
        XCTAssertEqual(text(CGRect(x: 590, y: 90, width: 220, height: 100)), "Sheet Later\nRow 69")
    }

    /// The lines of a text area in a box: those whose middle is in it, reaching across into it; their line breaks
    /// dropped.
    func testLinesIn() {
        func line(_ t: String, _ y: CGFloat, x: CGFloat = 20, width: CGFloat = 300) -> AX.ShownLine {
            AX.ShownLine(text: t, rect: CGRect(x: x, y: y, width: width, height: 14))
        }
        let lines = [line("one\n", 100), line("two\r\n", 114), line("\n", 128, width: 0), line("four", 142),
                     line("far right", 156, x: 900), line("six", 170)]
        XCTAssertEqual(AX.linesIn(lines, CGRect(x: 0, y: 110, width: 500, height: 70)), ["two", "", "four", "six"])
        XCTAssertEqual(AX.linesIn(lines, CGRect(x: 0, y: 0, width: 500, height: 106)), [], "one's middle is at 107")
        XCTAssertEqual(AX.linesIn(lines, CGRect(x: 0, y: 0, width: 1000, height: 1000)).count, 6)
    }

    /// A text area's part that accessibility didn't give: what was read off the screen there, after the rest; else
    /// the note.
    func testMissedPartsAreReadOffTheScreenOrNoted() {
        let part = CGRect(x: 0, y: 0, width: 400, height: 100)
        XCTAssertEqual(Handlers.missedText("status: ready", [], read: []), "status: ready")
        XCTAssertEqual(Handlers.missedText("status: ready", [part], read: ["Line 1\nLine 2"]),
                       "status: ready\n(a text area's lines here, read off the screen)\nLine 1\nLine 2")
        XCTAssertEqual(Handlers.missedText("status: ready", [part], read: [" "]), "status: ready\n" + AX.missedNote)
        XCTAssertEqual(Handlers.missedText("status: ready", [part], read: []), "status: ready\n" + AX.missedNote)
    }

    /// A web view seen for the first time may have built nothing of its page yet: a page with nothing in it, over
    /// the area, is listed as such and the text says so, rather than giving only the window's title as all there is.
    /// An empty frame in a page (an ad's) isn't, nor a page with something in it.
    func testAnEmptyWebPageIsNotedNotSilent() {
        let title = Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16))
        _ = window([title, Fake(2, "AXWebArea", frame: CGRect(x: 0, y: 28, width: 336, height: 215))])
        let area = CGRect(x: 0, y: 0, width: 336, height: 243)
        XCTAssertEqual(areaText(area), AX.AreaText(text: "probe web", pages: [CGRect(x: 0, y: 28, width: 336, height: 215)]))
        XCTAssertEqual(text(area), "probe web\n" + AX.pageNote)
        XCTAssertEqual(areaText(CGRect(x: 0, y: 100, width: 100, height: 50)).pages, [CGRect(x: 0, y: 100, width: 100, height: 50)],
                       "only its part in the area")
        XCTAssertEqual(areaText(CGRect(x: 0, y: 0, width: 336, height: 20)).pages, [], "not over it")

        _ = window([title, Fake(2, "AXWebArea", frame: CGRect(x: 0, y: 28, width: 336, height: 215), kids: [
            Fake(3, "AXStaticText", value: "A web page", frame: CGRect(x: 10, y: 40, width: 100, height: 18)),
            Fake(4, "AXWebArea", frame: CGRect(x: 10, y: 100, width: 300, height: 120)),
        ])])
        XCTAssertEqual(areaText(area), AX.AreaText(text: "probe web\nA web page"), "built; its empty frame isn't missed")
    }

    /// What was read off the screen over such a page comes after the rest; else the note.
    func testAnEmptyWebPagesPartIsReadOffTheScreenOrNoted() {
        let part = CGRect(x: 0, y: 28, width: 336, height: 215)
        XCTAssertEqual(Handlers.pageText("probe web", [], read: []), "probe web")
        XCTAssertEqual(Handlers.pageText("probe web", [part], read: ["A web page\nWeb Button"]),
                       "probe web\n(a web page's text here, read off the screen)\nA web page\nWeb Button")
        XCTAssertEqual(Handlers.pageText("probe web", [part], read: ["  "]), "probe web\n" + AX.pageNote)
        XCTAssertEqual(Handlers.pageText("(no text in that area)", [part], read: []), "(no text in that area)\n" + AX.pageNote)
    }

    // MARK: a web view that hasn't built its page yet

    let host = CGRect(x: 0, y: 28, width: 336, height: 215)  // the probe's web view
    let probeWindow = CGRect(x: 0, y: 0, width: 336, height: 243)

    /// The probe's web window at first contact: its title, a close button, and the web view's host, whose
    /// children can't be had yet (no web page in it at all); `built`, the page in it.
    @discardableResult
    func probeWeb(built: Bool) -> Fake {
        let page = Fake(4, "AXWebArea", frame: host, kids: [
            Fake(5, "AXStaticText", value: "A web page", frame: CGRect(x: 10, y: 40, width: 100, height: 18)),
        ])
        return window([
            Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
            Fake(2, "AXButton", subrole: "AXCloseButton", frame: CGRect(x: 8, y: 6, width: 14, height: 14), fails: true),
            built ? Fake(3, "AXGroup", frame: host, kids: [page]) : Fake(3, "AXGroup", frame: host, fails: true),
        ], title: "probe web")
    }

    /// With nothing read but the window's title, the host holding nothing counts as an empty page: listed, and
    /// the text says so. Built, it's read as before.
    func testAHostHoldingNothingIsAnEmptyPageWhenOnlyTheTitleWasRead() {
        probeWeb(built: false)
        XCTAssertEqual(areaText(probeWindow), AX.AreaText(text: "probe web", pages: [host], titleOnly: true))
        XCTAssertEqual(text(probeWindow), "probe web\n" + AX.pageNote)
        XCTAssertEqual(areaText(CGRect(x: 0, y: 0, width: 200, height: 150)).pages, [CGRect(x: 0, y: 28, width: 200, height: 122)],
                       "only its part in the area")
        probeWeb(built: true)
        XCTAssertEqual(areaText(probeWindow), AX.AreaText(text: "probe web\nA web page"))
        // A title bar's button that says what it is is no more of the window's text than the title.
        _ = window([
            Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
            Fake(2, "AXButton", subrole: "AXZoomButton", title: "zoom", frame: CGRect(x: 48, y: 6, width: 14, height: 14)),
            Fake(3, "AXGroup", frame: host),
        ], title: "probe  web")
        XCTAssertEqual(areaText(probeWindow), AX.AreaText(text: "zoom probe web", pages: [host], titleOnly: true))
    }

    /// Something of what the window shows read beside it: a group holding nothing isn't doubted, nor is a part of a
    /// page that's empty.
    func testAHostHoldingNothingBesideWhatWasReadIsntCounted() {
        _ = window([
            Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
            Fake(2, "AXStaticText", value: "status: ready", frame: CGRect(x: 10, y: 30, width: 100, height: 16)),
            Fake(3, "AXGroup", frame: CGRect(x: 0, y: 50, width: 336, height: 193), fails: true),
        ], title: "probe web")
        XCTAssertEqual(areaText(probeWindow), AX.AreaText(text: "probe web\nstatus: ready"))
        // The title alone isn't doubted when the window's title is something else.
        _ = window([Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
                    Fake(3, "AXGroup", frame: host, fails: true)], title: "Notes")
        XCTAssertEqual(areaText(probeWindow), AX.AreaText(text: "probe web"))
    }

    /// A button whose children can't be had is never taken for a host holding nothing, however big; nor is a group
    /// smaller than a few lines of text.
    func testControlsHoldingNothingArentHosts() {
        _ = window([
            Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
            Fake(2, "AXButton", frame: CGRect(x: 0, y: 28, width: 200, height: 72), fails: true),
            Fake(3, "AXGroup", frame: CGRect(x: 0, y: 28, width: 95, height: 70), fails: true),  // 33% of the area
        ], title: "probe web")
        let area = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(areaText(area), AX.AreaText(text: "probe web", titleOnly: true))
        XCTAssertNil(AX.hollowPart(CGRect(x: 0, y: 28, width: 95, height: 70), clip: nil, within: area))
        XCTAssertNil(AX.hollowPart(CGRect(x: 0, y: 0, width: 400, height: 400), clip: CGRect(x: 0, y: 0, width: 400, height: 20),
                                   within: area), "scrolled mostly out of view: under 30% of the area")
        XCTAssertEqual(AX.hollowPart(host, clip: nil, within: probeWindow), host)
    }

    /// What `regionText` asked for, with a made-up read, pause and look off the screen.
    struct RegionRun {
        var reads = 0
        var pauses: [Double] = []
        var looked: [CGRect] = []
    }

    @MainActor
    func regionText(_ region: CGRect, _ run: inout RegionRun, window: (Int) -> Void,
                    off: [OCR.Line] = []) async throws -> String {
        var r = run
        defer { run = r }
        return try await Handlers.regionText(region, read: {
            r.reads += 1
            window(r.reads)
            return areaText(region)
        }, pause: { r.pauses.append($0) }, look: { r.looked.append($0); return off })
    }

    /// The probe's web window at first contact: the read that gave only its title is asked again a moment later,
    /// by when the page is there; nothing is read off the screen.
    @MainActor
    func testATitleOnlyReadIsAskedAgainAndGetsThePage() async throws {
        var run = RegionRun()
        let out = try await regionText(probeWindow, &run, window: { self.probeWeb(built: $0 > 1) })
        XCTAssertEqual(out, "probe web\nA web page")
        XCTAssertEqual(run.reads, 2)
        XCTAssertEqual(run.pauses, [0.15])
        XCTAssertEqual(run.looked, [])
    }

    /// Still nothing in the host when asked again: its part is read off the screen, else the note says its text is
    /// missing.
    @MainActor
    func testAHostStillHoldingNothingIsReadOffTheScreenOrNoted() async throws {
        var run = RegionRun()
        var out = try await regionText(probeWindow, &run, window: { _ in self.probeWeb(built: false) },
                                       off: [line("A web page", 40, 1)])
        XCTAssertEqual(out, "probe web\n(a web page's text here, read off the screen)\nA web page")
        XCTAssertEqual(run.reads, 2)
        XCTAssertEqual(run.pauses, [0.15])
        XCTAssertEqual(run.looked, [host])
        run = RegionRun()
        out = try await regionText(probeWindow, &run, window: { _ in self.probeWeb(built: false) })
        XCTAssertEqual(out, "probe web\n" + AX.pageNote)
    }

    /// Only the title over a region that could hold a few lines, and no host in it: asked again, then the whole
    /// region read off the screen, as when nothing is exposed. A region too small to hold anything isn't doubted.
    @MainActor
    func testATitleOnlyReadWithNoHostIsReadOffTheScreen() async throws {
        func titleAndPicture(_: Int) {
            _ = window([Fake(1, "AXStaticText", value: "probe web", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
                        Fake(2, "AXImage", frame: host)], title: "probe web")
        }
        var run = RegionRun()
        var out = try await regionText(probeWindow, &run, window: titleAndPicture, off: [line("probe web", 4, 1), line("Chart: sales", 60, 1)])
        XCTAssertEqual(out, "(read off the screen)\nprobe web\nChart: sales")
        XCTAssertEqual(run.pauses, [0.15])
        XCTAssertEqual(run.looked, [probeWindow])
        run = RegionRun()
        out = try await regionText(probeWindow, &run, window: titleAndPicture)
        XCTAssertEqual(out, "probe web", "nothing more there")
        run = RegionRun()
        out = try await regionText(CGRect(x: 90, y: 0, width: 120, height: 30), &run, window: titleAndPicture)
        XCTAssertEqual(out, "probe web")
        XCTAssertEqual(run.reads, 1)
        XCTAssertEqual(run.pauses, [])
        XCTAssertEqual(run.looked, [])
    }

    /// A native region that gave its text is given it as before: read once, with no pause and nothing read off the
    /// screen.
    @MainActor
    func testANativeRegionThatGaveItsTextIsReadOnce() async throws {
        func native(_: Int) {
            _ = window([
                Fake(1, "AXStaticText", value: "Invoice", frame: CGRect(x: 100, y: 4, width: 80, height: 16)),
                Fake(2, "AXStaticText", value: "Total $42.50", frame: CGRect(x: 10, y: 40, width: 120, height: 16)),
                Fake(3, "AXButton", title: "Pay", frame: CGRect(x: 200, y: 40, width: 60, height: 22)),
                Fake(4, "AXGroup", frame: CGRect(x: 0, y: 70, width: 336, height: 170)),
            ], title: "Invoice")
        }
        var run = RegionRun()
        let out = try await regionText(probeWindow, &run, window: native)
        native(0)
        XCTAssertEqual(out, text(probeWindow))
        XCTAssertEqual(out, "Invoice\nTotal $42.50 Pay")
        XCTAssertEqual(run.reads, 1)
        XCTAssertEqual(run.pauses, [])
        XCTAssertEqual(run.looked, [])
    }

    /// Password fields are still never read.
    func testPasswordFieldsStayHidden() {
        _ = window([
            Fake(1, "AXStaticText", value: "Password", frame: CGRect(x: 10, y: 10, width: 80, height: 16)),
            Fake(2, "AXTextField", subrole: "AXSecureTextField", value: "hunter2", frame: CGRect(x: 100, y: 10, width: 200, height: 16)),
        ])
        XCTAssertEqual(text(CGRect(x: 0, y: 0, width: 400, height: 40)), "Password")
    }

    // MARK: the cap

    /// Past the cap the text stops at the end of a line, with the note.
    func testTheTextInAnAreaIsCapped() {
        _ = window((1...20).map { i in
            Fake(i, "AXStaticText", value: String(repeating: "abcdefghij", count: 100),
                 frame: CGRect(x: 10, y: CGFloat(i) * 20, width: 900, height: 16))
        })
        let lines = text(CGRect(x: 0, y: 0, width: 1000, height: 3000)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 8)  // 7 whole lines of 1000 (8007 characters would be over 8000)
        XCTAssertEqual(lines.dropLast().map(\.count), Array(repeating: 1000, count: 7))
        XCTAssertEqual(lines.last, AX.textCapNote)
    }

    /// Capped and cut short by a slow app: both notes, the slow one last.
    func testTheCapAndTheWalkBudgetBothHold() {
        _ = window((1...20).map { i in
            Fake(i, "AXStaticText", value: String(repeating: "abcdefghij", count: 100),
                 frame: CGRect(x: 10, y: CGFloat(i) * 20, width: 900, height: 16))
        })
        let lines = text(CGRect(x: 0, y: 0, width: 1000, height: 3000), cost: 0.125).components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "… (cut short: the app answered slowly; zoom in with a screenshot for the rest)")
        XCTAssertEqual(lines[lines.count - 2], AX.textCapNote)
        XCTAssertEqual(lines.count, 9)
    }

    func testCapped() {
        XCTAssertEqual(AX.capped("short", 10, note: "N"), "short")
        XCTAssertEqual(AX.capped("short", 10, note: "N", cut: true), "short\nN")
        XCTAssertEqual(AX.capped("1234567890", 10, note: "N"), "1234567890")  // exactly at the cap
        // A line ends in the last fifth: cut there.
        XCTAssertEqual(AX.capped("123456789\nabcdef", 10, note: "N"), "123456789\nN")
        // None does: cut at the cap.
        XCTAssertEqual(AX.capped("12\n4567890abcdef", 10, note: "N"), "12\n4567890\nN")
    }

    // MARK: duplicates

    func testTheSameTextAPointOrTwoOffIsGivenOnce() {
        func run(_ text: String, _ x: CGFloat, _ y: CGFloat) -> (rect: CGRect, text: String) {
            (CGRect(x: x, y: y, width: 40, height: 14), text)
        }
        let kept = AX.distinct([
            run("Total", 99.9, 50), run("Total", 100.1, 50.5),  // across a whole point: was given twice
            run("Total", 102.5, 52),  // within 3 pt of the first
            run("Total", 104, 50),  // 4 pt off: another one
            run("Tax", 100, 50),  // other text at the same place
            run("Total", 100, 80),  // the next line
            run("Price", 100.4, 10), run("Price", 100.6, 10),
        ])
        XCTAssertEqual(kept.map { $0.text }, ["Total", "Total", "Tax", "Total", "Price"])
        XCTAssertEqual(kept.map { $0.rect.minX }, [99.9, 104, 100, 100, 100.4])
    }

    /// Through the walk: a label exposed twice, 1.5 pt apart, reads once.
    func testADoubledLabelReadsOnce() {
        _ = window([
            Fake(1, "AXStaticText", value: "Price", frame: CGRect(x: 100, y: 50, width: 40, height: 16)),
            Fake(2, "AXStaticText", value: "Price", frame: CGRect(x: 101.5, y: 51, width: 40, height: 16)),
        ])
        XCTAssertEqual(text(CGRect(x: 0, y: 0, width: 400, height: 200)), "Price")
    }

    // MARK: the pieces of a text area's part

    func testFits() {
        XCTAssertEqual(AX.fits(CGSize(width: 800, height: 200)), 4000)
        XCTAssertEqual(AX.fits(CGSize(width: 10, height: 5)), 100)  // never less than this
    }

    func testHeadEndsAtAWord() {
        XCTAssertEqual(AX.head("short", 10), "short")
        XCTAssertEqual(AX.head("alpha beta gamma", 8), "alpha")
        XCTAssertEqual(AX.head("alpha beta", 5), "alpha")  // a word ends right there
        let unbroken = String(repeating: "x", count: 100)
        XCTAssertEqual(AX.head(unbroken, 50).count, 50)  // no word end near: cut at the count
    }

    func testBetweenTheCorners() {
        func r(_ l: Int, _ n: Int) -> CFRange { CFRange(location: l, length: n) }
        func pair(_ x: CFRange?) -> [Int]? { x.map { [$0.location, $0.length] } }
        XCTAssertEqual(pair(AX.between(r(5, 1), r(20, 1), within: r(0, 100))), [5, 16])  // both corner characters in
        XCTAssertEqual(pair(AX.between(r(5, 1), r(20, 1), within: r(10, 5))), [10, 5])  // kept to what's in view
        XCTAssertEqual(pair(AX.between(r(5, 1), r(100, 0), within: r(0, 100))), [5, 95])  // past the end of the text
        XCTAssertNil(AX.between(r(99, 1), r(99, 1), within: r(0, 100)))  // one character: blank space past the text
        XCTAssertNil(AX.between(r(20, 1), r(5, 1), within: r(0, 100)))  // the wrong way round
        XCTAssertNil(AX.between(r(5, 1), r(8, 1), within: r(50, 10)))  // nothing of it in view
    }

    func testWholeWords() {
        let s = "Total $1,299.00 due"
        func words(_ l: Int, _ n: Int) -> String {
            let w = AX.wholeWords(CFRange(location: l, length: n), of: s)
            return (s as NSString).substring(with: NSRange(location: w.location, length: w.length))
        }
        XCTAssertEqual(words(9, 3), "$1,299.00")  // a corner inside a price: all of it
        XCTAssertEqual(words(0, 5), "Total")  // already whole
        XCTAssertEqual(words(2, 6), "Total $1,299.00")
        XCTAssertEqual(words(16, 3), "due")
    }

    // MARK: read off the screen

    func line(_ text: String, _ y: CGFloat, _ confidence: Float) -> OCR.Line {
        OCR.Line(text: text, rect: CGRect(x: 10, y: y, width: 200, height: 14), confidence: confidence)
    }

    /// Doubtful (Vision's 0.3) short marks go; words stay, however doubtful.
    func testDoubtfulMarksAreDroppedButNotWords() {
        XCTAssertTrue(OCR.kept(line("Invoice 42", 0, 1)))
        XCTAssertTrue(OCR.kept(line("—", 0, 0.5)))  // sure: kept, whatever it is
        XCTAssertFalse(OCR.kept(line("| O .", 0, 0.3)))
        XCTAssertFalse(OCR.kept(line("x", 0, 0.3)))
        XCTAssertFalse(OCR.kept(line("•", 0, 0.1)))
        XCTAssertTrue(OCR.kept(line("Total", 0, 0.3)))
        XCTAssertTrue(OCR.kept(line("OK", 0, 0.3)))
        XCTAssertTrue(OCR.kept(line("Due: $42.50", 0, 0.1)))
    }

    func testTextReadOffTheScreenLeavesDoubtfulMarksOut() {
        let lines = [line("Invoice 42", 0, 1), line("| O .", 20, 0.3), line("Total 9", 40, 0.3)]
        XCTAssertEqual(OCR.text(lines), "Invoice 42\nTotal 9")
    }

    /// When every line is doubtful, they're all given: something was read there.
    func testAllDoubtfulIsStillGiven() {
        XCTAssertEqual(OCR.text([line("| O", 0, 0.3)]), "| O")
    }

    func testTextReadOffTheScreenIsCapped() {
        let lines = (0..<100).map { line(String(repeating: "abcdefghij", count: 10), CGFloat($0) * 20, 1) }
        let out = OCR.text(lines).components(separatedBy: "\n")
        XCTAssertEqual(out.last, OCR.capNote)
        XCTAssertEqual(out.count, 80)  // 79 whole lines of 100 (80 would be 8079 characters, over 8000)
    }
}
