import CoreGraphics
import XCTest

@testable import PuterUseHelper

final class ComboKeyTests: XCTestCase {
    /// `checkShortcuts` only looks up a menu command for a combo with "cmd" in it: every name that presses
    /// Command must read as "cmd", or a risky shortcut sent as super+… skips the confirmation.
    func testEveryCommandNameIsCmd() {
        for name in ["cmd", "command", "⌘", "meta", "super", "win", "windows", "Super_L", "Meta_R"] {
            XCTAssertEqual(AX.comboKey("\(name)+shift+e"), ["cmd", "shift", "e"], name)
        }
    }

    /// Whatever `Keys` presses as a modifier, `comboKey` names the same way.
    func testComboKeyAgreesWithKeysModifiers() {
        let names: [(CGEventFlags, String)] = [
            (.maskCommand, "cmd"), (.maskShift, "shift"), (.maskControl, "ctrl"), (.maskAlternate, "option"),
            (.maskSecondaryFn, "fn"),
        ]
        for (name, flag) in Keys.modifiers {
            let want = names.first { $0.0 == flag }!.1
            XCTAssertEqual(AX.comboKey(name), [want], name)
        }
    }
}
