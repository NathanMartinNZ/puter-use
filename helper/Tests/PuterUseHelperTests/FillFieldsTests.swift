import CoreGraphics
import Foundation
import XCTest

@testable import PuterUseHelper

/// fill's fields as an object of labels and values, {"Email": "a@b.c", "Country": "NZ", "Agree": true}: what a value
/// is (true or false, text, a number as its text), what it does to the control its key names (ticks a checkbox, picks
/// a pop-up's option, types into a field), the order the fields are filled in, and the check before the batch runs.
/// The list form ({target | element, text | option | checked}) reads as it always has.
@MainActor
final class FillFieldsTests: XCTestCase {
    /// A request's params as the helper reads them.
    func decoded(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - values

    /// JSON's true and false are a checkbox's; 1 and 0 are numbers, typed as their text. Text is text.
    func testJSONTrueIsAFlagAndOneIsANumber() {
        let f = decoded(#"{"Agree": true, "Off": false, "Age": 1, "Zero": 0, "Price": 2.5, "Qty": 5.0, "Email": "a@b.c"}"#)
        XCTAssertEqual(f["Agree"].flatMap { Handlers.fieldValue($0) }, .flag(true))
        XCTAssertEqual(f["Off"].flatMap { Handlers.fieldValue($0) }, .flag(false))
        XCTAssertEqual(f["Age"].flatMap { Handlers.fieldValue($0) }, .text("1"), "JSON 1 isn't true")
        XCTAssertEqual(f["Zero"].flatMap { Handlers.fieldValue($0) }, .text("0"), "JSON 0 isn't false")
        XCTAssertEqual(f["Price"].flatMap { Handlers.fieldValue($0) }, .text("2.5"))
        XCTAssertEqual(f["Qty"].flatMap { Handlers.fieldValue($0) }, .text("5"))
        XCTAssertEqual(f["Email"].flatMap { Handlers.fieldValue($0) }, .text("a@b.c"))
    }

    /// Values written in Swift (a saved macro's, a test's) read the same.
    func testSwiftValuesReadTheSame() {
        XCTAssertEqual(Handlers.fieldValue(true), .flag(true))
        XCTAssertEqual(Handlers.fieldValue(false), .flag(false))
        XCTAssertEqual(Handlers.fieldValue(5), .text("5"))
        XCTAssertEqual(Handlers.fieldValue(-3), .text("-3"))
        XCTAssertEqual(Handlers.fieldValue(2.5), .text("2.5"))
        XCTAssertEqual(Handlers.fieldValue(""), .text(""), "empty text empties a field, as the list form's does")
        XCTAssertEqual(Handlers.fieldValue("NZ"), .text("NZ"))
    }

    /// Null, a list or an object is no value the object form sets.
    func testNullListsAndObjectsAreNoValue() {
        let f = decoded(#"{"N": null, "L": [1, 2], "O": {"option": "NZ"}}"#)
        for k in ["N", "L", "O"] { XCTAssertNil(f[k].flatMap { Handlers.fieldValue($0) }, k) }
        XCTAssertNil(Handlers.fieldValue(NSNull()))
        XCTAssertNil(Handlers.fieldValue(["option": "NZ"]))
        XCTAssertNil(Handlers.fieldValue(["a", "b"]))
    }

    /// A number goes in as its digits: a whole one without ".0", any other as written.
    func testANumbersText() {
        XCTAssertEqual(Handlers.numberText(NSNumber(value: 42)), "42")
        XCTAssertEqual(Handlers.numberText(NSNumber(value: -7)), "-7")
        XCTAssertEqual(Handlers.numberText(NSNumber(value: 5.0)), "5")
        XCTAssertEqual(Handlers.numberText(NSNumber(value: 0.1)), "0.1")
        XCTAssertEqual(Handlers.numberText(NSNumber(value: 12.75)), "12.75")
        XCTAssertEqual(Handlers.numberText(NSDecimalNumber(string: "12.50")), "12.5")
        XCTAssertEqual(Handlers.numberText(NSNumber(value: Int64(9_007_199_254_740_993))), "9007199254740993", "a long id stays whole")
    }

    // MARK: - the check before the batch runs

    /// The object form passes the key check, with or without submit and confirm, and so does an empty object (fill
    /// itself says it needs fields).
    func testTheObjectFormPassesTheKeyCheck() {
        let forms: [[String: Any]] = [
            ["type": "fill", "fields": ["Email": "a@b.c", "Country": "NZ", "Agree": true]],
            ["type": "fill", "fields": ["Email": "a@b.c", "Age": 30], "submit": "Sign up", "confirm": true],
            ["type": "fill", "fields": ["Message": "hi"], "submit": true],
            ["type": "fill", "fields": ["Name": "Ada"], "submit": 9],
            decoded(#"{"type": "fill", "fields": {"Email": "a@b.c", "Country": "NZ", "Agree": true}, "submit": "Sign up"}"#),
        ]
        for a in forms { XCTAssertNil(Handlers.invalid(a), "\(a)") }
    }

    /// A value the object form can't set stops the batch before anything runs, named by its key, never repeated
    /// (it may be a password), with the list form for saying more.
    func testAValueItCantSetIsNamedByItsKey() {
        let why = Handlers.invalid(["type": "fill", "fields": ["Email": "a@b.c", "Country": ["option": "NZ"]]]) ?? ""
        XCTAssertTrue(why.hasPrefix("field \"Country\" takes text, a number, or true/false"), why)
        XCTAssertTrue(why.contains("give fields as a list: [{\"target\": …, \"text\": …}]"), why)
        XCTAssertNotNil(Handlers.invalid(["type": "fill", "fields": ["Notes": NSNull()]]))
        let secret = Handlers.invalid(["type": "fill", "fields": ["Password": ["hunter2"]]]) ?? ""
        XCTAssertTrue(secret.hasPrefix("field \"Password\""), secret)
        XCTAssertFalse(secret.contains("hunter2"), "a value is never repeated")
        XCTAssertEqual(Handlers.invalid(["type": "fill", "fields": ["  ": "x"]]),
                       "has a field with no label: each key is the text that names a field")
    }

    /// The list form passes as it did, and its fields are key-checked as they were.
    func testTheListFormPassesAsBefore() {
        let forms: [[String: Any]] = [
            ["type": "fill", "fields": [["target": "Email", "text": "a@b.c"], ["element": 5, "option": "NZ"],
                                        ["target": "Agree", "checked": true], ["target": "Name", "text": "Ada", "clear": false]],
             "submit": "Send"],
            ["type": "fill", "fields": [["element": 3, "value": "Ada"], ["element": 4, "select": "Blue", "confirm": true]],
             "submit": true, "confirm": true],
            ["type": "fill", "fields": [["target": ["text": "Name", "role": "field", "nth": 2], "text": "Ada"]]],
        ]
        for a in forms { XCTAssertNil(Handlers.invalid(a), "\(a)") }
        XCTAssertEqual(Handlers.invalid(["type": "fill", "fields": [["target": "Name", "text": "Ada"], ["target": "Email", "txt": "a@b"]]]),
                       "field 2 has an unknown key \"txt\" (did you mean text?): a field takes element, target, text, option, checked, clear")
    }

    /// A fill's submit clicks as it did: an element by number (JSON 1 too, which isn't true), a button by its text, a
    /// saved macro's {target, x, y, units}; true is a Return, not a click.
    func testTheSubmitClickIsAsBefore() {
        XCTAssertEqual(Handlers.fillSubmitClick(["submit": 9]).flatMap { Handlers.num($0["element"]) }, 9)
        XCTAssertEqual(Handlers.fillSubmitClick(decoded(#"{"submit": 1}"#)).flatMap { Handlers.num($0["element"]) }, 1)
        XCTAssertNil(Handlers.fillSubmitClick(decoded(#"{"submit": true}"#)))
        XCTAssertNil(Handlers.fillSubmitClick(["submit": true]))
        XCTAssertNil(Handlers.fillSubmitClick([:]))
        XCTAssertEqual(Handlers.fillSubmitClick(["submit": "Send"])?["target"] as? String, "Send")
        XCTAssertEqual(Handlers.fillSubmitClick(["submit": "Send"])?["type"] as? String, "click")
        let saved = Handlers.fillSubmitClick(["submit": ["target": "Go", "x": 10, "y": 20, "units": "pt"]])
        XCTAssertEqual(saved?["type"] as? String, "click")
        XCTAssertEqual(saved?["units"] as? String, "pt")
        XCTAssertEqual(saved?["target"] as? String, "Go")
    }

    // MARK: - what a value does, by the control's kind

    /// True or false ticks or unticks a checkbox, radio button or switch.
    func testAFlagSetsAToggle() throws {
        for role in ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"] {
            XCTAssertEqual(try Handlers.fieldFill(.flag(true), role: role, textInput: false, inPage: false, what: "checkbox"),
                           .checked(true), role)
            XCTAssertEqual(try Handlers.fieldFill(.flag(false), role: role, textInput: false, inPage: true, what: "checkbox"),
                           .checked(false), role)
        }
    }

    /// Text picks an option of a pop-up (a web page's `<select>` too), a menu button or a native combo box.
    func testTextPicksAPopUpsOption() throws {
        XCTAssertEqual(try Handlers.fieldFill(.text("NZ"), role: "AXPopUpButton", textInput: false, inPage: false, what: "popup"),
                       .option("NZ"))
        XCTAssertEqual(try Handlers.fieldFill(.text("NZ"), role: "AXPopUpButton", textInput: false, inPage: true, what: "popup"),
                       .option("NZ"), "a web page's <select>")
        XCTAssertEqual(try Handlers.fieldFill(.text("Large"), role: "AXMenuButton", textInput: false, inPage: false, what: "menubutton"),
                       .option("Large"))
        XCTAssertEqual(try Handlers.fieldFill(.text("12"), role: "AXComboBox", textInput: true, inPage: false, what: "combo"),
                       .option("12"), "a native combo box: its option, or its text if it lists none")
    }

    /// Text is typed into a field, a text area or a search field, and into a web page's combo box (a field with
    /// suggestions there).
    func testTextIsTypedIntoAField() throws {
        for role in ["AXTextField", "AXTextArea", "AXSearchField"] {
            XCTAssertEqual(try Handlers.fieldFill(.text("Ada"), role: role, textInput: true, inPage: false, what: "field"),
                           .text("Ada"), role)
        }
        XCTAssertEqual(try Handlers.fieldFill(.text("Wellington"), role: "AXComboBox", textInput: true, inPage: true, what: "combo"),
                       .text("Wellington"))
    }

    /// A number is its text: typed into a field, or the option of that title.
    func testANumberIsItsText() throws {
        let five = try XCTUnwrap(Handlers.fieldValue(5))
        XCTAssertEqual(try Handlers.fieldFill(five, role: "AXTextField", textInput: true, inPage: true, what: "field"), .text("5"))
        XCTAssertEqual(try Handlers.fieldFill(five, role: "AXPopUpButton", textInput: false, inPage: true, what: "popup"), .option("5"))
    }

    /// True or false on a field or a pop-up is an error that says what it takes.
    func testAFlagOnAFieldIsAnError() {
        XCTAssertThrowsError(try Handlers.fieldFill(.flag(true), role: "AXTextField", textInput: true, inPage: false,
                                                    what: "field \"Email\"")) { e in
            XCTAssertEqual("\(e)", "that's a field \"Email\": give the text to type, not true or false")
        }
        XCTAssertThrowsError(try Handlers.fieldFill(.flag(false), role: "AXPopUpButton", textInput: false, inPage: false,
                                                    what: "popup \"Country\"")) { e in
            XCTAssertEqual("\(e)", "that's a popup \"Country\": give the option to pick, not true or false")
        }
    }

    /// Text on a checkbox, or anything on a button or a bare label, is an error that never repeats the value.
    func testTextOnAToggleOrAButtonIsAnErrorThatKeepsTheValue() {
        XCTAssertThrowsError(try Handlers.fieldFill(.text("hunter2"), role: "AXCheckBox", textInput: false, inPage: false,
                                                    what: "checkbox \"Show password\"")) { e in
            XCTAssertEqual("\(e)", "that's a checkbox \"Show password\": give true or false to tick or untick it")
            XCTAssertFalse("\(e)".contains("hunter2"))
        }
        XCTAssertThrowsError(try Handlers.fieldFill(.text("hunter2"), role: "AXButton", textInput: false, inPage: false,
                                                    what: "button \"Go\"")) { e in
            XCTAssertEqual("\(e)", "that's a button \"Go\", not a field, pop-up or checkbox to fill")
        }
        XCTAssertThrowsError(try Handlers.fieldFill(.flag(true), role: "AXStaticText", textInput: false, inPage: true,
                                                    what: "text")) { e in
            XCTAssertTrue("\(e)".hasPrefix("that's a text, not a field, pop-up or checkbox to fill (nor the label of just one)"), "\(e)")
        }
    }

    /// Each field becomes the list form's own field, which passes its key check: what api.py sends for a dict too.
    func testEachFieldIsTheListFormsField() {
        let cases: [(Handlers.FieldFill, [String: Any])] = [
            (.text("Ada"), ["target": "Name", "text": "Ada"]),
            (.option("NZ"), ["target": "Name", "option": "NZ"]),
            (.checked(true), ["target": "Name", "checked": true]),
        ]
        for (fill, want) in cases {
            let field = fill.field("Name")
            XCTAssertEqual(NSDictionary(dictionary: field), NSDictionary(dictionary: want))
            XCTAssertNil(Handlers.invalid(["type": "fill", "fields": [field]]), "\(field)")
        }
    }

    // MARK: - order

    /// Fields are filled as a person fills the form: rows from the top down, each left to right, whatever order the
    /// object's keys came in.
    func testFieldsGoTopDownThenLeftToRight() {
        let items: [(key: String, frame: CGRect?)] = [
            ("Agree", CGRect(x: 20, y: 300, width: 14, height: 14)),
            ("Phone", CGRect(x: 320, y: 100, width: 200, height: 22)),
            ("Name", CGRect(x: 20, y: 100, width: 200, height: 22)),
            ("Country", CGRect(x: 20, y: 200, width: 150, height: 22)),
            ("Email", CGRect(x: 20, y: 150, width: 200, height: 22)),
        ]
        XCTAssertEqual(Handlers.fillOrder(items), ["Name", "Phone", "Email", "Country", "Agree"])
        XCTAssertEqual(Handlers.fillOrder(items.reversed()), ["Name", "Phone", "Email", "Country", "Agree"], "whatever order")
    }

    /// Controls of different heights side by side are one row, read left to right: their middles a little apart.
    func testControlsSideBySideAreOneRow() {
        let items: [(key: String, frame: CGRect?)] = [
            ("Subscribe", CGRect(x: 260, y: 104, width: 14, height: 14)),  // middle 111
            ("Zip", CGRect(x: 20, y: 100, width: 200, height: 22)),  // middle 111
            ("City", CGRect(x: 300, y: 101, width: 120, height: 22)),  // middle 112
            ("Notes", CGRect(x: 20, y: 140, width: 400, height: 80)),
        ]
        XCTAssertEqual(Handlers.fillOrder(items), ["Zip", "Subscribe", "City", "Notes"])
    }

    /// Those whose place isn't known go last, by key; ties go by key, so the order is always the same.
    func testUnplacedGoLastAndTiesGoByKey() {
        let same = CGRect(x: 20, y: 100, width: 200, height: 22)
        let items: [(key: String, frame: CGRect?)] = [
            ("b", nil), ("Z", same), ("a", nil), ("Y", same), ("Top", CGRect(x: 500, y: 10, width: 50, height: 20)),
        ]
        XCTAssertEqual(Handlers.fillOrder(items), ["Top", "Y", "Z", "a", "b"])
        XCTAssertEqual(Handlers.fillOrder([]), [])
    }

    // MARK: - messages

    /// A stop partway says which fields were filled: by number in the list form, by label in the object form.
    func testAStopPartwayNamesWhatWasFilled() {
        XCTAssertEqual(Handlers.filledSoFar(2, labels: nil), "fields 1-2 were")
        XCTAssertEqual(Handlers.filledSoFar(1, labels: ["Email", "Name"]), "field \"Email\" was")
        XCTAssertEqual(Handlers.filledSoFar(2, labels: ["Email", "Name", "Agree"]), "fields \"Email\", \"Name\" were")
        XCTAssertEqual(Handlers.filledSoFar(3, labels: ["Email", "Name", "Agree"]), "all 3 fields were")
        XCTAssertEqual(Handlers.fieldName("Email"), "field \"Email\"")
    }

    /// Only typing into a field opens a suggestions list: the fill closes one (and says so) only after a field it typed
    /// into, never after a pop-up's option or a checkbox (the object form {"Name": …, "Color": "Green", "Subscribe":
    /// true, "Size": …} said it closed one before "Subscribe", which was ticked).
    func testOnlyAFieldTypedIntoCanLeaveASuggestionsList() {
        let fields = Handlers.FieldFill.text("Ada Lovelace").field("Name")
        XCTAssertTrue(Handlers.typesText(fields))
        XCTAssertTrue(Handlers.typesText(["element": 3, "value": "Ada"]))
        XCTAssertFalse(Handlers.typesText(Handlers.FieldFill.option("Green").field("Color")))
        XCTAssertFalse(Handlers.typesText(Handlers.FieldFill.checked(true).field("Subscribe")))
        XCTAssertFalse(Handlers.typesText(["target": "Size", "select": "Large"]))
        XCTAssertFalse(Handlers.typesText(["target": "Size", "option": "Large", "text": "Large"]), "an option wins, as fill reads it")
        XCTAssertFalse(Handlers.typesText(decoded(#"{"target": "Agree", "checked": false}"#)))
        XCTAssertTrue(Handlers.typesText(decoded(#"{"target": "Age", "text": "42"}"#)))
        XCTAssertFalse(Handlers.typesText(["target": "Age"]), "nothing to type")
    }
}
