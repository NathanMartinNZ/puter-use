import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// Labels: a control with no name of its own is called what titles it (`AXTitleUIElement`), and a link, button or
/// heading what the text in it says, leaving those texts' own lines out; an image repeating its link is left out;
/// the interactive outline keeps sheets, dialogs, headings and alerts; a target naming a label finds its control.
/// A made-up window (no app needed).
@MainActor
final class LabelsTests: XCTestCase {
    final class Fake {
        let element: AXUIElement
        let role: String
        let subrole, title, placeholder, value: String?
        var titledBy: Fake?
        let frame: CGRect
        let kids: [Fake]
        init(_ id: Int, _ role: String, subrole: String?, title: String?, placeholder: String?, value: String?,
             titledBy: Fake?, frame: CGRect, kids: [Fake]) {
            element = AXUIElementCreateApplication(pid_t(960_000 + id))  // a distinct element; never asked anything
            (self.role, self.subrole, self.title, self.placeholder, self.value) = (role, subrole, title, placeholder, value)
            (self.titledBy, self.frame, self.kids) = (titledBy, frame, kids)
        }
    }

    var byElement: [AXUIElement: Fake] = [:]
    var id = 0
    var reads = 0

    /// An element on a row of its own.
    func make(_ role: String, _ title: String? = nil, value: String? = nil, subrole: String? = nil, placeholder: String? = nil,
              titledBy: Fake? = nil, kids: [Fake] = []) -> Fake {
        id += 1
        let f = Fake(id, role, subrole: subrole, title: title, placeholder: placeholder, value: value, titledBy: titledBy,
                     frame: CGRect(x: 10, y: CGFloat(id) * 20, width: 300, height: 16), kids: kids)
        byElement[f.element] = f
        return f
    }

    func window(_ kids: [Fake]) -> Fake {
        id += 1
        let f = Fake(id, "AXWindow", subrole: nil, title: nil, placeholder: nil, value: nil, titledBy: nil,
                     frame: CGRect(x: 0, y: 0, width: 1000, height: 4000), kids: kids)
        byElement[f.element] = f
        return f
    }

    /// `AX.attrs` of a fake, as the app would give them.
    func read(_ el: AXUIElement) -> [AnyObject]? {
        reads += 1
        guard let f = byElement[el] else { return nil }
        var pos = f.frame.origin, size = f.frame.size
        let none = NSNull()
        func s(_ v: String?) -> AnyObject {
            if let v { return v as NSString }
            return none
        }
        let titleUI: AnyObject = f.titledBy.map { $0.element as AnyObject } ?? none
        return [f.role as NSString, s(f.subrole), s(f.title), none, s(f.value), f.kids.map(\.element) as NSArray,
                AXValueCreate(.cgPoint, &pos)!, AXValueCreate(.cgSize, &size)!, none, kCFBooleanTrue, s(f.placeholder),
                none, none, titleUI]
    }

    /// The outline of a window holding `kids` (a new registry), and how many reads it took. `pressable` take a press.
    func outline(_ kids: [Fake], interactive: Bool = false, pressable: [Fake] = []) -> (lines: [String], reg: AX.Registry) {
        let win = window(kids)
        let reg = AX.Registry()
        reads = 0
        let text = AX.outline(of: win.element, reg, visible: win.frame, menus: [], maxElements: 300, maxChars: 8000,
                              interactive: interactive, now: { 0 }, read: { self.read($0) },
                              presses: { el in pressable.contains { CFEqual($0.element, el) } })
        return (text.components(separatedBy: "\n"), reg)
    }

    // MARK: - what titles a control

    /// A field is called what titles it, in the full outline and the interactive one, and the label's line before
    /// it goes: it would only say the same again.
    func testAFieldIsCalledWhatTitlesItAndTheLabelLineGoes() {
        let label = make("AXStaticText", value: "Email")
        let field = make("AXTextField", value: "ada@example.com", titledBy: label)
        XCTAssertEqual(outline([label, field]).lines, ["#1 field \"Email\" =\"ada@example.com\""])
        XCTAssertEqual(outline([label, field], interactive: true).lines, ["#1 field \"Email\" =\"ada@example.com\""])
    }

    /// A label after its control (a checkbox's) is read once, early, and its line goes too.
    func testALabelAfterItsControlIsReadOnceAndItsLineGoes() {
        let box = make("AXCheckBox", value: "1")
        let after = make("AXStaticText", value: "Remember me")
        box.titledBy = after
        XCTAssertEqual(outline([box, after]).lines, ["#1 checkbox \"Remember me\" checked"])
        XCTAssertEqual(reads, 3)  // the window, the checkbox and its label: none twice
    }

    /// The label's line stays when it isn't next to its control, or says more than the control's own name.
    func testALabelLineStaysWhenItsNotNextToItsFieldOrSaysMore() {
        let label = make("AXStaticText", value: "Email")
        let help = make("AXButton", "Help")
        let field = make("AXTextField", titledBy: label)
        XCTAssertEqual(outline([label, help, field]).lines, ["Email", "#1 button \"Help\"", "#2 field \"Email\""])

        let find = make("AXStaticText", value: "Find in page:")
        let search = make("AXTextField", "Search", titledBy: find)  // a name of its own, saying something else
        XCTAssertEqual(outline([find, search]).lines, ["Find in page:", "#1 field \"Search\""])

        let short = make("AXStaticText", value: "Email:")
        let named = make("AXTextField", "Email address", titledBy: short)  // its own name says it all
        XCTAssertEqual(outline([short, named]).lines, ["#1 field \"Email address\""])
    }

    /// The name a field has itself is still what tells it's the same element later (`AX.node`); what the outline
    /// calls it is kept apart, for messages. A label whose line went has no number.
    func testTheFieldsOwnNameIsStillWhatTellsItsTheSame() {
        let label = make("AXStaticText", value: "Email")
        let field = make("AXTextField", titledBy: label)
        let work = make("AXStaticText", value: "Work email")
        let hinted = make("AXTextField", placeholder: "you@example.com", titledBy: work)
        let (lines, reg) = outline([label, field, work, hinted])
        XCTAssertEqual(lines, ["#1 field \"Email\"", "#2 field \"Work email\""])
        XCTAssertNil(reg.nodes[1]?.label)  // no name of its own: told by its role, as before
        XCTAssertEqual(reg.nodes[1]?.shown, "Email")
        XCTAssertEqual(reg.nodes[2]?.label, "you@example.com")  // its placeholder, as AX.label reads it
        XCTAssertEqual(reg.nodes[2]?.shown, "Work email")
        XCTAssertNil(reg.ids[label.element])
        XCTAssertNil(reg.ids[work.element])
        XCTAssertEqual(reg.lines.map(\.1), lines)
    }

    // MARK: - the text in a control

    /// A link, button, tab or heading with no name is called what the text in it says, and that text (and a blank
    /// one beside it) isn't a line of its own; each element is read once.
    func testALinkButtonTabOrHeadingWithNoNameIsCalledWhatItsTextSays() {
        let heading = make("AXHeading", kids: [make("AXStaticText", value: "Settings")])
        let link = make("AXLink", kids: [make("AXStaticText", value: "Sign in")])
        let button = make("AXButton", kids: [make("AXStaticText", value: "Save"), make("AXStaticText", value: " ")])
        let tab = make("AXRadioButton", subrole: "AXTabButton", kids: [make("AXStaticText", value: "General")])
        let want = ["heading \"Settings\"", "#1 link \"Sign in\"", "#2 button \"Save\"", "#3 tab \"General\""]
        XCTAssertEqual(outline([heading, link, button, tab]).lines, want)
        XCTAssertEqual(reads, 10)
        XCTAssertEqual(outline([heading, link, button, tab], interactive: true).lines, want)
    }

    /// Text too long for a label stays a line of its own, under its unnamed link.
    func testLongTextIsntMadeALabel() {
        let long = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let lines = outline([make("AXLink", kids: [make("AXStaticText", value: long)])]).lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "#1 link")
        XCTAssertTrue(lines[1].hasPrefix(" word word"), lines[1])  // plain text, whole (under 200 characters): no number
    }

    /// Text that takes a press under a heading keeps its line and number (the heading has none), though the heading
    /// is still called what it says; under a link, the link is what a press goes to.
    func testTextThatTakesAPressUnderAHeadingKeepsItsNumber() {
        let billing = make("AXStaticText", value: "Billing")
        let heading = [make("AXHeading", kids: [billing])]
        XCTAssertEqual(outline(heading, pressable: [billing]).lines, ["heading \"Billing\"", " #1 text \"Billing\""])
        XCTAssertEqual(outline(heading, interactive: true, pressable: [billing]).lines, ["heading \"Billing\""])
        let more = make("AXStaticText", value: "More")
        XCTAssertEqual(outline([make("AXLink", kids: [more])], pressable: [more]).lines, ["#1 link \"More\""])
    }

    /// An image saying what the link or button it's in says is left out (case, spacing and punctuation aside), as
    /// is text saying it in other case; an image saying something else, or in a group, stays.
    func testAnImageSayingWhatItsLinkSaysIsLeftOut() {
        let kids = [
            make("AXLink", "GitHub", kids: [make("AXImage", "github ")]),
            make("AXLink", "Home", kids: [make("AXImage", "Company logo")]),
            make("AXGroup", "GitHub", kids: [make("AXImage", "GitHub")]),
            make("AXLink", "Read the docs", kids: [make("AXStaticText", value: "DOCS")]),
        ]
        XCTAssertEqual(outline(kids).lines, [
            "#1 link \"GitHub\"", "#2 link \"Home\"", " #3 image \"Company logo\"", "group \"GitHub\"", " #4 image \"GitHub\"",
            "#5 link \"Read the docs\"",
        ])
    }

    func testWhatRepeatsALabelAndHowTextsJoin() {
        XCTAssertTrue(AX.repeats("github ", in: "GitHub"))
        XCTAssertTrue(AX.repeats("Email:", in: "Email address"))
        XCTAssertFalse(AX.repeats("OK", in: "Look"))  // whole words only
        XCTAssertFalse(AX.repeats("·", in: "Docs · Blog"))  // no words at all
        let row = { (x: CGFloat, w: CGFloat) in CGRect(x: x, y: 0, width: w, height: 12) }
        XCTAssertEqual(AX.joinRuns([("$", row(0, 8)), ("9.99", row(8, 30)), ("Buy", row(60, 30))]), "$9.99 Buy")
        XCTAssertEqual(AX.joinRuns([("Sign", nil), (" in ", nil)]), "Sign in")
    }

    // MARK: - the interactive outline

    /// Besides what can be acted on, the interactive outline keeps what says where things are: a heading that says
    /// something, an alert's text, a sheet, a web page's dialog.
    func testTheInteractiveOutlineKeepsWhatSaysWhereThingsAre() {
        let kids = [
            make("AXHeading", "Billing address"),
            make("AXHeading"),  // says nothing
            make("AXStaticText", value: "Plain text"),
            make("AXGroup", subrole: "AXApplicationAlert", kids: [make("AXStaticText", value: "Card declined")]),
            make("AXSheet", kids: [make("AXStaticText", value: "Save changes?"), make("AXButton", "Save")]),
            make("AXGroup", "Sign in", subrole: "AXApplicationDialog", kids: [make("AXButton", "Close")]),
        ]
        XCTAssertEqual(outline(kids, interactive: true).lines, [
            "heading \"Billing address\"", "Card declined", "#1 sheet", " #2 button \"Save\"",
            "dialog \"Sign in\"", " #3 button \"Close\"",
        ])
        // A web page's dialog is one in the full outline too, named or not.
        let dialog = make("AXGroup", subrole: "AXApplicationDialog", kids: [make("AXButton", "OK")])
        XCTAssertEqual(outline([dialog]).lines, ["dialog", " #1 button \"OK\""])
    }

    // MARK: - a target naming a label

    func search(_ kids: [Fake], _ q: String, role: String? = nil) -> [AX.Match] {
        let win = window(kids)
        return AX.search(in: [(win.element, win.frame)], menus: [], query: q, role: role, limit: 30, budget: 1,
                         offScreen: false, now: { 0 }, read: { self.read($0) }).matches
    }

    /// A field goes by what titles it, so a target naming the label finds the field, before the label itself.
    func testATargetNamingALabelFindsTheFieldItTitles() {
        let label = make("AXStaticText", value: "Email")
        let field = make("AXTextField", titledBy: label)
        let all = search([label, field], "Email")
        XCTAssertEqual(all.map(\.role), ["text", "field"])
        XCTAssertTrue(all.allSatisfy(\.exact))
        let picked = Handlers.narrowed(all, Handlers.Spec(text: "Email"))
        XCTAssertEqual(picked.count, 1)
        XCTAssertTrue(picked.first.map { CFEqual($0.element, field.element) } == true)
        XCTAssertEqual(picked.first?.label, "Email")
        // Asked for the text, it's the text; by role alone, the field shows its label.
        let text = search([label, field], "Email", role: "text")
        XCTAssertEqual(Handlers.narrowed(text, Handlers.Spec(text: "Email", role: "text")).map(\.role), ["text"])
        XCTAssertEqual(search([label, field], "", role: "field").map(\.label), ["Email"])
        // A field with a name of its own goes by that.
        let named = make("AXTextField", "Search", titledBy: label)
        XCTAssertEqual(search([label, named], "Email").map(\.role), ["text"])
    }

    /// A label after its control is read for it: the control comes first.
    func testALabelAfterItsControlFindsTheControl() {
        let box = make("AXCheckBox")
        let after = make("AXStaticText", value: "Remember me")
        box.titledBy = after
        let all = search([box, after], "Remember")
        XCTAssertEqual(all.map(\.role), ["checkbox", "text"])
        XCTAssertEqual(Handlers.narrowed(all, Handlers.Spec(text: "Remember")).map(\.role), ["checkbox"])
    }

    /// The label that's named (type, fill, select, checked) acts on the one control it says it titles, of the kind
    /// the action needs, or the one the label element holding it titles. Never a guess: none for several, or for a
    /// control named.
    func testALabelNamesTheOneControlItTitles() {
        let label = make("AXStaticText", value: "Email"), field = make("AXTextField"), other = make("AXTextField")
        let inner = make("AXStaticText", value: "Remember me")
        let group = make("AXGroup", kids: [inner])
        let box = make("AXCheckBox"), button = make("AXButton", "Email")
        let parents: [AXUIElement: AXUIElement] = [inner.element: group.element]
        func titled(_ f: Fake, _ fits: String, _ serves: [AXUIElement: [AXUIElement]]) -> Fake? {
            AX.titled(by: f.element, { self.byElement[$0]?.role == fits }, role: { self.byElement[$0]?.role },
                      serves: { serves[$0] ?? [] }, parent: { parents[$0] }).flatMap { self.byElement[$0] }
        }
        let says: [AXUIElement: [AXUIElement]] = [
            label.element: [field.element], group.element: [box.element], button.element: [field.element],
        ]
        XCTAssertTrue(titled(label, "AXTextField", says) === field)
        XCTAssertNil(titled(label, "AXCheckBox", says))  // it titles no checkbox
        XCTAssertTrue(titled(inner, "AXCheckBox", says) === box)  // the label element it's in does
        XCTAssertNil(titled(button, "AXTextField", says))  // a control isn't a label
        XCTAssertNil(titled(label, "AXTextField", [label.element: [field.element, other.element]]))  // two: no guess
    }

    // MARK: - read's keys

    /// act's check knows read's keys (the action that reads an element's or an area's text in a batch).
    func testReadsKeys() {
        let keys = Handlers.actionKeys("read")
        XCTAssertEqual(keys?.name, "read")
        XCTAssertEqual(keys?.takes, ["element", "target", "region", "offset", "limit", "query"])
        XCTAssertTrue(Handlers.actionKinds.contains("read"))
        let fine: [[String: Any]] = [
            ["type": "read", "target": "Notes"], ["type": "read", "element": 3, "offset": 10000, "limit": 2000],
            ["type": "read", "region": [0, 0, 400, 300], "reason": "the total"],
            ["type": "read", "target": ["text": "Notes", "role": "textarea"], "confirm": true],
        ]
        for a in fine { XCTAssertNil(Handlers.invalid(a), "\(a)") }
        XCTAssertEqual(Handlers.invalid(["type": "read", "text": "Notes"]),
                       "has an unknown key \"text\" (did you mean target?): read takes element, target, region, offset, limit, query")
    }
}
