import AppKit
import XCTest

@testable import PuterUseHelper

/// Where the policy lets the agent click but not type, fill's fields as an object of labels and values
/// ({"Email": "a@b.c", "Agree": true}) are judged before the batch runs, as the list form's are: any text or number is
/// typing (typed into a field or picked from a pop-up, which only the controls its labels name say, once it runs);
/// true and false only tick and untick, as the list form's checked does (`Policy.typing`).
@MainActor
final class FillObjectPolicyTests: XCTestCase {
    /// A request's action as the helper reads it.
    func decoded(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// Text or a number among the object form's values is typing, beside true and false too. 1 and 0 are numbers, not
    /// true and false. A value fill can't set (null) isn't taken for a toggle either.
    func testTextOrANumberInTheObjectFormIsTyping() {
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": ["Email": "a@b.c", "Agree": true]]))
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": ["Country": "NZ"], "submit": "Sign up"]))
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": ["Age": 30]]))
        XCTAssertTrue(Policy.typing(["action": "Fill", "fields": ["Name": ""]]))
        XCTAssertTrue(Policy.typing(decoded(#"{"type": "fill", "fields": {"Email": "a@b.c", "Agree": true}, "submit": "Sign up"}"#)))
        XCTAssertTrue(Policy.typing(decoded(#"{"type": "fill", "fields": {"Count": 1}}"#)), "JSON 1 isn't true")
        XCTAssertTrue(Policy.typing(decoded(#"{"type": "fill", "fields": {"Off": 0}}"#)), "JSON 0 isn't false")
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": ["Notes": NSNull()]]))
    }

    /// True and false alone only tick and untick, as the list form's checked: not typing, unless the fill submits with
    /// Return, which is a key in either form.
    func testTrueAndFalseAloneAreTogglesAsChecked() {
        let toggles: [String: Any] = ["type": "fill", "fields": ["Agree": true, "Newsletter": false]]
        XCTAssertFalse(Policy.typing(toggles))
        XCTAssertFalse(Policy.typing(decoded(#"{"type": "fill", "fields": {"Agree": true, "Newsletter": false}}"#)))
        XCTAssertFalse(Policy.typing(["type": "fill", "fields": ["Agree": true], "submit": "Sign up"]))
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": ["Agree": true], "submit": true]))
        let checked: [String: Any] = ["type": "fill", "fields": [["target": "Agree", "checked": true],
                                                                ["target": "Newsletter", "checked": false]]]
        XCTAssertEqual(Policy.typing(toggles), Policy.typing(checked))
        XCTAssertEqual(Policy.typing(["type": "fill", "fields": ["Agree": true], "submit": true]),
                       Policy.typing(["type": "fill", "fields": [["target": "Agree", "checked": true]], "submit": true]))
        XCTAssertFalse(Policy.typing(["type": "fill", "fields": [String: Any]()]), "an empty object (fill says it needs fields)")
    }

    /// The list form is judged as it was: text or value is typing, an option or checked isn't, a Return submit is.
    func testTheListFormIsJudgedAsBefore() {
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": [["element": 3, "text": "Ada"]]]))
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": [["element": 3, "value": "Ada"], ["element": 5, "option": "Blue"]]]))
        XCTAssertFalse(Policy.typing(["type": "fill", "fields": [["element": 5, "option": "Blue"]], "submit": "Save"]))
        XCTAssertFalse(Policy.typing(["type": "fill", "fields": [["target": "Agree", "checked": true]]]))
        XCTAssertTrue(Policy.typing(["type": "fill", "fields": [["element": 5, "option": "Blue"]], "submit": true]))
        XCTAssertTrue(Policy.typing(["type": "type", "text": "Ada"]))
        XCTAssertTrue(Policy.typing(["type": "menu", "item": "File > Save"]))
        XCTAssertFalse(Policy.typing(["type": "click", "target": "Save"]))
    }

    /// In an app the policy lets the agent only click in (a terminal, by default), a batch with an object fill that has
    /// text is refused before any of it runs, the fill named, with the list form's option for a pop-up; one whose
    /// values are all true or false isn't, nor is a list form with only options and checks, as before.
    func testRefusedBeforeTheBatchRunsWhereTheAgentMayOnlyClick() throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && Policy.level($0.processIdentifier) == .click
        }) else {
            throw XCTSkip("no app the policy lets agents only click in is running")
        }
        let pid = app.processIdentifier
        let click: [String: Any] = ["type": "click", "target": "New"]
        let byText: [String: Any] = ["type": "fill", "fields": ["Email": "a@b.c", "Agree": true], "submit": "Sign up"]
        let why = try XCTUnwrap(Handlers.refusal([click, byText], from: 0, pid: pid, base: 0))
        XCTAssertTrue(why.hasPrefix("action 2 (fill): not allowed"), why)
        XCTAssertTrue(why.contains("[{\"target\": …, \"option\": …}]"), why)
        XCTAssertFalse(why.contains("a@b.c"), "a value is never repeated")
        XCTAssertThrowsError(try Policy.checkAction(byText, pid: pid))
        XCTAssertThrowsError(try Policy.checkAction(["type": "fill", "fields": ["Age": 30]], pid: pid))

        let toggles: [String: Any] = ["type": "fill", "fields": ["Agree": true, "Newsletter": false], "submit": "Sign up"]
        XCTAssertNil(Handlers.refusal([click, toggles], from: 0, pid: pid, base: 0))
        XCTAssertNotNil(Handlers.refusal([click, ["type": "fill", "fields": ["Agree": true], "submit": true]], from: 0, pid: pid, base: 0))

        XCTAssertNil(Handlers.refusal([click, ["type": "fill", "fields": [["target": "Colour", "option": "Blue"],
                                                                           ["target": "Agree", "checked": true]]]],
                                      from: 0, pid: pid, base: 0))
        let listed = Handlers.refusal([click, ["type": "fill", "fields": [["target": "Email", "text": "a@b.c"]]]], from: 0, pid: pid, base: 0)
        XCTAssertTrue(listed?.hasPrefix("action 2 (fill): not allowed") == true, listed ?? "")
        XCTAssertFalse(listed?.contains("\"option\"") == true, "the list form's refusal is as it was")
    }
}
