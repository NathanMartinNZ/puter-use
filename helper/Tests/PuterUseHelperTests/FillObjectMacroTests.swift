import Foundation
import XCTest

@testable import PuterUseHelper

/// A fill whose fields are an object of labels and values ({"Email": "a@b.c", "Agree": true}), saved as a macro with
/// vars: a var's value among its text values becomes `{{var}}`, as in the list form's text and option; its keys
/// (which name the fields, as a target does), true, false and numbers stay as they are. It comes back from the saved
/// file (keys sorted) as it went in, and a replay puts the value given in (`Macros.fill`).
@MainActor
final class FillObjectMacroTests: XCTestCase {
    /// Steps as the act loop saves them: recorded before each runs (`Macros.record`), the vars put in
    /// (`Macros.templated`), then written and read back as a macro's file is.
    func saved(_ steps: [[String: Any]], vars: [String: String]) throws -> (steps: [[String: Any]], used: [String]) {
        let recorded = steps.map { Macros.ran(Macros.record(Handlers.external($0), .screen), menu: nil) }
        let (templated, used) = Macros.templated(recorded, vars: vars)
        let data = try JSONSerialization.data(withJSONObject: ["steps": templated], options: [.prettyPrinted, .sortedKeys])
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (try XCTUnwrap(back["steps"] as? [[String: Any]]), used)
    }

    func isFlag(_ v: Any?) -> Bool { v.map { CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() } ?? false }

    /// A recorded object fill with a var, replayed with another value: that value goes in, the rest as saved.
    func testAVarInTheObjectFormIsReplayedWithTheValueGiven() throws {
        let fill: [String: Any] = ["type": "fill", "fields": ["Email": "ada@example.com", "Country": "New Zealand", "Agree": true],
                                   "submit": "Sign up", "confirm": true]
        let (steps, used) = try saved([fill], vars: ["email": "ada@example.com"])
        XCTAssertEqual(used, ["email"])
        let step = try XCTUnwrap(steps.first)
        XCTAssertNil(step["confirm"], "the user's OK was for that time")
        XCTAssertEqual(step["submit"] as? String, "Sign up")
        XCTAssertFalse(Macros.positional(step), "its labels find its fields: no saved place")
        let fields = try XCTUnwrap(step["fields"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["Email", "Country", "Agree"])
        XCTAssertEqual(fields["Email"] as? String, "{{email}}")
        XCTAssertEqual(fields["Country"] as? String, "New Zealand")

        let replay = try XCTUnwrap(Macros.fill(step, ["email": "grace@example.com"]) as? [String: Any])
        let filled = try XCTUnwrap(replay["fields"] as? [String: Any])
        XCTAssertEqual(filled["Email"] as? String, "grace@example.com")
        XCTAssertEqual(filled["Country"] as? String, "New Zealand")
        XCTAssertTrue(isFlag(filled["Agree"]), "true is still true, not text")
        XCTAssertEqual(filled["Agree"] as? Bool, true)
        XCTAssertEqual(replay["submit"] as? String, "Sign up")
    }

    /// True, false and numbers are kept as they are, even when a var's value reads as them; a key isn't a var's place
    /// (it names the field); a short value is a var only as the whole of a value, a longer one wherever it appears.
    func testTogglesNumbersAndKeysStayAsTheyAre() throws {
        let fill: [String: Any] = ["type": "fill", "fields": ["Agree": true, "Newsletter": false, "Age": 30, "Country": "NZ",
                                                             "Note": "for Ada Lovelace", "Code": "NZ-1"]]
        let (steps, used) = try saved([fill], vars: ["agree": "true", "age": "30", "label": "Country", "country": "NZ",
                                                     "who": "Ada Lovelace"])
        XCTAssertEqual(used, ["country", "who"])
        let fields = try XCTUnwrap(steps.first?["fields"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["Agree", "Newsletter", "Age", "Country", "Note", "Code"])
        XCTAssertTrue(isFlag(fields["Agree"]))
        XCTAssertEqual(fields["Agree"] as? Bool, true)
        XCTAssertTrue(isFlag(fields["Newsletter"]))
        XCTAssertEqual(fields["Newsletter"] as? Bool, false)
        XCTAssertNil(fields["Age"] as? String, "a number stays a number")
        XCTAssertFalse(isFlag(fields["Age"]))
        XCTAssertEqual((fields["Age"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual(fields["Country"] as? String, "{{country}}")
        XCTAssertEqual(fields["Code"] as? String, "NZ-1", "a value of 2 characters only as the whole of one")
        XCTAssertEqual(fields["Note"] as? String, "for {{who}}")

        let replay = try XCTUnwrap(Macros.fill(steps[0], ["country": "AU", "who": "Grace Hopper"]) as? [String: Any])
        let filled = try XCTUnwrap(replay["fields"] as? [String: Any])
        XCTAssertEqual(filled["Country"] as? String, "AU")
        XCTAssertEqual(filled["Note"] as? String, "for Grace Hopper")
        XCTAssertEqual(filled["Agree"] as? Bool, true)
        XCTAssertEqual(filled["Newsletter"] as? Bool, false)
        XCTAssertTrue(isFlag(filled["Newsletter"]))
        XCTAssertEqual((filled["Age"] as? NSNumber)?.intValue, 30)
        XCTAssertFalse(isFlag(filled["Age"]))
        XCTAssertEqual(Set(filled.keys), ["Agree", "Newsletter", "Age", "Country", "Note", "Code"])
    }

    /// With no vars, the object fill comes back from the saved file just as it was given.
    func testTheObjectFormRoundTrips() throws {
        let fields: [String: Any] = ["Email": "ada@example.com", "Country": "NZ", "Agree": true, "Age": 30]
        let (steps, used) = try saved([["type": "fill", "fields": fields, "submit": "Sign up"]], vars: [:])
        XCTAssertEqual(used, [])
        XCTAssertEqual(try XCTUnwrap(steps.first) as NSDictionary,
                       ["type": "fill", "fields": fields, "submit": "Sign up"] as NSDictionary)
    }

    /// The list form is saved and replayed as before: its text and option take vars, its targets and checked don't.
    func testTheListFormIsAsBefore() throws {
        let fill: [String: Any] = ["type": "fill", "fields": [["target": "Email", "text": "ada@example.com"],
                                                             ["target": "Colour", "option": "Blue"],
                                                             ["target": "Agree", "checked": true]]]
        let (steps, used) = try saved([fill], vars: ["email": "ada@example.com", "colour": "Blue", "field": "Agree"])
        XCTAssertEqual(used, ["colour", "email"])
        let fields = try XCTUnwrap(steps.first?["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields[0]["target"] as? String, "Email")
        XCTAssertEqual(fields[0]["text"] as? String, "{{email}}")
        XCTAssertEqual(fields[1]["option"] as? String, "{{colour}}")
        XCTAssertEqual(fields[2]["target"] as? String, "Agree", "a target isn't a var's place")
        XCTAssertTrue(isFlag(fields[2]["checked"]))

        let replay = try XCTUnwrap(Macros.fill(steps[0], ["email": "grace@example.com", "colour": "Green"]) as? [String: Any])
        let filled = try XCTUnwrap(replay["fields"] as? [[String: Any]])
        XCTAssertEqual(filled[0]["text"] as? String, "grace@example.com")
        XCTAssertEqual(filled[1]["option"] as? String, "Green")
        XCTAssertEqual(filled[2]["checked"] as? Bool, true)
    }
}
