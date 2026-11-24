import AppKit
import CoreGraphics
import XCTest

@testable import PuterUseHelper

@MainActor
final class FocusPromptTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FocusPrompt.resetForTests()
        Session.current.focusGrant = nil
        Connection.quitting = false
    }

    override func tearDown() {
        FocusPrompt.resetForTests()
        Session.current.focusGrant = nil
        Connection.quitting = false
        super.tearDown()
    }

    // MARK: - settings & eligibility

    func testSettingParsing() {
        XCTAssertTrue(FocusPrompt.setting(nil))
        XCTAssertTrue(FocusPrompt.setting(true))
        XCTAssertFalse(FocusPrompt.setting(false))
        for on in ["when-needed", "", "always", "1", "on", "true", "yes"] {
            XCTAssertTrue(FocusPrompt.setting(on), on)
        }
        for off in ["never", " Never ", "NEVER", "off", "0", "false", "no"] {
            XCTAssertFalse(FocusPrompt.setting(off), off)
        }
    }

    func testShouldPromptKeyboard() {
        XCTAssertTrue(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertTrue(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .switchedIn
        ))
        // Ineligible cases
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: false, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: true, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: true, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 0,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: true, onScreen: true, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: false, heldInput: false, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: true, inCooldown: false, trigger: .otherWindow
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: true, trigger: .otherWindow
        ))
        // keyboardBusy passes trigger: nil, and .frozen is Path B only
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: nil
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptKeyboard(
            enabled: true, quitting: false, foreground: false, wid: 42,
            screenLocked: false, onScreen: true, heldInput: false, inCooldown: false, trigger: .frozen
        ))
    }

    func testStructurallyRevivableAndShouldPromptRevive() {
        XCTAssertTrue(Handlers.structurallyRevivable(
            cover: .covered, onScreen: true, foreground: false, drawsCovered: false, otherAgent: false
        ))
        for cover: Handlers.Cover in [.inView, .minimized, .otherSpace, .hidden] {
            XCTAssertFalse(Handlers.structurallyRevivable(
                cover: cover, onScreen: true, foreground: false, drawsCovered: false, otherAgent: false
            ))
        }
        XCTAssertFalse(Handlers.structurallyRevivable(
            cover: .covered, onScreen: false, foreground: false, drawsCovered: false, otherAgent: false
        ))
        XCTAssertFalse(Handlers.structurallyRevivable(
            cover: .covered, onScreen: true, foreground: true, drawsCovered: false, otherAgent: false
        ))
        XCTAssertFalse(Handlers.structurallyRevivable(
            cover: .covered, onScreen: true, foreground: false, drawsCovered: true, otherAgent: false
        ))
        XCTAssertFalse(Handlers.structurallyRevivable(
            cover: .covered, onScreen: true, foreground: false, drawsCovered: false, otherAgent: true
        ))

        // Even when automatic Forward.forward returns .off / .notOwn / .appInFront / .busy / .fullScreen,
        // shouldPromptRevive evaluates structural prerequisites directly.
        let autoOff = Handlers.forward(
            cover: .covered, owner: .shared, enabled: false, foreground: false, drawsCovered: false,
            onScreen: true, otherAgent: false, sinceLast: nil, appFront: true, quiet: false, frontFullScreen: true
        )
        XCTAssertEqual(autoOff, .off)
        XCTAssertTrue(FocusPrompt.shouldPromptRevive(
            enabled: true, quitting: false, structurallyRevivable: true,
            recently: false, screenLocked: false, inCooldown: false
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptRevive(
            enabled: false, quitting: false, structurallyRevivable: true,
            recently: false, screenLocked: false, inCooldown: false
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptRevive(
            enabled: true, quitting: false, structurallyRevivable: true,
            recently: true, screenLocked: false, inCooldown: false
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptRevive(
            enabled: true, quitting: false, structurallyRevivable: true,
            recently: false, screenLocked: true, inCooldown: false
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptRevive(
            enabled: true, quitting: false, structurallyRevivable: true,
            recently: false, screenLocked: false, inCooldown: true
        ))
        XCTAssertFalse(FocusPrompt.shouldPromptRevive(
            enabled: true, quitting: true, structurallyRevivable: true,
            recently: false, screenLocked: false, inCooldown: false
        ))
    }

    // MARK: - FocusGrant & Run.arrange

    func testFocusGrantLifecycle() {
        let p = Fronts.Presses(keys: 10, clicks: 5)
        var grant = FocusGrant(pid: 100, wid: 200, presses: p, grantedAt: 1000.0)

        // Valid immediately and with mouse drift (extraRevokers excludes mouseMoved)
        XCTAssertFalse(FocusGrant.extraRevokers.contains(.mouseMoved))
        XCTAssertTrue(FocusGrant.extraRevokers.contains(.flagsChanged))
        XCTAssertTrue(FocusGrant.extraRevokers.contains(.otherMouseDown))
        XCTAssertTrue(FocusGrant.extraRevokers.contains(.scrollWheel))

        XCTAssertTrue(grant.isValid(pid: 100, wid: 200, now: 1000.02, presses: p, sinceExtra: 0.01))
        XCTAssertTrue(grant.isValid(pid: 100, wid: 200, now: 1005.0, presses: p, sinceExtra: 10.0))
        XCTAssertTrue(grant.isValid(pid: 100, wid: nil, now: 1005.0, presses: p, sinceExtra: 10.0))

        // Different pid or wid
        XCTAssertFalse(grant.isValid(pid: 101, wid: 200, now: 1005.0, presses: p, sinceExtra: 10.0))
        XCTAssertFalse(grant.isValid(pid: 100, wid: 201, now: 1005.0, presses: p, sinceExtra: 10.0))

        // New key press or click immediately revokes
        XCTAssertFalse(grant.isValid(pid: 100, wid: 200, now: 1001.0, presses: Fronts.Presses(keys: 11, clicks: 5), sinceExtra: 10.0))
        XCTAssertFalse(grant.isValid(pid: 100, wid: 200, now: 1001.0, presses: Fronts.Presses(keys: 10, clicks: 6), sinceExtra: 10.0))

        // Extra revoker event (flagsChanged / otherMouseDown / scrollWheel) after grantedAt revokes
        XCTAssertFalse(grant.isValid(pid: 100, wid: 200, now: 1005.0, presses: p, sinceExtra: 1.0))

        // Expires at maxDuration (60 s)
        XCTAssertFalse(grant.isValid(pid: 100, wid: 200, now: 1060.0, presses: p, sinceExtra: 100.0))

        // Explicit revoked flag
        grant.revoked = true
        XCTAssertFalse(grant.isValid(pid: 100, wid: 200, now: 1001.0, presses: p, sinceExtra: 10.0))
    }

    func testRunArrangeExcludesApproveClickWithValidGrant() {
        let withoutGrant = Run.arrange(launching: false, front: true, userPressed: true, userTyped: false)
        XCTAssertTrue(withoutGrant.users)
        XCTAssertFalse(withoutGrant.fit)
        XCTAssertFalse(withoutGrant.place)
        XCTAssertFalse(withoutGrant.follow)

        let withGrant = Run.arrange(launching: false, front: true, userPressed: false, userTyped: false)
        XCTAssertFalse(withGrant.users)
        XCTAssertTrue(withGrant.fit)
        XCTAssertTrue(withGrant.place)
        XCTAssertTrue(withGrant.follow)

        // Setting a fresh FocusGrant for pid 777 causes validFocusGrant(pid: 777, wid: nil) to succeed
        // (and after wid transfer, matches the new wid too).
        let now = ProcessInfo.processInfo.systemUptime
        Session.current.focusGrant = FocusGrant(pid: 777, wid: 10, presses: Input.userPresses(), grantedAt: now)
        if Run.sinceUser(FocusGrant.extraRevokers) >= 0.05 {
            XCTAssertTrue(Handlers.validFocusGrant(pid: 777, wid: nil))
            XCTAssertTrue(Handlers.validFocusGrant(pid: 777, wid: 10))
            XCTAssertFalse(Handlers.validFocusGrant(pid: 777, wid: 11))
            Session.current.focusGrant?.wid = 11
            XCTAssertTrue(Handlers.validFocusGrant(pid: 777, wid: 11))
        }
    }

    // MARK: - anti-spoofing, copy, & placement

    func testSanitizeTitleStripsBidiControlsAndSeparators() {
        // RLO (\u{202E}), ZWSP (\u{200B}), BEL (\u{0007}), newline, paragraph separator (\u{2029}), PUA (\u{E000})
        let evil = "\u{202E}Bank\u{200B}\u{0007}\nLogin\u{2029}Page\u{E000}\t\tNow"
        XCTAssertEqual(FocusPrompt.sanitizeTitle(evil), "Bank Login Page Now")

        // Clips long titles
        let long = String(repeating: "a", count: 60)
        let clipped = FocusPrompt.sanitizeTitle(long, limit: 20)
        XCTAssertEqual(clipped.count, 20)
        XCTAssertTrue(clipped.hasSuffix("…"))

        // Isolated title wraps in FSI..PDI and returns "" if nothing printable remains
        XCTAssertEqual(FocusPrompt.isolatedTitle("Docs"), "\u{2068}Docs\u{2069}")
        XCTAssertEqual(FocusPrompt.isolatedTitle("\u{202E}\u{200B}  \n"), "")
    }

    func testCopyForTriggersOwnersAndActions() {
        func makeReq(trigger: FocusPrompt.Trigger, owner: Owner, action: String, front: Bool = true) -> FocusPrompt.Request {
            FocusPrompt.Request(
                pid: 1, wid: 244, app: "Firefox", title: "GitHub \u{202E}spoof",
                targetOwner: owner, keyWid: 250, keyTitle: "Inbox", keyOwner: .user,
                trigger: trigger, action: action, front: front, sessionOrdinal: 0, anchorFrame: nil
            )
        }

        let other = FocusPrompt.copy(for: makeReq(trigger: .otherWindow, owner: .agent, action: "type"))
        XCTAssertEqual(other.approveLabel, "Switch Window")
        XCTAssertTrue(other.headline.contains("Switch Firefox to"))
        XCTAssertFalse(other.headline.contains("\u{202E}"))
        XCTAssertTrue(other.detail.contains("agent's window"))
        XCTAssertTrue(other.detail.contains("to type"))
        XCTAssertTrue(other.detail.contains("Inbox"))

        let switched = FocusPrompt.copy(for: makeReq(trigger: .switchedIn, owner: .shared, action: "paste"))
        XCTAssertEqual(switched.approveLabel, "Allow")
        XCTAssertTrue(switched.headline.contains("Allow typing"))
        XCTAssertTrue(switched.detail.contains("shared window"))
        XCTAssertTrue(switched.detail.contains("to paste"))

        let frozen = FocusPrompt.copy(for: makeReq(trigger: .frozen, owner: .user, action: "redraw", front: false))
        XCTAssertEqual(frozen.approveLabel, "Switch Window")
        XCTAssertTrue(frozen.detail.contains("paused drawing"))
        XCTAssertTrue(frozen.detail.contains("your window"))
        XCTAssertFalse(frozen.detail.contains("while you're in"))

        XCTAssertEqual(FocusPrompt.actionPhrase("menu"), "to run a menu command")
        XCTAssertEqual(FocusPrompt.actionPhrase("fill"), "to fill a form")
        XCTAssertEqual(FocusPrompt.actionPhrase("navigate"), "to navigate")
        XCTAssertEqual(FocusPrompt.actionPhrase("click"), "for a modifier click")
    }

    func testPanelFrameMultiMonitorAndFullScreen() {
        let size = CGSize(width: 368, height: 130)
        // Primary: 1440x900 with 25pt menu bar (visible maxY = 875).
        // Secondary to the right: 1920x1080 full-screen (visible maxY == frame maxY = 1080).
        let primary = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                       visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let secondary = (frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
                         visible: CGRect(x: 1440, y: -180, width: 1920, height: 1080))
        let screens = [primary, secondary]

        // Anchor on primary (CG top-left y=100..500 -> AppKit y=400..800) -> 16pt top inset
        let onPrimary = FocusPrompt.panelFrame(
            size: size, anchorCG: CGRect(x: 200, y: 100, width: 800, height: 400),
            screens: screens, primaryHeight: 900, mouseAppKit: nil
        )
        XCTAssertEqual(onPrimary.maxX, 1440 - 16)
        XCTAssertEqual(onPrimary.maxY, 875 - 16)

        // Anchor on secondary (CG x=1600, y=50..650 -> AppKit y=250..850) -> full-screen 48pt top inset
        let onSecondary = FocusPrompt.panelFrame(
            size: size, anchorCG: CGRect(x: 1600, y: 50, width: 1000, height: 600),
            screens: screens, primaryHeight: 900, mouseAppKit: nil
        )
        XCTAssertEqual(onSecondary.maxX, 1440 + 1920 - 16)
        XCTAssertEqual(onSecondary.maxY, 900 - 48)

        // Nil anchor falls back to mouse screen
        let byMouse = FocusPrompt.panelFrame(
            size: size, anchorCG: nil, screens: screens, primaryHeight: 900,
            mouseAppKit: CGPoint(x: 2000, y: 400)
        )
        XCTAssertEqual(byMouse.maxX, 1440 + 1920 - 16)
    }

    // MARK: - cooldowns, error wording & frozenRemedy

    func testCooldownsAndDedicatedErrors() {
        FocusPrompt.recordDecline(pid: 10, now: 100)
        FocusPrompt.recordTimeout(pid: 20, now: 100)

        XCTAssertEqual(FocusPrompt.activeCooldown(pid: 10, now: 159), .declined)
        XCTAssertNil(FocusPrompt.activeCooldown(pid: 10, now: 160))
        XCTAssertEqual(FocusPrompt.activeCooldown(pid: 20, now: 144), .timedOut)
        XCTAssertNil(FocusPrompt.activeCooldown(pid: 20, now: 145))

        FocusPrompt.recordDecline(pid: 30, now: 200)
        FocusPrompt.clearCooldown(pid: 30)
        XCTAssertNil(FocusPrompt.activeCooldown(pid: 30, now: 201))

        let decErr = FocusPrompt.declinedKeyboardError(
            app: "Firefox", wid: 244, title: "Docs", targetOwner: .agent, keyDesc: "#250 \"Inbox\""
        )
        XCTAssertTrue(decErr.contains("declined switching Firefox"))
        XCTAssertTrue(decErr.contains("Don't retry right now"))
        XCTAssertTrue(decErr.contains("Clicks without keys still reach #244"))

        let toErr = FocusPrompt.timedOutKeyboardError(
            app: "Firefox", wid: 244, title: "Docs", targetOwner: .agent, keyDesc: nil, seconds: 30
        )
        XCTAssertTrue(toErr.contains("within 30 s"))
        XCTAssertTrue(toErr.contains("Don't retry right away"))

        let cdErr = FocusPrompt.cooldownKeyboardError(app: "Firefox", wid: 244, reason: .declined)
        XCTAssertTrue(cdErr.contains("recently declined"))
        XCTAssertTrue(cdErr.contains("Don't retry right now"))

        // Frozen declined suppresses the "ask the user / activate" nudge
        var f = Handlers.Frozen(unread: true, cover: .covered, key: false, notForward: "the user declined switching to #244", declined: true)
        let declinedRemedy = Handlers.frozenRemedy(f, app: "Firefox", wid: 244)
        XCTAssertTrue(declinedRemedy.contains("don't retry right now"))
        XCTAssertFalse(declinedRemedy.contains("activate"))
        let declinedErr = Handlers.frozenError(f, app: "Firefox", wid: 244)
        XCTAssertTrue(declinedErr.contains("declined"))
        XCTAssertTrue(declinedErr.contains("Don't retry right now"))
        XCTAssertFalse(declinedErr.contains("activate"))

        f.declined = false
        let normalRemedy = Handlers.frozenRemedy(f, app: "Firefox", wid: 244)
        XCTAssertTrue(normalRemedy.contains("activate"))
    }

    // MARK: - async FIFO gate, promptWait delta, test guard & cancelAll

    func testHeadlessXCTestGuardReturnsUnavailable() async {
        FocusPrompt.presenter = nil
        let req = FocusPrompt.Request(
            pid: 1, wid: 2, app: "Firefox", title: "Test", targetOwner: .agent,
            keyWid: 3, keyTitle: "Other", keyOwner: .user, trigger: .otherWindow,
            action: "type", front: true, sessionOrdinal: 0, anchorFrame: nil
        )
        let outcome = await FocusPrompt.ask(req) { nil }
        XCTAssertEqual(outcome, .unavailable)
    }

    func testFIFOGateSerializesAndPromptWaitAccrues() async throws {
        var order: [String] = []
        FocusPrompt.presenter = { req, _, _ in
            order.append("start-\(req.wid)")
            try? await Task.sleep(nanoseconds: 120_000_000)
            order.append("end-\(req.wid)")
            return .declined
        }
        let conn = Connection(fd: -1, key: nil)
        let req1 = FocusPrompt.Request(
            pid: 55, wid: 1, app: "Firefox", title: "A", targetOwner: .agent,
            keyWid: 9, keyTitle: "U", keyOwner: .user, trigger: .otherWindow,
            action: "type", front: true, sessionOrdinal: 0, anchorFrame: nil
        )
        let req2 = FocusPrompt.Request(
            pid: 55, wid: 2, app: "Firefox", title: "B", targetOwner: .agent,
            keyWid: 9, keyTitle: "U", keyOwner: .user, trigger: .otherWindow,
            action: "type", front: true, sessionOrdinal: 1, anchorFrame: nil
        )

        var sawCooldownOnSecond = false
        try await Connection.$current.withValue(conn) {
            let first = Task { @MainActor in
                try await FocusPrompt.acquireGate()
                defer { FocusPrompt.releaseGate() }
                let out = await FocusPrompt.ask(req1) { nil }
                if out == .declined { FocusPrompt.recordDecline(pid: req1.pid) }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            let second = Task { @MainActor in
                try await FocusPrompt.acquireGate()
                defer { FocusPrompt.releaseGate() }
                if FocusPrompt.activeCooldown(pid: req2.pid) == .declined {
                    sawCooldownOnSecond = true
                    return
                }
                _ = await FocusPrompt.ask(req2) { nil }
            }
            try await first.value
            try await second.value
        }
        // Task 1 ran to completion before Task 2 entered the gate, and Task 2 suppressed its popup via cooldown.
        XCTAssertEqual(order, ["start-1", "end-1"])
        XCTAssertTrue(sawCooldownOnSecond)
        XCTAssertGreaterThanOrEqual(conn.promptWait, 0.1)
    }

    func testQuittingCancelsGateAndAskImmediately() async {
        Connection.quitting = true
        do {
            try await FocusPrompt.acquireGate()
            XCTFail("expected Cancelled when Connection.quitting is true")
        } catch {
            XCTAssertTrue(error is Cancelled)
        }
        let req = FocusPrompt.Request(
            pid: 1, wid: 2, app: "Firefox", title: "A", targetOwner: .agent,
            keyWid: 3, keyTitle: "U", keyOwner: .user, trigger: .otherWindow,
            action: "type", front: true, sessionOrdinal: 0, anchorFrame: nil
        )
        let out = await FocusPrompt.ask(req) { nil }
        XCTAssertEqual(out, .cancelled)
    }

    func testMainRouteUnwrapsPopupRoute() {
        let win = WinInfo(id: 42, pid: 100, app: "Firefox", title: "Docs",
                          frame: CGRect(x: 10, y: 20, width: 800, height: 600), layer: 0, onScreen: true)
        let popup = Route(pid: 100, wid: 999, frame: CGRect(x: 50, y: 50, width: 100, height: 100),
                          foreground: false, primer: false)
        let unwrapped = Handlers.mainRoute(.window(win), popup)
        XCTAssertEqual(unwrapped.wid, 42)
        XCTAssertEqual(unwrapped.pid, 100)
        XCTAssertTrue(unwrapped.primer)
    }

    func testWorkPromptCancelledGuard() {
        var w = Work()
        XCTAssertFalse(w.promptCancelled)
        w.promptCancelled = true
        let preSideEffect = w.promptCancelled && w.fields == nil && w.typed == 0 && w.did.isEmpty
        XCTAssertTrue(preSideEffect)
        w.typed = 3
        let afterTyping = w.promptCancelled && w.fields == nil && w.typed == 0 && w.did.isEmpty
        XCTAssertFalse(afterTyping)
    }
}
