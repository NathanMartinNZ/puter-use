import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// Reading a page's tree (`WebRead.walk`) on a made-up page, read the way `AX.readAttrs` reads one: every part of it,
/// out of view too, but not what's hidden, a table's columns or a pop-up's menu, and never a password's value; cut
/// short by its time and element budgets. Its links and controls get the window registry's numbers (`numberer`), the
/// outline's own where it gave one. And finding the page in a browser window (`page(in:)`).
final class WebReadWalkTests: XCTestCase {
    final class El {
        let element: AXUIElement
        let role: String
        var subrole, title: String?
        var value: AnyObject?
        var frame: CGRect?
        var titledBy: El?
        var kids: [El]
        init(_ id: Int, _ role: String, frame: CGRect?, kids: [El]) {
            element = AXUIElementCreateApplication(pid_t(940_000 + id))  // a distinct element; never asked anything
            (self.role, self.frame, self.kids) = (role, frame, kids)
        }
    }

    var byElement: [AXUIElement: El] = [:]
    var next = 0
    var clock: TimeInterval = 0
    var cost: TimeInterval = 0  // how far each read moves the clock on

    /// A made-up element. `value`: a string or a number.
    func el(_ role: String, _ title: String? = nil, value: Any? = nil, subrole: String? = nil,
            frame: CGRect? = CGRect(x: 10, y: 10, width: 100, height: 20), kids: [El] = []) -> El {
        next += 1
        let e = El(next, role, frame: frame, kids: kids)
        (e.title, e.subrole) = (title, subrole)
        if let s = value as? String { e.value = s as NSString } else if let n = value as? Int { e.value = NSNumber(value: n) }
        byElement[e.element] = e
        return e
    }

    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 20) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// `AX.attrs` of a fake, as the app would give them.
    func read(_ el: AXUIElement) -> [AnyObject]? {
        clock += cost
        guard let f = byElement[el] else { return nil }
        let none = NSNull()
        func s(_ v: String?) -> AnyObject {
            if let v { return v as NSString }
            return none
        }
        var pos = f.frame?.origin ?? .zero, size = f.frame?.size ?? .zero
        let p: AnyObject = f.frame == nil ? none : AXValueCreate(.cgPoint, &pos)!
        let z: AnyObject = f.frame == nil ? none : AXValueCreate(.cgSize, &size)!
        return [f.role as NSString, s(f.subrole), s(f.title), none, f.value ?? none, f.kids.map(\.element) as NSArray, p, z,
                none, kCFBooleanTrue, none, none, none, f.titledBy.map { $0.element as AnyObject } ?? none]
    }

    let screen = CGRect(x: 0, y: 0, width: 800, height: 600)

    func walk(_ root: El, maxNodes: Int = WebRead.nodeCap) -> (item: WebRead.Item?, cut: WebRead.Cut?) {
        WebRead.walk(root.element, visible: screen, maxNodes: maxNodes, now: { self.clock }, read: { self.read($0) })
    }

    /// Every part of the page is read, the parts below the fold too (marked out of view); what has no size and nothing
    /// in it goes (but a control, and a wrapper of no size round what shows), as do a table's columns, a scroll bar and
    /// what's in a pop-up (its menu). A password field's value isn't kept.
    func testThePageIsReadWholeButNotWhatsHidden() {
        let zero = box(10, 900, 0, 0)
        let page = el("AXWebArea", "Harbour news", frame: box(0, 0, 800, 5000), kids: [
            el("AXHeading", value: 1, frame: box(10, 10, 600, 30), kids: [el("AXStaticText", value: "The harbour", frame: box(10, 10, 300, 30))]),
            el("AXStaticText", value: "Far below", frame: box(10, 3000, 200)),
            el("AXStaticText", value: "hidden", frame: zero),
            el("AXImage", "spacer", frame: zero),
            el("AXGroup", frame: box(0, 0, 0, 0), kids: [el("AXLink", "Inside", frame: box(10, 60, 60))]),
            el("AXButton", "Hidden action", frame: zero),
            el("AXTable", frame: box(10, 100, 600, 40), kids: [
                el("AXRow", frame: box(10, 100, 600), kids: [
                    el("AXCell", frame: box(10, 100, 300), kids: [el("AXStaticText", value: "a", frame: box(10, 100, 20))]),
                    el("AXCell", frame: box(310, 100, 300), kids: [el("AXStaticText", value: "b", frame: box(310, 100, 20))]),
                ]),
                el("AXColumn", frame: box(10, 100, 300, 40)),
            ]),
            el("AXTextField", "Password", value: "hunter2", subrole: "AXSecureTextField", frame: box(10, 150, 200)),
            el("AXPopUpButton", "Flooding", frame: box(10, 180, 100), kids: [
                el("AXMenu", frame: box(10, 200, 100, 80), kids: [el("AXMenuItem", "Wildlife", frame: box(10, 200, 100))]),
            ]),
            el("AXScrollBar", frame: box(790, 0, 10, 600)),
        ])
        let (item, cut) = walk(page)
        XCTAssertNil(cut)
        guard let root = item else { return XCTFail("no page") }
        XCTAssertEqual(root.kids.map(\.role), ["AXHeading", "AXStaticText", "AXGroup", "AXButton", "AXTable", "AXTextField",
                                               "AXPopUpButton"])
        XCTAssertEqual(root.kids[0].value, "1")
        XCTAssertTrue(root.kids[0].numeric)
        XCTAssertFalse(root.kids[0].away)
        XCTAssertEqual(root.kids[1].value, "Far below")
        XCTAssertTrue(root.kids[1].away, "below the fold: scrolled to before it's acted on")
        XCTAssertEqual(root.kids[4].kids.map(\.role), ["AXRow"], "no column")
        XCTAssertNil(root.kids[5].value, "a password's value isn't kept")
        XCTAssertEqual(root.kids[5].name, "Password")
        XCTAssertTrue(root.kids[6].kids.isEmpty, "a pop-up's menu isn't the page")
        XCTAssertTrue(root.kids[1].parent.map { CFEqual($0, page.element) } == true)

        let text = WebRead.markdown(item, number: WebRead.numberer(AX.Registry())).text
        XCTAssertEqual(text, """
            # The harbour

            Far below

            [Inside](#1)

            [button "Hidden action"](#2)

            | a | b |
            | --- | --- |

            [password "Password"](#3)
            [popup "Flooding"](#4)
            """)
        XCTAssertFalse(text.contains("hunter2"))
    }

    /// A control with no name of its own is called what titles it (a form's label), and that text's own line goes.
    func testAFieldIsCalledByItsLabel() {
        let label = el("AXStaticText", value: "Email address", frame: box(10, 10, 100))
        let field = el("AXTextField", frame: box(120, 10, 200))
        field.titledBy = label
        let page = el("AXWebArea", frame: box(0, 0, 800, 600), kids: [el("AXGroup", frame: box(10, 10, 700), kids: [label, field])])
        let item = walk(page).item
        XCTAssertEqual(item?.kids.first?.kids.last?.name, "Email address")
        XCTAssertNil(item?.kids.first?.kids.last?.ownLabel, "not its own name: not what tells it's the same one later")
        XCTAssertEqual(WebRead.markdown(item, number: WebRead.numberer(AX.Registry())).text, "[field \"Email address\"](#1)")
    }

    /// Links and controls get the window registry's numbers: one the outline numbered keeps its number, the rest get
    /// the next ones, with what tells each is the same later (role, own label, what it was called, its container) and
    /// whether it was out of view. Past the cap, none: the end says how many.
    func testNumbersAreTheWindowsOwn() {
        let docs = el("AXLink", "Docs", frame: box(70, 10, 40))
        let subscribe = el("AXButton", "Subscribe", frame: box(10, 3000, 100))
        let below = el("AXGroup", frame: box(10, 3000, 700), kids: [subscribe])
        let page = el("AXWebArea", frame: box(0, 0, 800, 5000), kids: [
            el("AXGroup", frame: box(10, 10, 700), kids: [el("AXStaticText", value: "See the ", frame: box(10, 10, 60)), docs]),
            below,
            el("AXGroup", frame: box(10, 3100, 700), kids: [el("AXLink", "Contact", frame: box(10, 3100, 60))]),
        ])
        let reg = AX.Registry()
        reg.next = 5
        XCTAssertEqual(reg.number(AX.Node(element: docs.element, frame: nil, role: "AXLink", label: "Docs", name: "link")), 5)
        let item = walk(page).item
        let out = WebRead.markdown(item, number: WebRead.numberer(reg))
        XCTAssertEqual(out.text, "See the [Docs](#5)\n\n[button \"Subscribe\"](#6)\n\n[Contact](#7)")
        XCTAssertEqual(reg.ids[docs.element], 5)
        let n = reg.nodes[6]
        XCTAssertTrue(n.map { CFEqual($0.element, subscribe.element) } == true)
        XCTAssertEqual(n?.role, "AXButton")
        XCTAssertEqual(n?.label, "Subscribe")
        XCTAssertEqual(n?.name, "button")
        XCTAssertEqual(n?.shown, "Subscribe")
        XCTAssertEqual(n?.away, true)
        XCTAssertTrue(n?.parent.map { CFEqual($0, below.element) } == true)
        XCTAssertEqual(reg.nodes[5]?.away, false)

        let few = WebRead.markdown(walk(page).item, number: WebRead.numberer(AX.Registry(), cap: 1))
        XCTAssertEqual(few.text, "See the [Docs](#1)\n\n[button \"Subscribe\"]\n\nContact\n\n"
            + "… (2 links and controls have no number: name one by what it says, as a target)")
    }

    /// Out of time (`AX.walkBudget`) or elements, the walk stops with what it has, and the page says so at its end.
    func testTheWalksBudgets() {
        let texts = (1...100).map { i in el("AXStaticText", value: "Line \(i)", frame: box(10, CGFloat(i) * 30, 200)) }
        let page = el("AXWebArea", frame: box(0, 0, 800, 4000), kids: texts)
        cost = 0.125  // 20 reads in 2.5 s
        let slow = walk(page)
        XCTAssertEqual(slow.cut, WebRead.Cut(slow: true, walked: 20))
        XCTAssertEqual(slow.item?.kids.count, 19)
        let text = WebRead.markdown(slow.item, cut: slow.cut, number: { _, _ in nil }).text
        XCTAssertTrue(text.hasPrefix("Line 1\nLine 2\n"))
        XCTAssertTrue(text.hasSuffix("\n\n" + WebRead.cutNote(WebRead.Cut(slow: true, walked: 20), last: nil)))
        XCTAssertTrue(text.contains("Line 19") && !text.contains("Line 20"))

        cost = 0
        let many = walk(page, maxNodes: 10)
        XCTAssertEqual(many.cut, WebRead.Cut(slow: false, walked: 10))
        XCTAssertEqual(many.item?.kids.count, 9)
        XCTAssertNil(walk(page).cut, "in time and under the cap: whole")
    }

    /// A browser window's page: the one with a size (another tab's may be kept in the tree with none), else the one
    /// there is, else none.
    func testThePageInAWindow() {
        let hidden = el("AXWebArea", "Other tab", frame: box(0, 0, 0, 0))
        let shown = el("AXWebArea", "This tab", frame: box(0, 80, 800, 600))
        let window = el("AXWindow", frame: box(0, 0, 800, 700), kids: [
            el("AXGroup", frame: box(0, 0, 800, 700), kids: [
                hidden, el("AXToolbar", frame: box(0, 0, 800, 80), kids: [el("AXButton", "Back")]),
                el("AXGroup", frame: box(0, 80, 800, 600), kids: [shown]),
            ]),
        ])
        XCTAssertTrue(WebRead.page(in: window.element, read: { self.read($0) }).map { CFEqual($0, shown.element) } == true)
        let onlyHidden = el("AXWindow", frame: box(0, 0, 800, 700), kids: [hidden])
        XCTAssertTrue(WebRead.page(in: onlyHidden.element, read: { self.read($0) }).map { CFEqual($0, hidden.element) } == true)
        let native = el("AXWindow", frame: box(0, 0, 800, 700), kids: [el("AXButton", "OK")])
        XCTAssertNil(WebRead.page(in: native.element, read: { self.read($0) }))
    }
}
