import XCTest

@testable import PuterUseHelper

/// The app card's line listing the app's saved macros: names and vars only, nothing when there are none.
final class CardMacrosTests: XCTestCase {
    func entry(_ name: String, _ vars: [String] = []) -> Macros.Entry {
        Macros.Entry(name: name, line: "\(name) (App, 3 steps): does things", vars: vars)
    }

    func testNoMacrosNoLine() {
        XCTAssertNil(AppCards.savedMacros([]))
    }

    func testNamesWithVarsNoSteps() {
        let line = AppCards.savedMacros([entry("export pdf", ["file"]), entry("tidy up"), entry("fill form", ["name", "email"])])
        XCTAssertEqual(line, "saved macros: export pdf (file), tidy up, fill form (name, email)")
    }

    func testLongListAndNamesClipped() {
        let many = (1...11).map { entry("macro \($0)") }
        XCTAssertEqual(AppCards.savedMacros(many),
                       "saved macros: " + (1...8).map { "macro \($0)" }.joined(separator: ", ") + ", +3 more (macros lists all)")
        let long = AppCards.savedMacros([entry(String(repeating: "n", count: 60), (1...12).map { "var\($0)" })])!
        XCTAssertEqual(long, "saved macros: " + String(repeating: "n", count: 27) + "… (var1, var2, var3, var4, var…)")
    }
}
