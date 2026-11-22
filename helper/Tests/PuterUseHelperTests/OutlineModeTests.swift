import XCTest

@testable import PuterUseHelper

/// After a screenshot without an image (the window's outline), an act that isn't told about a picture
/// returns what changed in the outline and no image, until the outline can't stand in for one.
final class OutlineModeTests: XCTestCase {
    /// `screenshot` absent (or null) is "not told": the window's view mode decides. Given, as ever: false is
    /// "never", true "auto", and with always_image "always".
    func testTheActsScreenshotModeHasThreeStates() {
        XCTAssertNil(Handlers.shotMode([:]))
        XCTAssertNil(Handlers.shotMode(["screenshot": NSNull()]))
        XCTAssertEqual(Handlers.shotMode(["screenshot": false]), .never)
        XCTAssertEqual(Handlers.shotMode(["screenshot": true]), .auto)
        XCTAssertEqual(Handlers.shotMode(["screenshot": true, "always_image": false]), .auto)
        XCTAssertEqual(Handlers.shotMode(["screenshot": true, "always_image": true]), .always)
        XCTAssertEqual(Handlers.shotMode(["always_image": true]), .always, "asking for an image always is telling")
        XCTAssertEqual(Handlers.shotMode(["screenshot": false, "always_image": true]), .never, "never wins, as before")
        let json = try! JSONSerialization.jsonObject(with: Data(#"{"a": {"screenshot": true}, "b": {"screenshot": false}}"#.utf8))
            as! [String: [String: Any]]
        XCTAssertEqual(Handlers.shotMode(json["a"]!), .auto)
        XCTAssertEqual(Handlers.shotMode(json["b"]!), .never)
    }

    /// A look without an image switches the window to its outline (interactive or not, as asked); one with an
    /// image, a zoom too, back to pictures. Reading an element or a region's text changes nothing.
    func testWhatAScreenshotDoesToTheViewMode() {
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: [:]), .visual)
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: ["image": true]), .visual)
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: ["region": [10, 10, 200, 100]]), .visual, "a zoom is a picture")
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: ["image": false, "text": true]), .outline(interactive: false))
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: ["image": false, "text": true, "interactive": true]),
                       .outline(interactive: true))
        XCTAssertNil(Handlers.viewMode(afterScreenshot: ["image": false, "region": [10, 10, 200, 100]]), "a region's text")
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: ["image": false, "region": [10, 10]]), .outline(interactive: false),
                       "a region that isn't one is the whole window's outline, as the look returns")
        XCTAssertNil(Handlers.viewMode(afterScreenshot: ["read": 12, "image": false]))
        XCTAssertNil(Handlers.viewMode(afterScreenshot: ["read": "Notes"]))
        XCTAssertEqual(Handlers.viewMode(afterScreenshot: ["read": false, "image": false]), .outline(interactive: false))
    }

    /// Going by the outline: only when not told about a picture and the agent's last look had no image. Its
    /// kind is the one the agent last had, unless the act asks for an outline itself.
    func testWhenAnActGoesByTheOutline() {
        let full = ViewMode.outline(interactive: false), short = ViewMode.outline(interactive: true)
        XCTAssertEqual(Handlers.outlineKind(given: nil, mode: full, [:]), false)
        XCTAssertEqual(Handlers.outlineKind(given: nil, mode: short, [:]), true)
        XCTAssertEqual(Handlers.outlineKind(given: nil, mode: full, ["text": true, "interactive": true]), true)
        XCTAssertEqual(Handlers.outlineKind(given: nil, mode: short, ["text": true]), false)
        XCTAssertNil(Handlers.outlineKind(given: nil, mode: .visual, [:]), "pictures")
        XCTAssertNil(Handlers.outlineKind(given: nil, mode: nil, [:]), "never looked: pictures")
        for told in [Handlers.ShotMode.never, .auto, .always] {
            XCTAssertNil(Handlers.outlineKind(given: told, mode: full, [:]), "told: as told")
        }
    }

    /// How the batch ended can call for the window rather than its outline: a failure, a stop (before an
    /// action aimed by position, or for the user's OK: a press that can't be undone is looked at), or a move
    /// to another window. Otherwise nothing does.
    func testWhatInTheBatchShowsTheWindow() {
        XCTAssertNil(Handlers.outlineEscalation(failed: false, stopped: false, confirm: false, moved: false))
        XCTAssertNotNil(Handlers.outlineEscalation(failed: true, stopped: false, confirm: false, moved: false))
        let guardStop = Handlers.outlineEscalation(failed: false, stopped: true, confirm: false, moved: false)
        let okStop = Handlers.outlineEscalation(failed: false, stopped: true, confirm: true, moved: false)
        XCTAssertNotNil(guardStop)
        XCTAssertNotNil(okStop)
        XCTAssertNotEqual(guardStop, okStop)
        XCTAssertTrue(okStop!.contains("OK"))
        XCTAssertNotNil(Handlers.outlineEscalation(failed: false, stopped: false, confirm: false, moved: true))
    }

    /// A stop for the user's OK with the window as the agent last saw it sends no image (as "auto" would): the note
    /// saying why there's no outline goes too, so it doesn't promise a picture; the other notes stay, in order.
    func testAnEscalationsNoteGoesWhenNoImageIsSent() {
        let okStop = "no outline this time: " + Handlers.outlineEscalation(failed: false, stopped: true, confirm: true, moved: false)!
        XCTAssertEqual(Handlers.dropping(okStop, from: ["closed a menu", okStop, "the text cursor moved"]),
                       ["closed a menu", "the text cursor moved"])
        XCTAssertEqual(Handlers.dropping(okStop, from: [okStop]), [])
        XCTAssertEqual(Handlers.dropping(okStop, from: ["closed a menu"]), ["closed a menu"])
    }

    /// The outline stands in for a picture only when it shows the window: not with no tree, nothing in it,
    /// a walk cut short, or one past its length cap.
    func testWhenTheOutlineCantStandInForAPicture() {
        let outline = "[1] button \"Save\"\n[2] field \"Name\" =\"Ann\""
        XCTAssertNil(Handlers.outlineProblem(outline, interactive: false, cutShort: false))
        XCTAssertNil(Handlers.outlineProblem(outline, interactive: true, cutShort: false))
        XCTAssertNotNil(Handlers.outlineProblem(nil, interactive: false, cutShort: false))
        XCTAssertNotNil(Handlers.outlineProblem("", interactive: false, cutShort: false))
        XCTAssertNotNil(Handlers.outlineProblem("", interactive: true, cutShort: false))
        XCTAssertNotNil(Handlers.outlineProblem(outline, interactive: false, cutShort: true))
        let capped = outline + "\n… (truncated; zoom with region or use a screenshot)"
        XCTAssertNotNil(Handlers.outlineProblem(capped, interactive: false, cutShort: false))
    }

    /// The length cap's line ends the outline, or comes just before the cut-short one.
    func testAnOutlinePastItsCapIsSeen() {
        let lines = "[1] button \"Save\"\n[2] text \"… (truncated in the middle of a label\""
        XCTAssertFalse(Handlers.outlineTruncated(lines), "a label that says it isn't the cap's line")
        XCTAssertTrue(Handlers.outlineTruncated("[1] button \"Save\"\n… (truncated; zoom with region or use a screenshot)"))
        XCTAssertTrue(Handlers.outlineTruncated("[1] button \"Save\"\n… (truncated; zoom with region or use a screenshot)\n"
            + "… (outline cut short: the app answered slowly; look again later or use a screenshot)"))
        XCTAssertFalse(Handlers.outlineTruncated(""))
    }
}
