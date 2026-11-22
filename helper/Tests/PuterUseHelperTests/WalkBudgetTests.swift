import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// The outline and text walks stop at `AX.walkBudget` on an app that answers slowly, say so, and leave element
/// numbers alone. A made-up window (no app needed), and a clock that each read moves on by `cost`.
final class WalkBudgetTests: XCTestCase {
    final class Fake {
        let element: AXUIElement
        let role: String
        let title: String?
        let value: String?
        let frame: CGRect
        var kids: [Fake]
        init(_ id: Int, _ role: String, title: String? = nil, value: String? = nil, frame: CGRect, kids: [Fake] = []) {
            element = AXUIElementCreateApplication(pid_t(900_000 + id))  // a distinct element; never asked anything
            (self.role, self.title, self.value, self.frame, self.kids) = (role, title, value, frame, kids)
        }
    }

    var clock: TimeInterval = 0
    var reads = 0
    var byElement: [AXUIElement: Fake] = [:]

    /// A window of `n` buttons ("B1"…), or static texts ("T1"…), one per 5 pt row.
    func window(_ n: Int, role: String = "AXButton") -> Fake {
        let kids = (1...n).map { i in
            Fake(i, role, title: role == "AXButton" ? "B\(i)" : nil, value: role == "AXStaticText" ? "T\(i)" : nil,
                 frame: CGRect(x: 10, y: CGFloat(i) * 5, width: 100, height: 4))
        }
        let win = Fake(0, "AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: CGFloat(n) * 5 + 20), kids: kids)
        byElement = Dictionary(uniqueKeysWithValues: ([win] + kids).map { ($0.element, $0) })
        return win
    }

    /// Reads cost `cost` s each.
    func read(_ cost: TimeInterval) -> (AXUIElement) -> [AnyObject]? {
        { el in
            self.clock += cost
            self.reads += 1
            guard let f = self.byElement[el] else { return nil }
            var pos = f.frame.origin, size = f.frame.size
            let none = NSNull()
            return [f.role as NSString, none, (f.title as NSString?) ?? none, none, (f.value as NSString?) ?? none,
                    f.kids.map(\.element) as NSArray, AXValueCreate(.cgPoint, &pos)!, AXValueCreate(.cgSize, &size)!,
                    none, kCFBooleanTrue, none, none, none, none]
        }
    }

    func outline(_ win: Fake, _ reg: AX.Registry, cost: TimeInterval, maxElements: Int = 300, maxChars: Int = 8000) -> [String] {
        AX.outline(of: win.element, reg, visible: win.frame, menus: [], maxElements: maxElements, maxChars: maxChars,
                   interactive: false, now: { self.clock }, read: read(cost)).components(separatedBy: "\n")
    }

    let cutNote = "… (outline cut short: the app answered slowly; look again later or use a screenshot)"

    func testAnOutlineInTimeIsWholeWithNoNote() {
        XCTAssertEqual(AX.walkBudget, 2.5)
        let reg = AX.Registry()
        let lines = outline(window(100), reg, cost: 0.02)  // 2.02 s in all
        XCTAssertEqual(lines.count, 100)
        XCTAssertEqual(lines.first, "#1 button \"B1\"")
        XCTAssertEqual(lines.last, "#100 button \"B100\"")
        XCTAssertFalse(reg.cutShort)
        XCTAssertEqual(reg.lines.count, 100)
    }

    /// It stops at the first element after the budget, with what it has and the note.
    func testASlowAppIsCutShortWithANote() {
        let reg = AX.Registry()
        let lines = outline(window(100), reg, cost: 0.125)  // 12.6 s in all
        XCTAssertEqual(reads, 20)  // the window and 19 buttons: 2.5 s
        XCTAssertEqual(clock, 2.5)
        XCTAssertEqual(lines.count, 20)
        XCTAssertEqual(lines[18], "#19 button \"B19\"")
        XCTAssertEqual(lines.last, cutNote)
        XCTAssertTrue(reg.cutShort)
        XCTAssertEqual(reg.lines.map(\.0), Array(1...19))  // the note isn't a numbered line

        // The next look, in time, is whole again.
        clock = 0
        XCTAssertEqual(outline(window(100), AX.Registry(), cost: 0.001).count, 100)
    }

    /// The element and character caps still apply, with their own note.
    func testTheOtherCapsKeepTheirNote() {
        let reg = AX.Registry()
        let lines = outline(window(100), reg, cost: 0.001, maxElements: 10)
        XCTAssertEqual(lines.last, "… (truncated; zoom with region or use a screenshot)")
        XCTAssertEqual(lines.count, 11)  // the 10 it may have, then the note
        XCTAssertFalse(reg.cutShort)
    }

    /// Numbers hold across a cut-short look: the elements it didn't reach keep theirs (no pruning), and the
    /// next whole look gives every element the number it had.
    func testACutShortLookKeepsEveryNumber() {
        let reg = AX.Registry()
        let win = window(3100)  // over the 3000 at which a look forgets elements it didn't list
        let all = 6000, chars = 1_000_000
        let first = outline(win, reg, cost: 0.0001, maxElements: all, maxChars: chars)
        XCTAssertEqual(first.count, 3100)
        XCTAssertEqual(reg.nodes.count, 3100)

        clock = 0
        let cut = outline(win, reg, cost: 0.01, maxElements: all, maxChars: chars)
        XCTAssertEqual(cut.last, cutNote)
        XCTAssertEqual(Array(cut.dropLast()), Array(first.prefix(cut.count - 1)))  // same lines, same numbers
        XCTAssertEqual(reg.nodes.count, 3100)  // the rest weren't forgotten
        XCTAssertEqual(reg.ids[win.kids[3099].element], 3100)

        clock = 0
        XCTAssertEqual(outline(win, reg, cost: 0.0001, maxElements: all, maxChars: chars), first)
        XCTAssertFalse(reg.cutShort)
        XCTAssertEqual(reg.next, 3101)  // nothing renumbered
    }

    func text(_ win: Fake, cost: TimeInterval, budget: TimeInterval = AX.walkBudget) -> String {
        AX.text(of: win.element, within: win.frame, budget: budget, now: { self.clock }, read: read(cost))
    }

    func testTextInTimeIsWholeWithNoNote() {
        let out = text(window(100, role: "AXStaticText"), cost: 0.02)
        XCTAssertEqual(out.components(separatedBy: "\n"), (1...100).map { "T\($0)" })
    }

    func testSlowTextIsCutShortWithANote() {
        let out = text(window(100, role: "AXStaticText"), cost: 0.125).components(separatedBy: "\n")
        XCTAssertEqual(reads, 20)
        XCTAssertEqual(Array(out.dropLast()), (1...19).map { "T\($0)" })
        XCTAssertEqual(out.last, "… (cut short: the app answered slowly; zoom in with a screenshot for the rest)")
    }

    /// Out of time before any text: "no text", which the screenshot handler reads off the screen instead.
    func testSlowTextWithNothingReadFallsBackToTheScreen() {
        XCTAssertEqual(text(window(10, role: "AXStaticText"), cost: 3), "(no text in that area)")
        XCTAssertEqual(reads, 1)  // just the window
    }
}
