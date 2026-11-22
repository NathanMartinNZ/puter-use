import AppKit
import ApplicationServices

/// Routine field edits that accessibility confirms (act's `verify_edits`). When all an act did was type text into
/// fields, set a field's value, or tick or untick a checkbox it named, and accessibility shows each one holding just
/// what was put in it, and the window changed nowhere else, the reply says so (`verified`). Its picture is still
/// sent: whoever reads the reply decides whether it's needed.
///
/// Never for a password field (its text is never read), a field the page marks invalid, an act that sends a form (a
/// submit, a Return), presses anything else or has the user's OK on any of its actions, nor when the act stopped,
/// failed, noted something, looked at the window for the first time, or something opened over the window or moved it
/// (`Ending`). A picture marked verified is withheld from the agent, so it isn't kept as what the agent last saw
/// (`remembers`): the next reply is compared with the last picture it was shown.
enum VerifyEdit {
    /// How far a control's own change may show past its frame (a focus ring, the text cursor at its edge), in points.
    nonisolated static let margin: CGFloat = 8

    /// What an edit did: typed text into a field (type, or a fill's text), set a field's value (set_value), or
    /// ticked or unticked a checkbox (a click on it, or a fill's true or false).
    enum Kind: Equatable { case typed, set, checked }

    /// One edit: the control's frame (global points), what it should hold and what accessibility says it holds (a
    /// checkbox's "1" or "0"), whether it's a password field, and whether the page marks it invalid.
    struct Edit: Equatable {
        var frame: CGRect?
        var expected: String?
        var actual: String?
        var secure = false
        var invalid = false
        var kind: Kind

        /// Accessibility confirms it: not a password field nor one marked invalid, its place known, and it holds
        /// exactly what it should.
        var confirmed: Bool { !secure && !invalid && frame != nil && expected != nil && actual == expected }
    }

    /// How an act ended, as far as the verdict goes. Any of these and it's never verified.
    struct Ending: Equatable {
        /// An action failed (the reply's errors).
        var failed = false
        /// It stopped: for the user's OK (confirm), or before coordinates or a macro's positions (the guard).
        var stopped = false
        /// It noted something: a pop-up it closed, the focus moving on, a field showing other text.
        var noted = false
        /// The agent hadn't been shown the window: there's no picture it saw to compare with.
        var firstLook = false
        /// A new window, sheet, dialog, menu or pop-up came, or the act moved to another window.
        var newWindow = false
        /// The window moved or changed size.
        var moved = false

        var rulesOut: Bool { failed || stopped || noted || firstLook || newWindow || moved }
    }

    /// Whether a reply's picture is kept as what the agent last saw (`Handlers.remember`): not a zoom's (it isn't the
    /// window), nor one marked verified, which the agent isn't shown. The next reply is compared with the last one it
    /// was, so a change it hasn't seen (the edits too) comes with a picture, a stop for the user's OK included.
    nonisolated static func remembers(zoom: Bool, verified: Bool) -> Bool { !zoom && !verified }

    // MARK: - which acts

    /// Whether an act's actions are all routine edits (`edits`), one at least.
    nonisolated static func eligible(actions: [[String: Any]]) -> Bool {
        !actions.isEmpty && actions.allSatisfy { edits($0) != nil }
    }

    /// How many edits action `a` makes when it's a routine edit, or nil when it isn't. Routine:
    /// - type, of text with no Return or Tab in it (`Handlers.readsBack`) and no submit;
    /// - set_value;
    /// - fill with no submit: one edit per field, each text going in (no Return or Tab either, no submit of its own)
    ///   or a checkbox's true or false (`routineField`, `routineValue`). A key of the object form whose control turns
    ///   out to be a pop-up makes no edit, so its act isn't complete (`complete`);
    /// - a plain left click on what an element number or target names: one edit, made only when that's a checkbox.
    ///
    /// Nothing else: no keys, menus, scrolls, waits, navigation, pop-up picks (a web page's `<select>` included),
    /// clicks by coordinates or macros, and nothing with the user's OK on it (`confirm`: the guard stopped it).
    nonisolated static func edits(_ a: [String: Any]) -> Int? {
        if a["confirm"] as? Bool == true { return nil }
        switch Handlers.kind(a) {
        case "type", "type_text":
            guard let text = a["text"] as? String ?? a["value"] as? String, Handlers.readsBack(text), !submits(a["submit"]) else {
                return nil
            }
            return 1
        case "set_value":
            return 1
        case "fill":
            guard !submits(a["submit"]) else { return nil }
            if let fields = a["fields"] as? [[String: Any]], !fields.isEmpty {
                return fields.allSatisfy(routineField) ? fields.count : nil
            }
            if let byLabel = a["fields"] as? [String: Any], !byLabel.isEmpty {
                return byLabel.values.allSatisfy(routineValue) ? byLabel.count : nil
            }
            return nil
        case "click", "left_click":
            let named = Handlers.isGiven(a["element"]) || Handlers.isGiven(a["target"])
            let byPoint = ["x", "y", "coordinate"].contains { Handlers.isGiven(a[$0]) }
            let plain = ((a["button"] as? String)?.lowercased() ?? "left") == "left" && Handlers.int(a["count"] ?? a["clicks"], 1) == 1
                && !Handlers.isGiven(a["item"]) && Keys.splitCombo(Handlers.modifierKeys(a)).isEmpty
            return named && !byPoint && plain ? 1 : nil
        default:
            return nil
        }
    }

    /// Whether a submit's value sends the form: anything given but false (true is a Return; an element number, a
    /// button's text or a step is a click).
    nonisolated static func submits(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return true
    }

    /// A fill field of the list form that's a routine edit, read as fill reads it: a checkbox's true or false, or
    /// text going in with no Return or Tab and no submit of its own. Not a pop-up's option.
    nonisolated static func routineField(_ f: [String: Any]) -> Bool {
        if f["option"] != nil || f["select"] != nil || submits(f["submit"]) || f["confirm"] as? Bool == true { return false }
        if f["checked"] as? Bool != nil { return true }
        guard let text = f["text"] as? String ?? f["value"] as? String else { return false }
        return Handlers.readsBack(text)
    }

    /// A value of fill's object form that's a routine edit: true or false (a checkbox), or text (a number too) with
    /// no Return or Tab in it.
    nonisolated static func routineValue(_ v: Any) -> Bool {
        switch Handlers.fieldValue(v) {
        case .flag: return true
        case .text(let s): return Handlers.readsBack(s)
        case nil: return false
        }
    }

    /// Whether each action made just the edits it does (`edits`): none missed (a pop-up where text was given, a click
    /// on something other than a checkbox, a field typed into that wasn't read) and none more.
    nonisolated static func complete(_ made: [[Edit]], for actions: [[String: Any]]) -> Bool {
        made.count == actions.count && zip(made, actions).allSatisfy { m, a in edits(a) == m.count }
    }

    // MARK: - the verdict

    /// The verdict as the act ends. Nothing in `ending` rules it out (an error, a stop, a note, a first look, a new
    /// window or pop-up, the window moved). Every edit is confirmed (`Edit.confirmed`: never a password field's), there
    /// being one at least. And every change to the window's picture (`changes`, global points: none when it didn't
    /// change) lies within the edited controls' frames, or the frame of the control the window's last click went to
    /// before the act (`lastClicked`: its hover shade may clear), each grown by `margin`.
    nonisolated static func verified(edits: [Edit], changes: [CGRect], lastClicked: CGRect?, ending: Ending,
                                     margin: CGFloat = VerifyEdit.margin) -> Bool {
        guard !ending.rulesOut, !edits.isEmpty, edits.allSatisfy(\.confirmed) else { return false }
        return contained(changes, in: allowed(edits: edits, lastClicked: lastClicked), margin: margin)
    }

    /// Where an act's edits may change the window: the edited controls' frames, and the last-clicked one's.
    nonisolated static func allowed(edits: [Edit], lastClicked: CGRect?) -> [CGRect] {
        edits.compactMap(\.frame) + [lastClicked].compactMap { $0 }
    }

    /// Whether every changed area lies within the allowed ones grown by `margin`, taken together: two fields close
    /// enough for their margins to meet cover the gap between them, and two farther apart don't.
    nonisolated static func contained(_ changes: [CGRect], in allowed: [CGRect], margin: CGFloat = VerifyEdit.margin) -> Bool {
        let zones = allowed.filter { !$0.isNull && !$0.isInfinite }.map { $0.insetBy(dx: -margin, dy: -margin) }
        return changes.allSatisfy { covered($0, by: zones) }
    }

    /// Whether `r` is covered by `zones` together: cut along their edges, each piece of it lies in one of them.
    nonisolated static func covered(_ r: CGRect, by zones: [CGRect]) -> Bool {
        guard !r.isNull else { return true }
        if r.isEmpty { return zones.contains { $0.contains(r.origin) } }
        let over = zones.filter { $0.intersects(r) }
        guard !over.isEmpty else { return false }
        func cuts(_ edges: [CGFloat], _ lo: CGFloat, _ hi: CGFloat) -> [CGFloat] {
            Array(Set([lo, hi] + edges.filter { $0 > lo && $0 < hi })).sorted()
        }
        let xs = cuts(over.flatMap { [$0.minX, $0.maxX] }, r.minX, r.maxX)
        let ys = cuts(over.flatMap { [$0.minY, $0.maxY] }, r.minY, r.maxY)
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            for (y0, y1) in zip(ys, ys.dropFirst()) {
                let mid = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                if !over.contains(where: { $0.contains(mid) }) { return false }
            }
        }
        return true
    }

    /// The cells of a window's picture that changed between two signatures of it (by `Signature.diff`'s tolerance),
    /// as areas of the screen (global points; the picture shows `capture`). Each row's run of changed cells is one
    /// area. Nil when the two can't be compared (the picture's size changed).
    nonisolated static func changedCells(_ now: Signature, _ before: Signature, capture: CGRect, tolerance: Int = 6) -> [CGRect]? {
        guard now.w == before.w, now.h == before.h else { return nil }
        return changedCells(now.px, before.px, w: now.w, h: now.h, capture: capture, tolerance: tolerance)
    }

    /// `changedCells` on the cells themselves: `w` x `h` grey levels, row by row. Nil when there aren't that many.
    nonisolated static func changedCells(_ now: [UInt8], _ before: [UInt8], w: Int, h: Int, capture: CGRect,
                                         tolerance: Int = 6) -> [CGRect]? {
        guard w > 0, h > 0, now.count >= w * h, before.count >= w * h else { return nil }
        let cw = capture.width / CGFloat(w), ch = capture.height / CGFloat(h)
        func changed(_ i: Int) -> Bool { abs(Int(now[i]) - Int(before[i])) > tolerance }
        var out: [CGRect] = []
        for y in 0..<h {
            var x = 0
            while x < w {
                guard changed(y * w + x) else {
                    x += 1
                    continue
                }
                let start = x
                while x < w, changed(y * w + x) { x += 1 }
                out.append(CGRect(x: capture.minX + CGFloat(start) * cw, y: capture.minY + CGFloat(y) * ch,
                                  width: CGFloat(x - start) * cw, height: ch))
            }
        }
        return out
    }

    // MARK: - what an edit should show

    /// What a field holding `old` should hold once `typed` replaces `range` of it (UTF-16 units, as accessibility
    /// counts them; an empty range is the text cursor's place). Nil when either isn't known, or the range isn't in
    /// the text.
    nonisolated static func expectedText(old: String?, range: CFRange?, typed: String) -> String? {
        guard let old, let range, range.location >= 0, range.length >= 0 else { return nil }
        let s = old as NSString
        guard range.location + range.length <= s.length else { return nil }
        return s.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: typed)
    }

    /// Whether a control's `AXInvalid` says the page marks it invalid (`aria-invalid`): "true", not "false" nor a
    /// spelling or grammar mark.
    nonisolated static func invalid(_ v: Any?) -> Bool {
        if let s = v as? String { return s.lowercased() == "true" }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return false
    }

    /// A checkbox's state as accessibility gives it: "1" ticked, "0" not. Nil when it's mixed, or not a state.
    nonisolated static func state(_ v: Any?) -> String? {
        guard let n = v as? NSNumber else { return nil }
        switch n.intValue {
        case 0: return "0"
        case 1: return "1"
        default: return nil
        }
    }

    // MARK: - an act's edits as they're made

    /// The act under way checks its edits, and they can be verified: its fields are read for it.
    @MainActor static var collecting: Bool { Session.current.edits?.recording == true }

    /// What `field` should hold once `typed` goes in where its selection (or text cursor) is, read before it's typed
    /// (`expectedText`), when the act under way checks its edits. Nil otherwise, or when it can't be read.
    @MainActor static func expectation(_ field: AX.Node?, typed: String) -> String? {
        guard collecting, let field else { return nil }
        return expectedText(old: AX.value(field.element, kAXValueAttribute) as? String, range: AX.selectedRange(field.element),
                            typed: typed)
    }

    /// Text typed into `field`: what it should hold (`expected`), and what it showed once typed (`shows`, as its
    /// read-back read it). A password field's (`secure`) is never read, so never confirmed.
    @MainActor static func typed(_ field: AX.Node, expected: String?, shows: String?, secure: Bool = false) {
        guard collecting, let c = Session.current.edits else { return }
        c.add(Edit(frame: field.frame, expected: secure ? nil : expected, actual: secure ? nil : shows, secure: secure,
                   kind: .typed), field.element)
    }

    /// A value set_value put in `n` (`text`). An edit of a text field only: another control's value isn't text put in.
    @MainActor static func valueSet(_ n: AX.Node, _ text: String) {
        guard collecting, let c = Session.current.edits else { return }
        let secure = Policy.isSecure(n.element)
        c.add(Edit(frame: n.frame, expected: !secure && AX.isTextInput(n.element) ? text : nil, secure: secure, kind: .set),
              n.element)
    }

    /// A checkbox a fill ticks or unticks (`want`), in the state `was` before. Only a checkbox's: a radio button
    /// changes another too.
    @MainActor static func checked(_ n: AX.Node, want: Bool, was: String?) {
        guard collecting, let c = Session.current.edits else { return }
        let state = want ? "1" : "0"
        c.add(Edit(frame: n.frame, expected: role(n) == "AXCheckBox" ? state : nil, actual: was == state ? was : nil,
                   kind: .checked), n.element)
    }

    /// A click going to `node` (to `p`, when no element was named), in an act that checks its edits. Where it goes is
    /// kept for the window (`Session.lastClicked`: the control's frame, found at `p` when no element was named), for
    /// the acts after it. Not a text field's: what changes there as the focus leaves it (a page marking it invalid)
    /// isn't a hover shade; one typed into is judged as an edit. And a click the act was given itself (not one a type
    /// or fill makes on the way) on a checkbox it names is an edit: from the state it's in to the other.
    @MainActor static func clicking(_ node: AX.Node?, at p: CGPoint, pid: pid_t) {
        guard let c = Session.current.edits else { return }
        let el = node?.element ?? AX.element(pid: pid, at: p)
        let frame: CGRect? = el.flatMap { e -> CGRect? in AX.isTextInput(e) ? nil : (node?.frame ?? AX.frame(e)) }
        if let frame, let o = Windows.info(c.window.id)?.frame.origin {
            Session.current.lastClicked[c.window.id] = frame.offsetBy(dx: -o.x, dy: -o.y)
        } else {
            Session.current.lastClicked[c.window.id] = nil
        }
        guard c.recording, let node, let a = Policy.running, ["click", "left_click"].contains(Handlers.kind(a)),
              role(node) == "AXCheckBox", let was = state(AX.value(node.element, kAXValueAttribute)) else { return }
        c.add(Edit(frame: frame, expected: was == "1" ? "0" : "1", kind: .checked), node.element)
    }

    /// Where window `wid`'s last click went (global points), as `clicking` kept it.
    @MainActor static func lastClick(in wid: CGWindowID) -> CGRect? {
        guard let r = Session.current.lastClicked[wid], let o = Windows.info(wid)?.frame.origin else { return nil }
        return r.offsetBy(dx: o.x, dy: o.y)
    }

    @MainActor static func role(_ n: AX.Node) -> String {
        n.role.isEmpty ? AX.value(n.element, kAXRoleAttribute) as? String ?? "" : n.role
    }

    /// The edits of the act under way (`Session.edits`, there when act was given `verify_edits`), each action's
    /// apart, and what's needed to judge them as it ends: its window as it began (what was over it, where it was),
    /// where the window's last click went before it, and the edits earlier replies confirmed whose picture the agent
    /// hasn't seen (`Session.withheld`).
    @MainActor final class Collector {
        typealias Entry = (element: AXUIElement?, edit: Edit)

        let window: WinInfo
        /// Its actions can all be verified (`eligible`): only then are fields read for it.
        let recording: Bool
        /// Where the window's last click went before the act (global points).
        let lastClicked: CGRect?
        /// What was over the window as the act began, and where it was (only when `recording`).
        let start: (over: WindowSet, frame: CGRect?)?
        private(set) var made: [[Entry]] = []
        /// Edits of earlier acts in the window whose pictures were withheld: the picture this act's is compared with
        /// is older than they are, so they show in it too. Each is read again and must still hold.
        private(set) var carried: [Entry]

        /// For an act of `actions` (as the agent gave them: a macro isn't routine) in window `w`.
        init(_ actions: [[String: Any]], window w: WinInfo) {
            window = w
            recording = VerifyEdit.eligible(actions: actions)
            lastClicked = VerifyEdit.lastClick(in: w.id)
            start = recording ? (WindowSet.of(w), Windows.info(w.id)?.frame) : nil
            carried = Session.current.withheld[w.id] ?? []
        }

        /// The next action begins: the edits it makes are its own.
        func begin() { made.append([]) }

        func add(_ edit: Edit, _ element: AXUIElement?) {
            guard recording else { return }
            if made.isEmpty { made.append([]) }
            made[made.count - 1].append((element, edit))
        }

        var edits: [Edit] { made.flatMap { $0.map { $0.edit } } }

        /// The carried edits of controls this act didn't edit again (one it did is judged by what it put there now).
        var older: [Entry] {
            let now = made.joined().compactMap { $0.element }
            return carried.filter { old in old.element.map { e in !now.contains { CFEqual($0, e) } } ?? true }
        }

        /// Each edited control read again as the act ends, as its picture shows it (`fresh`), the carried ones too.
        func reread() {
            for i in made.indices {
                for j in made[i].indices { made[i][j] = Collector.fresh(made[i][j]) }
            }
            carried = carried.map(Collector.fresh)
        }

        /// `e` read again: where its control is, what it holds, and whether the page marks it invalid. A password
        /// field's text is never read (one that's become one isn't either); a control that's gone has no place, so it
        /// isn't confirmed.
        static func fresh(_ e: Entry) -> Entry {
            guard let el = e.element, !e.edit.secure else { return e }
            var edit = e.edit
            if Policy.isSecure(el) {
                edit.secure = true
                return (el, edit)
            }
            edit.frame = AX.frame(el)
            let v = AX.value(el, kAXValueAttribute)
            edit.actual = edit.kind == .checked ? VerifyEdit.state(v) : v as? String
            edit.invalid = VerifyEdit.invalid(AX.value(el, "AXInvalid"))
            return (el, edit)
        }

        /// The verdict (`verified`) as the act ends, each edit read again first (`reread`), the carried ones with this
        /// act's. `actions`: those that ran, a macro's steps in its place; `now`: the picture's signature, `before` the
        /// one it's compared with (none: it's a first look), the picture showing `capture` (global points); `ending`:
        /// how the act ended, to which it adds what it sees itself (something over the window that wasn't, the window
        /// moved or resized). A changed cell counts as within a control when it's within the margin and one cell more,
        /// as the cells are coarser than the margin.
        func verdict(_ actions: [[String: Any]], now: Signature, before: Signature?, capture: CGRect, ending: Ending) -> Bool {
            var ending = ending
            if before == nil { ending.firstLook = true }
            guard recording, !ending.rulesOut, let start, let before else { return false }
            if WindowSet.of(window) != start.over { ending.newWindow = true }
            if Windows.info(window.id)?.frame != start.frame { ending.moved = true }
            guard !ending.rulesOut else { return false }
            reread()
            guard VerifyEdit.complete(made.map { $0.map { $0.edit } }, for: actions),
                  let changes = VerifyEdit.changedCells(now, before, capture: capture) else { return false }
            let cell = max(capture.width / CGFloat(max(now.w, 1)), capture.height / CGFloat(max(now.h, 1)))
            return VerifyEdit.verified(edits: older.map { $0.edit } + edits, changes: changes, lastClicked: lastClicked,
                                       ending: ending, margin: VerifyEdit.margin + cell)
        }

        /// The reply was marked verified, so its picture is withheld: its edits, and the carried ones, wait for the
        /// next act in the window to be judged with them (until the agent is shown a picture of it: `seen`).
        func withhold() { Session.current.withheld[window.id] = older + made.joined() }
    }

    /// The agent was shown a picture of window `wid`: the edits withheld before it are in it.
    @MainActor static func seen(_ wid: CGWindowID) { Session.current.withheld[wid] = nil }
}
