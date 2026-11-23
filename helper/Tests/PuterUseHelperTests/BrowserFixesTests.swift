import ApplicationServices
import XCTest

@testable import PuterUseHelper

/// What keeps browser forms from stopping or going wrong: no stop for the user's OK on a press that only sets
/// something (a checkbox "Send me updates"), while a button still stops; a click aimed at a field that a pop-up
/// (a suggestions or saved-data list) lies over isn't let land in the pop-up; the coordinate guard's words for a
/// pop-up; and the key-window error, which says when it clears (or that it won't), and not to take the keyboard.
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

    /// In the user's front app: they're in it, so it clears when they leave; not to take the keyboard from them
    /// (and how one would), and that clicks without keys still go. The window is named as the one the action is
    /// for, with whose it is.
    func testTheKeyWindowErrorInTheUsersFrontAppSaysItClearsWhenTheyLeave() {
        let p = Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .agent, key: 12, keyTitle: "YouTube", front: true)
        let e = Handlers.keyboardRefusal(p)
        XCTAssertEqual(e, "the user is in Firefox (their window #12 \"YouTube\" has the keyboard), so the action didn't run: "
            + "keys and menu commands would act there, not in #34, the window this action is for (yours). This clears when "
            + "they leave Firefox; or ask them. Don't take the keyboard from them (no foreground, activate or a click just "
            + "to move it). Clicks without keys still reach #34")
        let unknown = Handlers.keyboardRefusal(Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .user, key: nil,
                                                                          front: true))
        XCTAssertTrue(unknown.hasPrefix("the user is in Firefox, and which of its windows has the keyboard can't be told"))
        XCTAssertTrue(unknown.contains("not in #34, the window this action is for (the user's)"))
    }

    /// In the background the keyboard never comes back by itself: don't retry, ask the user. Unless the agent's own
    /// window wasn't tried yet: a new call moves it there.
    func testTheKeyWindowErrorInTheBackgroundSaysNotToRetry() {
        let e = Handlers.keyboardRefusal(Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .agent, key: 12,
                                                                    front: false))
        XCTAssertEqual(e, "Firefox's keyboard is on the user's window #12, and it won't move by itself, so the action didn't "
            + "run: keys and menu commands would act there, not in #34, the window this action is for (yours). Don't retry: "
            + "ask the user to click into #34. Clicks without keys still reach #34")
        let untried = Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .agent, key: 12, front: false, tried: false)
        XCTAssertTrue(untried.advice.hasPrefix("Run it again in a new call: that moves the keyboard to #34 while Firefox is in the background"))
        let theirs = Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .user, key: 12, front: false, tried: false)
        XCTAssertTrue(theirs.advice.hasPrefix("Don't retry: ask the user to click into #34"), "never moved to the user's window")
        let used = Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .agent, key: 12, keyTitle: "Docs",
                                              keyOwner: .shared, front: false)
        XCTAssertEqual(used.why, "Firefox's keyboard is on your window #12 \"Docs\", which the user has used, and it won't move by itself")
        let usedFront = Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .shared, key: 12, keyOwner: .shared, front: true)
        XCTAssertEqual(usedFront.why, "the user is in Firefox (your window #12, which the user has used, has the keyboard)")
        XCTAssertTrue(usedFront.effect.hasSuffix("(yours, used by the user)"))
    }

    /// The user came into the app just as the act moved its keyboard to the agent's window: stop, as they may type there.
    func testTheUserSwitchingInAsTheKeyboardMovedStopsTheKeys() {
        let e = Handlers.keyboardRefusal(Handlers.keyboardSwitchedIn(app: "Firefox", target: 34, from: 12))
        XCTAssertEqual(e, "the user switched to Firefox after its keyboard was moved off their #12, so the action didn't run: "
            + "their keys would go to #34, the window this action is for (yours), too. This clears when they leave Firefox; "
            + "or ask them")
    }

    /// The third refusal of keys for a window within 3 minutes says to stop retrying; older ones don't count.
    func testRefusalsAreCountedOverThreeMinutes() {
        var times: [TimeInterval] = []
        for t in [0.0, 60, 120] { times = Handlers.refusals(times, now: t) }
        XCTAssertEqual(times.count, 3)
        XCTAssertEqual(Handlers.refusalNote(times.count), "Refused 3 times in 3 minutes: stop retrying and ask the user")
        XCTAssertNil(Handlers.refusalNote(2))
        XCTAssertEqual(Handlers.refusals(times, now: 200), [60, 120, 200], "the first is over 3 minutes old")
        XCTAssertEqual(Handlers.refusals([0, 10], now: 500), [500])
        XCTAssertEqual(Handlers.refusalNote(4), "Refused 4 times in 3 minutes: stop retrying and ask the user")
    }

    /// The counter is the session's, per window, and its note goes on the refusal itself.
    func testARefusalCarriesTheCount() {
        let s = Session(id: "refusal-count-test", ordinal: 3)
        Session.$current.withValue(s) {
            let r = Route(pid: 1, wid: 77, frame: .zero)
            XCTAssertEqual(Handlers.refused(r, "no").description, "no")
            XCTAssertEqual(Handlers.refused(r, "no").description, "no")
            XCTAssertEqual(Handlers.refused(r, "no").description, "no. Refused 3 times in 3 minutes: stop retrying and ask the user")
            XCTAssertEqual(Handlers.refused(Route(pid: 1, wid: 78, frame: .zero), "no").description, "no", "another window")
        }
    }

    /// From the third refusal on, the note to stop retrying takes the place of the part that says to try again, so
    /// the two never disagree; a refusal without one gets the note at its end.
    func testTheThirdRefusalDoesntAlsoSayTryAgain() {
        let busy = Handlers.keyboardBusy(app: "Firefox", target: 34)
        XCTAssertEqual(Handlers.refusalText(busy.text, retry: busy.retry, count: 1), busy.text)
        XCTAssertEqual(Handlers.refusalText(busy.text, retry: busy.retry, count: 3),
                       "the user is in Firefox and its keyboard is on your window #34: they may be typing there, so the action "
                           + "didn't run. Refused 3 times in 3 minutes: stop retrying and ask the user")
        let retry = "Try again in a few seconds, or work in #12"
        let own = Handlers.refusalText("your other window #12 has Firefox's keyboard. The action didn't run. \(retry)", retry: retry,
                                       count: 4)
        XCTAssertFalse(own.contains("Try again"), own)
        XCTAssertTrue(own.hasSuffix("The action didn't run. Refused 4 times in 3 minutes: stop retrying and ask the user"), own)
        // In the background, before the keyboard was moved: "run it again" gives way too; what clicks do stays.
        let untried = Handlers.keyboardRefusal(Handlers.keyboardElsewhere(app: "Firefox", target: 34, targetOwner: .agent, key: 12,
                                                                          front: false, tried: false))
        let third = Handlers.refusalText(untried, retry: Handlers.keyboardRetry(app: "Firefox", target: 34), count: 3)
        XCTAssertFalse(third.contains("Run it again"), third)
        XCTAssertTrue(third.hasSuffix("Refused 3 times in 3 minutes: stop retrying and ask the user. Clicks without keys still "
            + "reach #34"), third)
        XCTAssertEqual(Handlers.refusalText("no", retry: "Try again", count: 3),
                       "no. Refused 3 times in 3 minutes: stop retrying and ask the user", "nothing to replace")
    }

    /// Keys into the agent's window that has its app's keyboard wait while that app is the user's front app and they've
    /// touched the keyboard or mouse in the last moments: it's the window they're in. Not while they're quiet, not in
    /// the background, not in foreground mode, and not for a window of the user's (as ever).
    func testKeysWaitWhileTheUserMayBeTypingInTheAgentsWindow() {
        func waits(foreground: Bool = false, front: Bool = true, owner: Owner = .agent, quiet: Bool = false) -> Bool {
            Handlers.waitsForUser(foreground: foreground, front: front, targetOwner: owner, quiet: quiet)
        }
        XCTAssertTrue(waits())
        XCTAssertTrue(waits(owner: .shared), "one they've used, too")
        XCTAssertFalse(waits(quiet: true), "they've left the keyboard and mouse alone")
        XCTAssertFalse(waits(front: false), "the app is in the background")
        XCTAssertFalse(waits(foreground: true))
        XCTAssertFalse(waits(owner: .user))
        XCTAssertEqual(Handlers.keyboardBusy(app: "Firefox", target: 34).text,
                       "the user is in Firefox and its keyboard is on your window #34: they may be typing there, so the action "
                           + "didn't run. Try again once they've left the keyboard for a moment")
    }

    /// The refusal of keys counts toward the third, with its own "try again" replaced then.
    func testTheUserBusyRefusalIsCounted() {
        let s = Session(id: "refusal-busy-test", ordinal: 3)
        Session.$current.withValue(s) {
            let r = Route(pid: 1, wid: 79, frame: .zero)
            let busy = Handlers.keyboardBusy(app: "Firefox", target: 79)
            _ = Handlers.refused(r, "no")
            _ = Handlers.refused(r, busy.text, retry: busy.retry)
            XCTAssertTrue(Handlers.refused(r, busy.text, retry: busy.retry).description.hasSuffix(
                "they may be typing there, so the action didn't run. Refused 3 times in 3 minutes: stop retrying and ask the user"))
        }
    }

    /// An error reply carries the notes the call found about the agent's windows, each a sentence after it.
    func testAnErrorCarriesTheOwnerNotes() {
        XCTAssertEqual(Handlers.withNotes("no window for Foo", []), "no window for Foo")
        XCTAssertEqual(Handlers.withNotes("nothing was typed.", ["#7 now shows \"Docs\" (changed since your last call)"]),
                       "nothing was typed. #7 now shows \"Docs\" (changed since your last call)")
        XCTAssertEqual(Handlers.withNotes("no", ["#7 was yours", "#8 now shows \"A\""]), "no. #7 was yours. #8 now shows \"A\"")
    }
}
