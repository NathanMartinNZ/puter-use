import ApplicationServices
import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The plan fill's object form makes before anything is filled (`Handlers.planFill`): every key looked up, what's done
/// to each by its control's kind, from the top of the form down; a key that names nothing (or several things), a value
/// its control can't take, a password field, or two keys naming one control stop it, named by the key, with nothing
/// filled and no value repeated. Made-up controls (no app needed).
@MainActor
final class FillFieldsPlanTests: XCTestCase {
    var next = 0

    /// A made-up control: a distinct element, never asked anything.
    func control(_ role: String, y: CGFloat?, x: CGFloat = 20, height: CGFloat = 22, textInput: Bool = false,
                 inPage: Bool = true, secure: Bool = false, what: String) -> Handlers.FieldControl {
        next += 1
        let frame = y.map { CGRect(x: x, y: $0, width: 200, height: height) }
        let node = AX.Node(element: AXUIElementCreateApplication(pid_t(975_000 + next)), frame: frame, role: role)
        return Handlers.FieldControl(node: node, role: role, textInput: textInput, inPage: inPage, secure: secure, what: what)
    }

    /// A sign-up form: name, email, country, password, a checkbox, top to bottom.
    lazy var form: [String: Handlers.FieldControl] = [
        "Name": control("AXTextField", y: 60, textInput: true, what: "field \"Name\""),
        "Email": control("AXTextField", y: 100, textInput: true, what: "field \"Email\""),
        "Country": control("AXPopUpButton", y: 140, what: "popup \"Country\""),
        "Password": control("AXTextField", y: 180, textInput: true, secure: true, what: "field \"Password\""),
        "Agree": control("AXCheckBox", y: 220, height: 14, what: "checkbox \"I agree\""),
        "Sign up": control("AXButton", y: 260, what: "button \"Sign up\""),
    ]

    var looked: [String] = []

    /// Looks a key up in `form`: nothing there shows it, as the window's search says.
    func resolve(_ key: String) throws -> Handlers.FieldControl {
        looked.append(key)
        guard let c = form[key] else { throw Handlers.Missing(description: "nothing shows \"\(key)\" in the window") }
        return c
    }

    func plan(_ byLabel: [String: Any], secureAllowed: Bool = false) throws -> [Handlers.FieldStep] {
        try Handlers.planFill(byLabel, secureAllowed: secureAllowed) { try self.resolve($0) }
    }

    /// Each key does what its control takes, and the fields come from the top of the form down.
    func testEachKeyDoesWhatItsControlTakesTopDown() throws {
        let steps = try plan(["Agree": true, "Country": "NZ", "Email": "a@b.c", "Name": "Ada"])
        XCTAssertEqual(steps.map { $0.key }, ["Name", "Email", "Country", "Agree"])
        XCTAssertEqual(steps.map { $0.fill }, [.text("Ada"), .text("a@b.c"), .option("NZ"), .checked(true)])
        XCTAssertTrue(CFEqual(steps[2].node.element, form["Country"]!.node.element))
        // As the list form's fields: what fill then runs.
        let fields = steps.map { $0.fill.field($0.key) }
        XCTAssertEqual(fields.map { $0["target"] as? String }, ["Name", "Email", "Country", "Agree"])
        XCTAssertEqual(fields[2]["option"] as? String, "NZ")
        XCTAssertEqual(fields[3]["checked"] as? Bool, true)
        XCTAssertNil(Handlers.invalid(["type": "fill", "fields": fields]))
    }

    /// A number is typed as its text, or picked as the option of that title.
    func testANumberGoesInAsItsText() throws {
        let steps = try plan(["Email": 42, "Country": 64])
        XCTAssertEqual(steps.map { $0.fill }, [.text("42"), .option("64")])
    }

    /// A key that names nothing stops the plan, named, with every key before it looked up and nothing filled.
    func testAKeyThatNamesNothingStopsBeforeAnythingIsFilled() {
        var filled: [String] = []
        do {
            filled = try plan(["Email": "a@b.c", "Phone": "021 555", "Name": "Ada"]).map { $0.key }  // what fill would go on to do
            XCTFail("the plan should stop")
        } catch {
            XCTAssertEqual("\(error)", "field \"Phone\": nothing shows \"Phone\" in the window")
            XCTAssertFalse("\(error)".contains("021"), "the value isn't repeated")
        }
        XCTAssertEqual(filled, [], "nothing filled")
        XCTAssertEqual(looked, ["Email", "Name", "Phone"], "keys are looked up in a set order")
    }

    /// Several matches for a key stop the plan with the lookup's own list, named by the key.
    func testAKeyNamingSeveralThingsIsNamed() {
        XCTAssertThrowsError(try Handlers.planFill(["Email": "a@b.c"], secureAllowed: false) { key in
            throw HelperError("\"\(key)\" matches 2 elements: [4] field \"Email\"; [9] field \"Email\". Name one by its number, or add role or nth")
        }) { e in
            XCTAssertTrue("\(e)".hasPrefix("field \"Email\": \"Email\" matches 2 elements"), "\(e)")
        }
    }

    /// An element's number written as a key is pointed at the list form.
    func testANumberAsAKeyIsPointedAtTheListForm() {
        XCTAssertThrowsError(try plan(["14": "Ada"])) { e in
            XCTAssertTrue("\(e)".hasSuffix("; to name element 14 by its number, give fields as a list: [{\"element\": 14, …}]"), "\(e)")
        }
    }

    /// A value no control takes stops the plan before anything is looked up.
    func testABadValueStopsBeforeAnyLookup() {
        XCTAssertThrowsError(try plan(["Email": "a@b.c", "Country": ["option": "NZ"]])) { e in
            XCTAssertTrue("\(e)".hasPrefix("field \"Country\" takes text, a number, or true/false"), "\(e)")
        }
        XCTAssertEqual(looked, [])
    }

    /// True or false on a field is an error naming the key.
    func testAFlagOnAFieldIsNamed() {
        XCTAssertThrowsError(try plan(["Name": "Ada", "Email": true])) { e in
            XCTAssertEqual("\(e)", "field \"Email\": that's a field \"Email\": give the text to type, not true or false")
        }
    }

    /// Text for a checkbox or a button is an error that never repeats it (it may be a password meant elsewhere).
    func testTextForACheckboxOrButtonIsNamedNotRepeated() {
        XCTAssertThrowsError(try plan(["Agree": "hunter2"])) { e in
            XCTAssertEqual("\(e)", "field \"Agree\": that's a checkbox \"I agree\": give true or false to tick or untick it")
        }
        XCTAssertThrowsError(try plan(["Sign up": "hunter2"])) { e in
            XCTAssertFalse("\(e)".contains("hunter2"))
            XCTAssertTrue("\(e)".contains("not a field, pop-up or checkbox to fill"), "\(e)")
        }
    }

    /// A password field takes text only where the policy allows typing in them; refused, the value isn't repeated.
    func testAPasswordFieldFollowsThePolicy() throws {
        XCTAssertThrowsError(try plan(["Email": "a@b.c", "Password": "hunter2"])) { e in
            XCTAssertTrue("\(e)".hasPrefix("field \"Password\": not allowed: that's a password field"), "\(e)")
            XCTAssertFalse("\(e)".contains("hunter2"))
        }
        let steps = try plan(["Email": "a@b.c", "Password": "hunter2"], secureAllowed: true)
        XCTAssertEqual(steps.map { $0.fill }, [.text("a@b.c"), .text("hunter2")])
    }

    /// Two keys naming one control would fill it twice: refused.
    func testTwoKeysNamingOneControlAreRefused() {
        form["E-mail"] = form["Email"]
        XCTAssertThrowsError(try plan(["Email": "a@b.c", "E-mail": "a@b.c"])) { e in
            XCTAssertEqual("\(e)", "field \"Email\": it names the same field \"Email\" as field \"E-mail\": give it once")
        }
    }

    /// A control whose place isn't known goes after those whose place is.
    func testAnUnplacedControlGoesLast() throws {
        form["Notes"] = control("AXTextArea", y: nil, textInput: true, what: "textarea \"Notes\"")
        let steps = try plan(["Notes": "hi", "Agree": false, "Name": "Ada"])
        XCTAssertEqual(steps.map { $0.key }, ["Name", "Agree", "Notes"])
    }

    // MARK: - a label names its control

    /// A key may name a form's label: the one fillable control it titles is what's filled (a button it also titles
    /// isn't one). Titling two fillable controls, it names neither, and the plan says the label isn't one control's.
    func testALabelNamesTheOneFillableControlItTitles() {
        func el(_ id: Int) -> AXUIElement { AXUIElementCreateApplication(pid_t(976_000 + id)) }
        let label = el(1), field = el(2), button = el(3), box = el(4), label2 = el(5)
        let roles: [AXUIElement: String] = [label: "AXStaticText", field: "AXTextField", button: "AXButton", box: "AXCheckBox",
                                            label2: "AXStaticText"]
        let serves: [AXUIElement: [AXUIElement]] = [label: [field, button], label2: [field, box]]
        func fits(_ e: AXUIElement) -> Bool { Handlers.fillableRoles.contains(roles[e] ?? "") }
        let found = AX.titled(by: label, fits, role: { roles[$0] }, serves: { serves[$0] ?? [] }, parent: { _ in nil })
        XCTAssertTrue(found.map { CFEqual($0, field) } ?? false)
        XCTAssertNil(AX.titled(by: label2, fits, role: { roles[$0] }, serves: { serves[$0] ?? [] }, parent: { _ in nil }))
        XCTAssertThrowsError(try Handlers.fieldFill(.text("Ada"), role: "AXStaticText", textInput: false, inPage: true,
                                                    what: "text")) { e in
            XCTAssertTrue("\(e)".contains("nor the label of just one"), "\(e)")
        }
    }

    /// The roles a key may name: text inputs, pop-ups and combo boxes, checkboxes and their kin; not a button.
    func testTheRolesAKeyMayName() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXCheckBox",
                     "AXRadioButton", "AXSwitch", "AXToggle"] {
            XCTAssertTrue(Handlers.fillableRoles.contains(role), role)
        }
        for role in ["AXButton", "AXLink", "AXStaticText", "AXGroup", "AXSlider"] {
            XCTAssertFalse(Handlers.fillableRoles.contains(role), role)
        }
    }
}
