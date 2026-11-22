import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// What keeps browser forms from stopping or going wrong: no stop for the user's OK on a press that only sets
/// something (a checkbox "Send me updates"), while a button still stops; a click aimed at a field that a pop-up
/// (a suggestions or saved-data list) lies over isn't let land in the pop-up; the coordinate guard's words for a
/// pop-up; and the key-window error, which says to wait and not to work around it.
@MainActor
final class BrowserFixesTests: XCTestCase {
    // MARK: - the confirm stop

    /// Checkboxes, switches, radio buttons, disclosure triangles and text inputs never ask; buttons, links, menu
    /// items and anything else may.
    func testOnlyPressesThatCommitAsk() {
        for role in ["AXCheckBox", "AXSwitch", "AXToggle", "AXRadioButton", "AXDisclosureTriangle", "AXTextField", "AXTextArea",
                     "AXComboBox", "AXSearchField"] {
            XCTAssertFalse(Policy.asksOK(role: role), role)
        }
        for role in ["AXButton", "AXLink", "AXMenuItem", "AXStaticText", "AXPopUpButton", "AXCell", "AXImage", ""] {
            XCTAssertTrue(Policy.asksOK(role: role), role)
        }
    }

    /// A checkbox named "Send me updates" (or "Save my information … pay faster") is ticked with no OK; a button
    /// "Send" still stops, and so does one named only by the text in it.
    func testACheckboxWithARiskyLabelDoesntStopButAButtonDoes() throws {
        try XCTSkipUnless(Policy.config.confirm.contains("send") && Policy.config.confirm.contains("pay"),
                          "the user's policy file has no \"send\"/\"pay\" confirm")
        func node(_ role: String, _ label: String?, shown: String? = nil) -> AX.Node {
            AX.Node(element: AXUIElementCreateApplication(931_001), frame: nil, role: role, label: label, name: "x", shown: shown)
        }
        XCTAssertNoThrow(try Policy.checkPress(["type": "click"], node: node("AXCheckBox", "Send me updates"), at: nil, pid: 931_001))
        XCTAssertNoThrow(try Policy.checkPress(["type": "click"], node: node("AXCheckBox", "Save my information to pay faster"),
                                               at: nil, pid: 931_001))
        XCTAssertNoThrow(try Policy.checkPress(["type": "click"], node: node("AXRadioButton", "Send later"), at: nil, pid: 931_001))
        XCTAssertNoThrow(try Policy.checkPress(["type": "click"], node: node("AXTextField", "Post title"), at: nil, pid: 931_001))
        XCTAssertThrowsError(try Policy.checkPress(["type": "click"], node: node("AXButton", "Send"), at: nil, pid: 931_001)) {
            XCTAssertTrue($0 is Policy.NeedsOK)
        }
        XCTAssertThrowsError(try Policy.checkPress(["type": "click"], node: node("AXButton", nil, shown: "Pay now"), at: nil,
                                                   pid: 931_001)) { XCTAssertTrue($0 is Policy.NeedsOK) }
        XCTAssertNoThrow(try Policy.checkPress(["type": "click", "confirm": true], node: node("AXButton", "Send"), at: nil, pid: 931_001))
    }

    // MARK: - a pop-up over the field a click is aimed at

    /// A click routed to a menu-level window over the target, for an element in the target window, would land in
    /// that pop-up; not when it routes to the target, nor for an element in the pop-up, a sheet or a panel, nor for
    /// one whose window isn't known.
    func testAPopupOverTheAimedElementIsCaught() {
        XCTAssertTrue(Handlers.popupCovers(routedTo: 9, target: 5, layer: 101, elementWindow: 5), "a suggestions list over the field")
        XCTAssertFalse(Handlers.popupCovers(routedTo: 5, target: 5, layer: 0, elementWindow: 5), "nothing over it")
        XCTAssertFalse(Handlers.popupCovers(routedTo: 9, target: 5, layer: 101, elementWindow: 9), "the element is in the pop-up")
        XCTAssertFalse(Handlers.popupCovers(routedTo: 9, target: 5, layer: 0, elementWindow: 5), "a sheet or dialog: as before")
        XCTAssertFalse(Handlers.popupCovers(routedTo: 9, target: 5, layer: 3, elementWindow: 5), "a floating panel: as before")
        XCTAssertFalse(Handlers.popupCovers(routedTo: 9, target: 5, layer: 101, elementWindow: nil), "its window isn't known")
        XCTAssertFalse(Handlers.popupCovers(routedTo: 9, target: 5, layer: nil, elementWindow: 5), "the pop-up is gone")
    }

    /// Menu and pop-up layers (Firefox draws its lists at 101) are the ones Escape closes; not windows, panels, the
    /// menu bar's or the system's overlays.
    func testPopupLayers() {
        XCTAssertTrue(Run.popupLayer(101))
        XCTAssertTrue(Run.popupLayer(100))
        XCTAssertFalse(Run.popupLayer(0))
        XCTAssertFalse(Run.popupLayer(3))
        XCTAssertFalse(Run.popupLayer(25))
        XCTAssertFalse(Run.popupLayer(1000))
        XCTAssertTrue(Run.onlyPopups([101, 101]))
        XCTAssertFalse(Run.onlyPopups([101, 0]), "a sheet came too")
        XCTAssertFalse(Run.onlyPopups([101, nil]))
        XCTAssertFalse(Run.onlyPopups([]))
    }

    // MARK: - the key-window error

    /// It says what happened, to wait and retry, not to work around it (and how one would), and that clicks
    /// without keys still go: everything the agent needs is in the error itself.
    func testTheKeyWindowErrorSaysWhatToDo() {
        let what = "another window of Firefox has the keyboard (window #12, not the agent's #34), so the action didn't run: "
            + "keys and menu commands would act there"
        let e = Handlers.keyboardElsewhere(what, app: "Firefox", wait: "it's back in #34", wid: 34).description
        XCTAssertTrue(e.hasPrefix("another window of Firefox has the keyboard"))
        XCTAssertTrue(e.contains("wait until it's back in #34, then retry"))
        XCTAssertTrue(e.contains("don't work around it (no foreground, activate or click to take the keyboard)"))
        XCTAssertTrue(e.hasSuffix("Clicks without keys still reach #34"))
    }
}
