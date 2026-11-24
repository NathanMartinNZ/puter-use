import AppKit
import ApplicationServices

/// User-approved temporary focus grant on window `wid` of app `pid`, issued right after clicking Approve
/// on a focus prompt: prevents post-click HID recoil and mouse drift from falsely triggering `userAtKeys`
/// or `Run.arrange` while immediately revoking on any real user key press, click, modifier key, scroll,
/// or app switch.
struct FocusGrant: Equatable {
    var pid: pid_t
    var wid: CGWindowID
    let presses: Fronts.Presses
    let grantedAt: TimeInterval  // system uptime
    var revoked = false

    nonisolated static let maxDuration: TimeInterval = 60
    /// Extra HID event types (beyond `Input.userPresses()`) that revoke a grant when fired after `grantedAt`.
    nonisolated static var extraRevokers: [CGEventType] { [.flagsChanged, .otherMouseDown, .scrollWheel] }

    /// Whether this grant still covers `pid` (and `wid`, when given) at uptime `now`, given the current
    /// `presses` count and the minimum seconds since any `extraRevokers` event (`sinceExtra`).
    nonisolated func isValid(pid: pid_t, wid: CGWindowID?, now: TimeInterval, presses: Fronts.Presses,
                             sinceExtra: Double) -> Bool {
        guard !revoked, self.pid == pid else { return false }
        if let wid, self.wid != wid { return false }
        let elapsed = now - grantedAt
        guard elapsed >= -0.05, elapsed < Self.maxDuration else { return false }
        guard presses == self.presses else { return false }
        // Tiny 0.05 s margin for the Approve click's own button release / event delivery.
        return sinceExtra >= max(0, elapsed - 0.05)
    }

    nonisolated func matches(pid: pid_t, wid: CGWindowID) -> Bool {
        self.pid == pid && self.wid == wid
    }
}

/// Native non-activating macOS HUD popup asking the user to approve or decline switching focus to the
/// agent's target window when the user is active in another window of the same app (or when a covered
/// window needs to come forward to redraw).
///
/// Non-activating (`NSPanel` with `.nonactivatingPanel`, `canBecomeKey = false`): never steals keyboard
/// focus while waiting, so typing in the active app never accidentally clicks Approve or Decline.
@MainActor
enum FocusPrompt {
    nonisolated static let defaultTimeout: TimeInterval = 30
    nonisolated static let declineCooldown: TimeInterval = 60
    nonisolated static let timeoutCooldown: TimeInterval = 45
    nonisolated static let clickGrace: TimeInterval = 0.4

    enum Trigger: Equatable {
        case otherWindow  // another window of the app has the keyboard
        case switchedIn  // user switched into the app after background keyboard move
        case frozen  // covered window stopped drawing and auto-flash couldn't run
    }

    enum CooldownReason: Equatable {
        case declined
        case timedOut
    }

    struct Request: Equatable {
        let pid: pid_t
        let wid: CGWindowID
        let app: String  // display name, e.g. "Firefox" or "Firefox (agent)"
        let title: String
        let targetOwner: Owner
        let keyWid: CGWindowID?
        let keyTitle: String
        let keyOwner: Owner
        let trigger: Trigger
        let action: String
        let front: Bool
        let sessionOrdinal: Int
        let anchorFrame: CGRect?  // CG top-left frame of user's active window (for display selection)
    }

    enum Outcome: Equatable {
        case approved(presses: Fronts.Presses, at: TimeInterval)
        case declined
        case timedOut
        case clearedBackground
        case clearedFocused
        case clearedInView
        case windowGone
        case cancelled
        case unavailable
    }

    // MARK: - pure decisions & copy (unit-tested)

    /// Whether `focus_prompt` setting enables the popup: on by default unless explicitly off.
    nonisolated static func setting(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        return !["never", "off", "0", "false", "no"].contains(s)
    }

    /// Whether a keyboard conflict is eligible to show the focus prompt.
    nonisolated static func shouldPromptKeyboard(enabled: Bool, quitting: Bool, foreground: Bool, wid: CGWindowID,
                                                 screenLocked: Bool, onScreen: Bool, heldInput: Bool,
                                                 inCooldown: Bool, trigger: Trigger?) -> Bool {
        guard enabled, !quitting, !foreground, wid != 0, !screenLocked, onScreen, !heldInput, !inCooldown,
              let trigger else { return false }
        return trigger == .otherWindow || trigger == .switchedIn
    }

    /// Whether a frozen covered window (that automatic `Forward.forward` did not flash) is eligible to prompt.
    nonisolated static func shouldPromptRevive(enabled: Bool, quitting: Bool, structurallyRevivable: Bool,
                                               recently: Bool, screenLocked: Bool, inCooldown: Bool) -> Bool {
        enabled && !quitting && structurallyRevivable && !recently && !screenLocked && !inCooldown
    }

    /// Sanitize an untrusted window title for display: strips all control, format (Bidi overrides/isolates/marks,
    /// zero-width chars), separator, private-use, and unassigned scalars; collapses whitespace; clips to `limit`.
    nonisolated static func sanitizeTitle(_ s: String, limit: Int = 45) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned:
                if u == "\n" || u == "\r" || u == "\t" || u.properties.generalCategory == .lineSeparator
                    || u.properties.generalCategory == .paragraphSeparator {
                    pendingSpace = !scalars.isEmpty
                }
                continue
            default:
                if u.properties.isWhitespace {
                    pendingSpace = !scalars.isEmpty
                    continue
                }
                if pendingSpace {
                    scalars.append(" ")
                    pendingSpace = false
                }
                scalars.append(u)
            }
        }
        let cleaned = String(scalars)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(1, limit - 1))) + "…"
    }

    /// A sanitized title wrapped in Unicode First-Strong Isolate marks so RTL/LTR text cannot reorder surrounding copy.
    nonisolated static func isolatedTitle(_ s: String, limit: Int = 45) -> String {
        let clean = sanitizeTitle(s, limit: limit)
        guard !clean.isEmpty else { return "" }
        return "\u{2068}\(clean)\u{2069}"
    }

    /// Ownership phrase shown to the user so `.user` windows are visually distinguished from the agent's own.
    nonisolated static func ownerPhrase(_ o: Owner) -> String {
        switch o {
        case .agent: return "agent's window"
        case .shared: return "shared window"
        case .user: return "your window"
        }
    }

    /// Short human-readable phrase for the blocked action.
    nonisolated static func actionPhrase(_ action: String?) -> String {
        switch (action ?? "").lowercased() {
        case "type", "type_text": return "to type"
        case "keypress", "key", "press_key", "hotkey": return "to press keys"
        case "paste": return "to paste"
        case "menu", "menu_item": return "to run a menu command"
        case "fill": return "to fill a form"
        case "navigate", "goto", "go_to": return "to navigate"
        case "select", "choose": return "to choose an option"
        case "key_down", "keydown", "hold_key", "hold": return "to hold keys"
        case "click", "left_click", "double_click", "triple_click", "right_click", "middle_click",
             "drag", "left_click_drag", "move", "mouse_move", "hover", "mouse_down":
            return "for a modifier click"
        case "redraw": return "to redraw it"
        default: return "to continue"
        }
    }

    /// Headline, detail, and primary-button label for `req`.
    nonisolated static func copy(for req: Request) -> (headline: String, detail: String, approveLabel: String) {
        let app = sanitizeTitle(req.app, limit: 30)
        let title = isolatedTitle(req.title)
        let targetName = title.isEmpty ? "window #\(req.wid)" : "\"\(title)\""
        let who = ownerPhrase(req.targetOwner)
        let act = actionPhrase(req.action)
        let keyName: String? = {
            let kt = isolatedTitle(req.keyTitle, limit: 35)
            if !kt.isEmpty { return "\"\(kt)\"" }
            return req.keyWid.map { "#\($0)" }
        }()
        switch req.trigger {
        case .switchedIn:
            let headline = "Allow typing in \(app) \(targetName)?"
            let detail = "Agent wants \(act) in #\(req.wid) (\(who)) while you're in \(app)."
            return (headline, detail, "Allow")
        case .frozen:
            let headline = "Switch \(app) to \(targetName)?"
            let whereStr = req.front ? (keyName.map { " while you're in \($0)" } ?? " while you're in \(app)") : ""
            let detail = "\(app) paused drawing #\(req.wid) (\(who)) while covered\(whereStr)."
            return (headline, detail, "Switch Window")
        case .otherWindow:
            let headline = "Switch \(app) to \(targetName)?"
            let active: String
            if req.front {
                active = keyName.map { " You're active in \($0)." } ?? " You're active in another window."
            } else {
                active = keyName.map { " Focus is on \($0)." } ?? ""
            }
            let detail = "Agent needs #\(req.wid) (\(who)) \(act).\(active)"
            return (headline, detail, "Switch Window")
        }
    }

    /// Where the HUD panel goes in AppKit bottom-left coordinates: top-right of the screen containing
    /// `anchorCG` (CG top-left frame converted via `primaryHeight`), else `mouseAppKit`, else the first screen.
    /// Uses a 48 pt top inset on full-screen / auto-hiding menu bar screens so the menu bar doesn't cover buttons.
    nonisolated static func panelFrame(size: CGSize, anchorCG: CGRect?,
                                       screens: [(frame: CGRect, visible: CGRect)],
                                       primaryHeight: CGFloat, mouseAppKit: CGPoint?) -> CGRect {
        guard let fallback = screens.first else { return CGRect(origin: .zero, size: size) }
        var chosen = fallback
        if let cg = anchorCG, primaryHeight > 0 {
            let appKit = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            let center = CGPoint(x: appKit.midX, y: appKit.midY)
            if let hit = screens.first(where: { $0.frame.contains(center) }) {
                chosen = hit
            } else if let best = screens.max(by: {
                let a = $0.frame.intersection(appKit), b = $1.frame.intersection(appKit)
                let aa = a.isNull ? 0 : a.width * a.height
                let bb = b.isNull ? 0 : b.width * b.height
                return aa < bb
            }), !best.frame.intersection(appKit).isNull {
                chosen = best
            }
        } else if let m = mouseAppKit, let hit = screens.first(where: { $0.frame.contains(m) }) {
            chosen = hit
        }
        let v = chosen.visible
        // Full-screen Spaces and auto-hiding menu bars leave visible.maxY == frame.maxY.
        let topInset: CGFloat = abs(v.maxY - chosen.frame.maxY) < 1 ? 48 : 16
        let rightInset: CGFloat = 16
        let x = max(v.minX + 8, v.maxX - size.width - rightInset)
        let y = max(v.minY + 8, v.maxY - size.height - topInset)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: - dedicated error wording

    nonisolated static func declinedKeyboardError(app: String, wid: CGWindowID, title: String,
                                                  targetOwner: Owner, keyDesc: String?) -> String {
        let t = sanitizeTitle(title, limit: 40)
        let named = t.isEmpty ? "#\(wid)" : "#\(wid) \"\(t)\""
        let active = keyDesc.map { " (they're active in \($0))" } ?? ""
        return "the user declined switching \(app) to \(named) (\(Handlers.whose(targetOwner)))\(active), so the "
            + "action didn't run. Don't retry right now; wait until they leave \(app) or ask them. Clicks without keys "
            + "still reach #\(wid)"
    }

    nonisolated static func timedOutKeyboardError(app: String, wid: CGWindowID, title: String,
                                                  targetOwner: Owner, keyDesc: String?, seconds: Int) -> String {
        let t = sanitizeTitle(title, limit: 40)
        let named = t.isEmpty ? "#\(wid)" : "#\(wid) \"\(t)\""
        let active = keyDesc.map { " (they're in \($0))" } ?? ""
        return "asked the user to switch \(app) to \(named) (\(Handlers.whose(targetOwner)))\(active), but they "
            + "didn't respond within \(seconds) s, so the action didn't run. Don't retry right away; wait until they "
            + "leave \(app) or ask them. Clicks without keys still reach #\(wid)"
    }

    nonisolated static func cooldownKeyboardError(app: String, wid: CGWindowID, reason: CooldownReason) -> String {
        let why = reason == .declined ? "declined switching \(app)" : "didn't respond to the \(app) switch prompt"
        return "the user recently \(why), so puter-use didn't ask again and the action didn't run. Don't retry right "
            + "now; wait until they leave \(app) or ask them. Clicks without keys still reach #\(wid)"
    }

    // MARK: - per-app cooldowns & FIFO gate

    private static var cooldowns: [pid_t: (until: TimeInterval, reason: CooldownReason)] = [:]
    private static var gateLine: [Int] = []
    private static var gateTickets = 0
    private static var activeCancel: (() -> Void)?

    /// Injectable presenter for unit tests; nil uses the live AppKit HUD panel.
    typealias Presenter = @MainActor (Request, TimeInterval, @escaping @MainActor () -> Outcome?) async -> Outcome
    static var presenter: Presenter?
    static var timeout: TimeInterval = defaultTimeout

    static func recordDecline(pid: pid_t, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        cooldowns[pid] = (now + declineCooldown, .declined)
    }

    static func recordTimeout(pid: pid_t, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        cooldowns[pid] = (now + timeoutCooldown, .timedOut)
    }

    static func activeCooldown(pid: pid_t, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CooldownReason? {
        guard let c = cooldowns[pid] else { return nil }
        if now < c.until { return c.reason }
        cooldowns[pid] = nil
        return nil
    }

    static func clearCooldown(pid: pid_t) { cooldowns[pid] = nil }

    static func resetForTests() {
        cancelAll()
        cooldowns = [:]
        gateLine = []
        presenter = nil
        timeout = defaultTimeout
    }

    /// Serialize prompts globally (FIFO, like `Turns`) so two sessions never stack overlapping popups.
    /// Caller holds the gate across re-check + presentation in its own `@TaskLocal` context.
    static func acquireGate() async throws {
        guard !Connection.quitting, !Connection.hungUp else { throw Cancelled() }
        let t = gateTickets
        gateTickets += 1
        gateLine.append(t)
        while gateLine.first != t {
            if Connection.quitting || Connection.hungUp {
                gateLine.removeAll { $0 == t }
                throw Cancelled()
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    static func releaseGate() {
        if !gateLine.isEmpty { gateLine.removeFirst() }
    }

    /// Immediately close any active popup and wake its caller with `.cancelled` (called on quit / SIGTERM).
    static func cancelAll() {
        let cancel = activeCancel
        activeCancel = nil
        cancel?()
    }

    /// Present `req` (caller must already hold the FIFO gate) and return the outcome, adding wall-clock
    /// prompt wait time to `Connection.current?.promptWait`.
    static func ask(_ req: Request, checkCleared: @escaping @MainActor () -> Outcome?) async -> Outcome {
        guard !Connection.quitting, !Connection.hungUp else { return .cancelled }
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let waited = max(0, ProcessInfo.processInfo.systemUptime - started)
            Connection.current?.promptWait += waited
        }
        if let presenter {
            return await presenter(req, timeout, checkCleared)
        }
        guard NSApp != nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return .unavailable
        }
        let controller = PromptController(request: req, timeout: timeout, checkCleared: checkCleared)
        return await controller.run()
    }

    // MARK: - AppKit non-activating HUD panel

    private final class PromptPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class PromptContentView: NSVisualEffectView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class PromptButton: NSView {
        let title: String
        let primary: Bool
        let accent: NSColor
        var isTracking = false
        private var isHovered = false
        private var isPressed = false
        private var trackingArea: NSTrackingArea?
        private let label = NSTextField(labelWithString: "")
        private let canTrigger: () -> Bool
        private let onClick: () -> Void

        init(title: String, primary: Bool, accent: NSColor, canTrigger: @escaping () -> Bool, onClick: @escaping () -> Void) {
            self.title = title
            self.primary = primary
            self.accent = accent
            self.canTrigger = canTrigger
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.masksToBounds = true
            translatesAutoresizingMaskIntoConstraints = false

            label.stringValue = title
            label.font = .systemFont(ofSize: 12.5, weight: primary ? .semibold : .medium)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            ])
            setAccessibilityRole(.button)
            setAccessibilityLabel(title)
            updateAppearance()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateAppearance()
        }

        private func updateAppearance() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                if primary {
                    let base = accent
                    let bg = isPressed ? base.blended(withFraction: 0.22, of: .black) ?? base
                        : isHovered ? base.blended(withFraction: 0.1, of: .white) ?? base : base
                    layer?.backgroundColor = bg.cgColor
                    layer?.borderWidth = 0
                    label.textColor = .white
                } else {
                    let alpha: CGFloat = isPressed ? 0.22 : isHovered ? 0.14 : 0.09
                    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
                    layer?.borderWidth = 0.75
                    layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
                    label.textColor = .labelColor
                }
            }
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            updateAppearance()
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            updateAppearance()
        }

        override func mouseDown(with event: NSEvent) {
            guard canTrigger() else { return }
            isTracking = true
            isPressed = true
            updateAppearance()
            // Track until mouseUp inside the window without activating PuterUse.app.
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let pt = convert(next.locationInWindow, from: nil)
                let inside = bounds.contains(pt)
                isPressed = inside && next.type != .leftMouseUp
                updateAppearance()
                if next.type == .leftMouseUp {
                    isTracking = false
                    if inside && canTrigger() { onClick() }
                    return
                }
            }
            isTracking = false
            isPressed = false
            updateAppearance()
        }
    }

    @MainActor
    private final class PromptController {
        private let req: Request
        private let timeout: TimeInterval
        private let checkCleared: @MainActor () -> Outcome?
        private var panel: PromptPanel?
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var watcher: Task<Void, Never>?
        private var shownAt: TimeInterval = 0
        private var countdownLabel: NSTextField?
        private var declineButton: PromptButton?
        private var approveButton: PromptButton?

        init(request: Request, timeout: TimeInterval, checkCleared: @escaping @MainActor () -> Outcome?) {
            self.req = request
            self.timeout = timeout
            self.checkCleared = checkCleared
        }

        func run() async -> Outcome {
            await withCheckedContinuation { cont in
                self.continuation = cont
                self.present()
            }
        }

        private func present() {
            let tint = Session.tints[req.sessionOrdinal % Session.tints.count]
            let text = FocusPrompt.copy(for: req)
            let width: CGFloat = 368

            let effect = PromptContentView(frame: NSRect(x: 0, y: 0, width: width, height: 132))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.75
            effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            effect.maskImage = Self.roundedMask(radius: 14)

            // Header: colored session dot + "PuterUse" + countdown.
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = tint.cgColor
            dot.layer?.cornerRadius = 4.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 9), dot.heightAnchor.constraint(equalToConstant: 9)])

            let brand = NSTextField(labelWithString: "PuterUse")
            brand.font = .systemFont(ofSize: 11.5, weight: .semibold)
            brand.textColor = .secondaryLabelColor

            let countdown = NSTextField(labelWithString: "\(max(1, Int(timeout.rounded(.up))))s")
            countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            countdown.textColor = .tertiaryLabelColor
            countdown.alignment = .right
            self.countdownLabel = countdown

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let header = NSStackView(views: [dot, brand, spacer, countdown])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 6

            let headline = NSTextField(wrappingLabelWithString: text.headline)
            headline.font = .systemFont(ofSize: 13.5, weight: .semibold)
            headline.textColor = .labelColor
            headline.maximumNumberOfLines = 2
            headline.lineBreakMode = .byTruncatingTail
            headline.preferredMaxLayoutWidth = width - 32

            let detail = NSTextField(wrappingLabelWithString: text.detail)
            detail.font = .systemFont(ofSize: 12, weight: .regular)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 3
            detail.lineBreakMode = .byTruncatingTail
            detail.preferredMaxLayoutWidth = width - 32

            let canClick: () -> Bool = { [weak self] in
                guard let self, self.continuation != nil else { return false }
                return ProcessInfo.processInfo.systemUptime >= self.shownAt + FocusPrompt.clickGrace
            }
            let decline = PromptButton(title: "Decline", primary: false, accent: tint, canTrigger: canClick) { [weak self] in
                self?.finish(.declined)
            }
            let approve = PromptButton(title: text.approveLabel, primary: true, accent: tint, canTrigger: canClick) { [weak self] in
                // Snapshot user press count synchronously on Approve click, before raising the target window.
                let presses = Input.userPresses()
                let at = ProcessInfo.processInfo.systemUptime
                self?.finish(.approved(presses: presses, at: at))
            }
            self.declineButton = decline
            self.approveButton = approve

            let btnSpacer = NSView()
            btnSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let buttons = NSStackView(views: [btnSpacer, decline, approve])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8

            let stack = NSStackView(views: [header, headline, detail, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.setCustomSpacing(4, after: header)
            stack.setCustomSpacing(10, after: detail)
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 13),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -13),
                header.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            effect.layoutSubtreeIfNeeded()
            let fitHeight = max(108, stack.fittingSize.height + 26)
            let size = CGSize(width: width, height: fitHeight)

            let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let frame = FocusPrompt.panelFrame(size: size, anchorCG: req.anchorFrame, screens: screens,
                                               primaryHeight: primaryH, mouseAppKit: NSEvent.mouseLocation)

            let p = PromptPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.sharingType = .none
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.title = "PuterUse Focus Request"
            p.contentView = effect
            p.setFrame(frame, display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.invalidateShadow()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                p.animator().alphaValue = 1
            }, completionHandler: nil)

            self.panel = p
            self.shownAt = ProcessInfo.processInfo.systemUptime
            let deadline = self.shownAt + timeout

            FocusPrompt.activeCancel = { [weak self] in self?.finish(.cancelled) }

            let conn = Connection.current
            watcher = Task { @MainActor [weak self] in
                while let self, self.continuation != nil {
                    if Connection.quitting || conn?.hungUp() == true {
                        self.finish(.cancelled)
                        return
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    let tracking = self.declineButton?.isTracking == true || self.approveButton?.isTracking == true
                    if !tracking {
                        let left = max(0, deadline - now)
                        self.countdownLabel?.stringValue = "\(max(1, Int(left.rounded(.up))))s"
                        if now >= deadline {
                            self.finish(.timedOut)
                            return
                        }
                        if let cleared = self.checkCleared() {
                            self.finish(cleared)
                            return
                        }
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        /// Atomically complete the prompt once and tear down the panel.
        private func finish(_ outcome: Outcome) {
            guard let cont = continuation else { return }
            continuation = nil
            watcher?.cancel()
            watcher = nil
            FocusPrompt.activeCancel = nil
            let p = panel
            panel = nil
            p?.orderOut(nil)
            cont.resume(returning: outcome)
        }

        private static func roundedMask(radius: CGFloat) -> NSImage {
            let side = radius * 2 + 2
            let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            img.resizingMode = .stretch
            return img
        }
    }
}
