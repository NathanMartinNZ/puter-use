import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Accessibility: a compact, indexed outline of a window's UI, and actions on indexed elements.
enum AX {
    struct Node {
        let element: AXUIElement
        let frame: CGRect?
        var role = ""  // AX role when it was numbered
        var label: String?  // its title/description then (not its value): how to tell it's still the same
        var name = ""  // outline role name ("button", "field", …)
        var parent: AXUIElement? = nil  // its container then: a replacement must be in the same one
        var away = false  // numbered by an off-screen search: used only once where it is is known (`reveal`)
        var shown: String? = nil  // what the outline called it (also from the text that titles it), for messages
    }

    /// Element numbers per window, stable across looks: an element keeps its number for as long as it
    /// exists, so numbers from an earlier outline (or find) still work after the window changes, and a
    /// number whose element is gone fails instead of hitting something else.
    final class Registry {
        var ids: [AXUIElement: Int] = [:]
        var nodes: [Int: Node] = [:]
        var next = 1
        var lines: [(Int, String)] = []  // the last outline's numbered lines, in order (for "what changed")
        /// The last outline's lines with no number of their own (texts, headings, containers, and a line of text
        /// with links in it), in order, each with a key that stays while the line does: the line itself, then
        /// " (2)", " (3)"… for the same line again. For "what changed" in what has no number.
        var unnumbered: [(String, String)] = []
        /// The last outline's lines, numbered or not, each with its key, in the order written (a line of text's own
        /// line, then those of the elements in it): what "what changed" compares (`OutlineDiff`).
        var keyed: [OutlineDiff.Line] = []
        var cutShort = false  // that outline ran out of time (`walkBudget`): its lines are only part of the window
        var truncated = false  // that outline ran past its caps (`truncatedNote`): the window has more past its last line
        var presses: [AXUIElement: Bool] = [:]  // which texts take a press, as asked once (`canPress`)

        func number(_ n: Node) -> Int {
            let id = ids[n.element] ?? { defer { next += 1 }; return next }()
            ids[n.element] = id
            nodes[id] = n
            return id
        }

        /// Forget elements that weren't in the latest outline once there are many (long-lived web pages).
        func prune(keeping seen: Set<Int>) {
            guard nodes.count > 3000 else { return }
            for (id, n) in nodes where !seen.contains(id) {
                nodes[id] = nil
                ids[n.element] = nil
            }
        }
    }

    nonisolated(unsafe) static var registries: [CGWindowID: Registry] = [:]
    /// For the agent (the session's): e.g. an element found again.
    static var remarks: [String] {
        get { Session.current.remarks }
        set { Session.current.remarks = newValue }
    }

    static func registry(_ wid: CGWindowID) -> Registry {
        if let r = registries[wid] { return r }
        let r = Registry()
        registries[wid] = r
        return r
    }

    /// 8.333333333333334 -> "8.33", 1.0 -> "1": slider/ruler values without wasted digits.
    static func compact(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        var s = String(format: "%.2f", d)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        // Chromium/Electron only build their accessibility tree when asked.
        askForTree(pid) { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        // So does Firefox (Gecko), for clients asking for the "enhanced" UI: done on the first look at it, so
        // find and target: see its pages from the start. Never for other apps: some native ones change
        // behaviour with it.
        if Windows.isGecko(pid), !enhanced.contains(pid) {
            enhanced.insert(pid)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            usleep(400_000)  // it builds the tree
        }
        return app
    }

    /// When each app (pid) last answered `AXManualAccessibility` (system uptime, s).
    nonisolated(unsafe) static var treeAsked: [pid_t: TimeInterval] = [:]
    /// How often it's asked again. Not once for good: another accessibility client turning Electron's
    /// enhanced UI off turns its tree off too. Not on every lookup either: each is a round trip to the app,
    /// and lookups come in bursts (about one per typed key). Agents' calls are usually further apart than
    /// this, so each call still asks on its first lookup; a long one asks again every 5 s.
    static let treeEvery: TimeInterval = 5

    /// Sends `AXManualAccessibility` (`send`) to `pid` unless the app answered it less than `treeEvery` ago.
    /// Done, unsupported (native apps) and not implemented count as answered; "cannot complete" (busy, or
    /// still launching) doesn't, so the next lookup asks again.
    static func askForTree(_ pid: pid_t, now: TimeInterval = ProcessInfo.processInfo.systemUptime, send: () -> AXError) {
        func fresh(_ t: TimeInterval) -> Bool { now >= t && now - t < treeEvery }
        if let last = treeAsked[pid], fresh(last) { return }
        let err = send()
        guard err == .success || err == .attributeUnsupported || err == .notImplemented else { return }
        if treeAsked.count >= 32 { treeAsked = treeAsked.filter { fresh($0.value) } }  // gone apps, reused pids
        treeAsked[pid] = now
    }

    static func window(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        let app = appElement(pid)
        guard let wins = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for w in wins {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success, id == wid { return w }
        }
        // Fall back to matching by frame.
        if let target = Windows.info(wid)?.frame {
            return wins.first { frame($0).map { abs($0.minX - target.minX) < 2 && abs($0.minY - target.minY) < 2 } ?? false }
        }
        return nil
    }

    /// Shrink (never grow) a resizable document window to fit `box` points, keeping its top-left corner.
    /// Returns false when nothing changed (already small enough, a dialog, or not resizable).
    static func fit(pid: pid_t, wid: CGWindowID, box: CGSize) -> Bool {
        guard let win = window(pid: pid, wid: wid), let f = frame(win),
              (value(win, kAXSubroleAttribute) as? String) == "AXStandardWindow" else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(win, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var size = CGSize(width: min(f.width, box.width), height: min(f.height, box.height))
        guard size != f.size, let v = AXValueCreate(.cgSize, &size) else { return false }
        return write(win, kAXSizeAttribute, v) == .success
    }

    /// Put a window the agent just opened wholly on screen: an app may cascade a new window off an edge,
    /// and what's off screen can't be captured or clicked. Moved, and shrunk if it's too big. Its new
    /// frame, or nil if it was on screen already (or isn't a document window, or wouldn't move). Only for
    /// the agent's own new windows: the user's stay where they put them.
    @MainActor static func bringOnScreen(pid: pid_t, wid: CGWindowID) -> CGRect? {
        guard let win = window(pid: pid, wid: wid), let f = frame(win),
              (value(win, kAXSubroleAttribute) as? String) == "AXStandardWindow" else { return nil }
        let top = NSScreen.screens.first?.frame.height ?? 0  // global points are measured down from its top
        let screens = NSScreen.screens.map { s in
            CGRect(x: s.visibleFrame.minX, y: top - s.visibleFrame.maxY, width: s.visibleFrame.width, height: s.visibleFrame.height)
        }
        guard let to = onScreen(f, screens: screens) else { return nil }
        var size = to.size, origin = to.origin
        if size != f.size, let v = AXValueCreate(.cgSize, &size) { write(win, kAXSizeAttribute, v) }
        if let v = AXValueCreate(.cgPoint, &origin) { write(win, kAXPositionAttribute, v) }
        guard let now = frame(win), now != f else { return nil }
        return now
    }

    /// Where a window with frame `f` goes to be wholly on screen: inside the visible area (`screens`, in
    /// global points) of the screen it's most on, or the first if it's on none, shrunk to fit if it's
    /// bigger. nil if it's on screen already (a point of slack at the edges).
    nonisolated static func onScreen(_ f: CGRect, screens: [CGRect]) -> CGRect? {
        guard !screens.isEmpty, f.width > 0, f.height > 0 else { return nil }
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        let shown = screens.map { area(f.intersection($0)) }
        if shown.reduce(0, +) >= f.width * f.height - (f.width + f.height) { return nil }
        let best = shown.indices.max { shown[$0] < shown[$1] }!
        let s = shown[best] > 0 ? screens[best] : screens[0]
        let w = min(f.width, s.width), h = min(f.height, s.height)
        return CGRect(x: min(max(f.minX, s.minX), s.maxX - w), y: min(max(f.minY, s.minY), s.maxY - h), width: w, height: h)
    }

    static let roleNames: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXTextField": "field",
        "AXTextArea": "textarea", "AXSearchField": "search", "AXComboBox": "combo", "AXPopUpButton": "popup",
        "AXMenuButton": "menubutton", "AXLink": "link", "AXMenuItem": "menuitem", "AXMenuBarItem": "menu",
        "AXStaticText": "text", "AXImage": "image", "AXSlider": "slider", "AXTab": "tab", "AXTabGroup": "tabs",
        "AXRow": "row", "AXCell": "cell", "AXOutlineRow": "row", "AXDisclosureTriangle": "disclosure",
        "AXHeading": "heading", "AXIncrementor": "stepper", "AXColorWell": "color", "AXDateField": "date",
        "AXToolbar": "toolbar", "AXTable": "table", "AXOutline": "outline", "AXList": "list", "AXWebArea": "web",
        "AXSheet": "sheet", "AXDialog": "dialog", "AXSwitch": "switch", "AXToggle": "toggle",
        "AXSegmentedControl": "segments", "AXLevelIndicator": "level", "AXProgressIndicator": "progress",
        "AXValueIndicator": "value", "AXScrollBar": "", "AXSplitter": "", "AXGrowArea": "", "AXMenuBar": "",
        // One short word for roles that would otherwise run two together ("busyindicator").
        "AXBusyIndicator": "busy", "AXRelevanceIndicator": "relevance", "AXTimeField": "time", "AXHelpTag": "tooltip",
        "AXRulerMarker": "marker", "AXGenericElement": "generic",
    ]

    /// Containers that add nesting but no meaning unless labelled.
    static let transparent: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXMatte",
        "AXRuler", "AXBrowser", "AXGrid", "AXColumn", "AXWindow", "AXDrawer", "AXRadioGroup", "AXLandmark",
    ]

    static let attrs: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute, kAXEnabledAttribute,
        kAXPlaceholderValueAttribute, kAXSelectedAttribute, kAXHelpAttribute, kAXTitleUIElementAttribute,
    ]

    /// An element's `attrs`, in one round trip to its app.
    static func readAttrs(_ el: AXUIElement) -> [AnyObject]? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let vals = raw as? [AnyObject], vals.count == attrs.count else { return nil }
        return vals
    }

    /// The element that titles the one `vals` (its `attrs`) are of (`AXTitleUIElement`): a form's "Email" text
    /// beside its field, or a web page's `<label for=…>`.
    static func titleElement(_ vals: [AnyObject]) -> AXUIElement? {
        guard vals.count > 13, CFGetTypeID(vals[13]) == AXUIElementGetTypeID() else { return nil }
        return (vals[13] as! AXUIElement)
    }

    /// What a text says, from its `attrs`: its name, else its value (as the outline shows a text).
    static func textSays(_ vals: [AnyObject]) -> String? {
        for i in [2, 3, 10, 12] { if let s = vals[i] as? String, !s.isEmpty { return s } }
        return vals[4] as? String
    }

    /// What a title element says: a text's words, or a label element's own name, else the words of the texts in
    /// it (four at most). `read` gives an element's `attrs`.
    static func titleText(_ el: AXUIElement, read: (AXUIElement) -> [AnyObject]?) -> String? {
        func some(_ s: String?) -> String? { s.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } }
        guard let vals = read(el) else { return nil }
        if vals[0] as? String == "AXStaticText" { return some(textSays(vals)) }
        if let own = some(vals[2] as? String) ?? some(vals[3] as? String) { return own }
        let kids = vals[5] as? [AXUIElement] ?? []
        guard !kids.isEmpty, kids.count <= 4 else { return nil }
        let parts = kids.compactMap { k in read(k).flatMap { $0[0] as? String == "AXStaticText" ? some(textSays($0)) : nil } }
        let s = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    /// Whether label `l` says nothing `whole` doesn't: its words are among `whole`'s, case, spacing and
    /// punctuation aside ("GitHub" in "GitHub profile", "Email:" in "Email"). Never for a label of no words.
    static func repeats(_ l: String, in whole: String) -> Bool {
        func words(_ s: String) -> String {
            let plain = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            return String(plain).split(separator: " ").joined(separator: " ")
        }
        let k = words(l)
        return !k.isEmpty && (" " + words(whole) + " ").contains(" " + k + " ")
    }

    /// Texts side by side (with their frames) as one label: a space between two that don't touch, none
    /// within a word split in two ("$" "9.99"); spaces run together.
    static func joinRuns(_ parts: [(text: String, rect: CGRect?)]) -> String {
        var s = ""
        var prev: CGRect?
        for (i, p) in parts.enumerated() {
            let touching = prev.flatMap { a in p.rect.map { b in abs(b.minX - a.maxX) <= 1 && abs(b.midY - a.midY) < 3 } } ?? false
            if i > 0, !touching { s += " " }
            s += p.text
            prev = p.rect
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether an element takes a press (`AXPress`): text that does is something to click in itself.
    static func canPress(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(el, &names) == .success && (names as? [String] ?? []).contains(kAXPressAction)
    }

    /// How long a walk over a window's elements (an outline, the text in an area) may take. Its other caps
    /// count elements and characters, but an app that's busy yet answering (a page loading, an IDE
    /// indexing) can take tens of seconds over a whole window. Then the walk stops with what it has and says
    /// so. Checked between elements, so one slow answer can still run over. Longer than `search`'s 1.5 s
    /// over the same reads: a big outline that's just big isn't cut, and cut short it loses more.
    static let walkBudget: TimeInterval = 2.5
    static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    nonisolated(unsafe) static var enhanced: Set<pid_t> = []

    /// Indexed outline, e.g. `#3 button "Back"` / ` #7 field "Search" ="cats" focused` / ` By [Ada](#9) | 2 days ago`.
    /// `within` (global points) limits it to elements overlapping that area, e.g. one table row.
    static func outline(pid: pid_t, wid: CGWindowID, within: CGRect? = nil, maxElements: Int = 300,
                        maxChars: Int = 8000, interactive: Bool = false) -> String? {
        // (Firefox's tree is switched on in `appElement`.)
        buildOutline(pid: pid, wid: wid, within: within, maxElements: maxElements, maxChars: maxChars,
                     interactive: interactive)
    }

    /// Each window's text height as last measured (`textHeight`), and when (system uptime, s).
    nonisolated(unsafe) static var measuredText: [CGWindowID: (height: Double?, at: TimeInterval)] = [:]
    /// How long a window's text height is gone by before it's measured again (s).
    static let textHeightKept: TimeInterval = 30

    /// How high window `wid`'s lines of text are (points), for a picture at `detail: "low"` (`DetailLow`): from
    /// the texts a quick look at it finds (`textHeights`), kept a while (`textHeightKept`). Nil when too few were
    /// found to tell.
    static func textHeight(pid: pid_t, wid: CGWindowID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        if let m = measuredText[wid], now >= m.at, now - m.at < textHeightKept { return m.height }
        let found = textHeights(pid: pid, wid: wid)
        let h = DetailLow.textHeight(window: found.all, page: found.page)
        if measuredText.count >= 64 { measuredText = measuredText.filter { now >= $0.value.at && now - $0.value.at < textHeightKept } }
        measuredText[wid] = (h, now)
        return h
    }

    /// The heights (points) of the texts shown in window `wid`: all those found, and those in a web page in it,
    /// at most `maxSamples` of each, looking breadth first (a window's own labels, then what's in them) for at
    /// most `budget` seconds and `maxVisits` elements. A text of several lines counts by its first line's height
    /// where the app says how high that is. Not through `appElement`, and each question gets a short timeout:
    /// this look mustn't be what switches on an app's tree (Chromium's, Firefox's), nor wait long on a busy app.
    static func textHeights(pid: pid_t, wid: CGWindowID, budget: TimeInterval = 0.3, maxVisits: Int = 600,
                            maxSamples: Int = 40) -> (all: [Double], page: [Double]) {
        let end = uptime() + budget, timeout: Float = 0.25
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let wins = value(app, kAXWindowsAttribute) as? [AXUIElement],
              let win = wins.first(where: { var id: CGWindowID = 0; return _AXUIElementGetWindow($0, &id) == .success && id == wid })
        else { return ([], []) }
        AXUIElementSetMessagingTimeout(win, timeout)
        guard let shown = frame(win) else { return ([], []) }
        let keys = [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var queue: [(el: AXUIElement, page: Bool)] = [(win, false)]
        var next = 0, sawPage = false
        var all: [Double] = [], page: [Double] = []
        // Until the page's texts are enough, or with no page, the window's.
        while next < queue.count, next < maxVisits, uptime() < end, page.count < maxSamples, sawPage || all.count < maxSamples {
            let (el, inPage) = queue[next]
            next += 1
            AXUIElementSetMessagingTimeout(el, timeout)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let vals = raw as? [AnyObject], vals.count == 4 else { continue }
            let role = vals[0] as? String ?? ""
            let r = rect(vals[2], vals[3])
            if let r, r.width > 0, r.height > 0, !r.intersects(shown) { continue }  // scrolled out of view
            if role == "AXStaticText" {
                guard let r, r.width > 0, r.height > 0 else { continue }
                let h = firstLineHeight(el).map { min($0, Double(r.height)) } ?? Double(r.height)
                if all.count < maxSamples { all.append(h) }
                if inPage { page.append(h) }
                continue
            }
            if role == "AXMenu" || role == "AXMenuBar" { continue }  // closed menus stay in some trees
            if role == "AXWebArea" { sawPage = true }
            for k in vals[1] as? [AXUIElement] ?? [] { queue.append((k, inPage || role == "AXWebArea")) }
        }
        return (all, page)
    }

    /// How high a text's first line is (points), as its app gives the first character's bounds; nil where it doesn't.
    static func firstLineHeight(_ el: AXUIElement) -> Double? {
        var first = CFRange(location: 0, length: 1)
        guard let arg = AXValueCreate(.cfRange, &first),
              let v = parameterized(el, kAXBoundsForRangeParameterizedAttribute, arg), CFGetTypeID(v) == AXValueGetTypeID()
        else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0 else { return nil }
        return Double(r.height)
    }

    /// At most this many characters of the text in an area (`text`, and `OCR.text` for text read off the
    /// screen). A long document is read with `read` instead, a page at a time.
    static let textCap = 8000
    static let textCapNote = "… (truncated; use read for a text area's whole text, or a smaller region)"

    /// The text inside `within` (global points) in reading order, one line per visual line, words unclipped:
    /// for reading values exactly (a table row, a price) without a zoomed screenshot. A text area gives just
    /// what it shows there, not what's scrolled out of view, and all of it stops at `textCap` characters,
    /// saying so.
    static func text(pid: pid_t, wid: CGWindowID, within: CGRect) -> String? {
        guard let win = window(pid: pid, wid: wid) else { return nil }
        return text(of: win, within: within)
    }

    /// `areaText` in window `wid` of `pid`: nil with no such window.
    static func areaText(pid: pid_t, wid: CGWindowID, within: CGRect) -> AreaText? {
        guard let win = window(pid: pid, wid: wid) else { return nil }
        return areaText(of: win, within: within)
    }

    /// `text` from window element `win`, at most `maxChars` characters, with `missedNote` when a text area in
    /// the area didn't say which of its lines it shows there. `budget`, `now`, `read` and `shown` are there for
    /// tests.
    static func text(of win: AXUIElement, within: CGRect, maxChars: Int = textCap, budget: TimeInterval = walkBudget,
                     now: () -> TimeInterval = uptime, read: (AXUIElement) -> [AnyObject]? = readAttrs,
                     shown: (AXUIElement, CGRect, String) -> Shown? = { shownText($0, in: $1, of: $2) }) -> String {
        let got = areaText(of: win, within: within, maxChars: maxChars, budget: budget, now: now, read: read, shown: shown)
        return got.text + (got.missed.isEmpty ? "" : "\n" + missedNote) + (got.pages.isEmpty ? "" : "\n" + pageNote)
    }

    /// For a text area in the area that doesn't say which of its lines it shows there (nor were they read off the
    /// screen): its text isn't in what was read.
    static let missedNote = "… (a text area here doesn't say which of its lines it shows: zoom in with a screenshot, "
        + "or use read for its text)"

    /// For a web page in the area that had nothing in it yet (nor was its text read off the screen): a web view
    /// builds what it tells accessibility only once asked, so its text isn't in what was read.
    static let pageNote = "… (a web page here gave no text yet: zoom in with a screenshot, or read the region again)"

    /// What `areaText` read: the text (`text`'s, notes and all, or "(no text in that area)"), the parts of the
    /// area (global points) over text areas that gave none of it, not saying which of their lines they show there,
    /// and those over web pages with nothing in them yet (`pages`: a web view builds its tree when first asked).
    /// `titleOnly`: all it read was the window's title (and its title bar's buttons), none of what the window shows.
    struct AreaText: Equatable {
        let text: String
        var missed: [CGRect] = []
        var pages: [CGRect] = []
        var titleOnly = false
    }

    /// Big enough to hold a few lines of text: a region read that gave only the window's title is doubted when
    /// it's at least this size, and a group holding nothing is no control (a button) when it is.
    static let roomy = CGSize(width: 100, height: 60)

    /// The part of area `within` (global points) over a group or scroll area of frame `frame` that holds nothing,
    /// as far as `clip` (the scroll areas it's in) lets it be seen: when the group is `roomy` or bigger and that
    /// part is 30% of the area or more. Else nil. (A web view's host holds nothing for a moment when first asked.)
    static func hollowPart(_ frame: CGRect, clip: CGRect?, within: CGRect) -> CGRect? {
        guard frame.width >= roomy.width, frame.height >= roomy.height else { return nil }
        let box = (clip.map { frame.intersection($0) } ?? frame).intersection(within)
        guard !box.isNull, box.width * box.height >= 0.3 * within.width * within.height else { return nil }
        return box
    }

    /// The subroles of a title bar's buttons: what they say is no more of the window's text than its title is.
    static let titleBarButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// The text inside `within`, as `text` gives it, and where text areas gave none (`AreaText.missed`). With
    /// nothing read but the window's title, the parts over groups holding nothing count as empty pages.
    static func areaText(of win: AXUIElement, within: CGRect, maxChars: Int = textCap, budget: TimeInterval = walkBudget,
                         now: () -> TimeInterval = uptime, read: (AXUIElement) -> [AnyObject]? = readAttrs,
                         shown: (AXUIElement, CGRect, String) -> Shown? = { shownText($0, in: $1, of: $2) }) -> AreaText {
        let area = within.insetBy(dx: -2, dy: -2)
        let inputs: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        let labelled: Set<String> = ["AXButton", "AXLink", "AXPopUpButton", "AXMenuButton", "AXCheckBox",
                                     "AXRadioButton", "AXMenuItem", "AXCell"]
        var runs: [(rect: CGRect, text: String)] = []
        var missed: [CGRect] = []
        var pages: [CGRect] = []
        var hollow: [CGRect] = []  // over groups holding nothing (`hollowPart`)
        var title: String?  // the window's, its spacing collapsed
        var titled = 0  // runs that are the window's title or its title bar's buttons
        let end = now() + budget
        var slow = false
        var clipped = false  // a text area's text was cut to what the area could show
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func asLines(_ s: String) -> String {  // a text area's lines stay lines
            s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func words(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        // `clip`: the part of the screen it can be seen in, as far as the scroll areas and web pages it's in say.
        // `inPage`: it's in a web page.
        func walk(_ el: AXUIElement, depth: Int, clip: CGRect?, inPage: Bool = false) {
            guard depth < 60, runs.count < 500, !slow else { return }
            if now() >= end { slow = true; return }
            guard let vals = read(el) else { return }
            func str(_ i: Int) -> String? {  // keeps edge spaces: pages split "380 points" / " by " / "hn_acker"
                guard let s = vals[i] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return s.replacingOccurrences(of: "\n", with: " ")
            }
            let role = str(0) ?? ""
            if role == "AXColumn" || str(1) == "AXSecureTextField" { return }
            if depth == 0 { title = str(2).map(words) }
            var rect: CGRect?
            var pt = CGPoint.zero, sz = CGSize.zero
            if CFGetTypeID(vals[6]) == AXValueGetTypeID(), CFGetTypeID(vals[7]) == AXValueGetTypeID(),
               AXValueGetValue(vals[6] as! AXValue, .cgPoint, &pt), AXValueGetValue(vals[7] as! AXValue, .cgSize, &sz) {
                rect = CGRect(origin: pt, size: sz)
            }
            if let r = rect, r.width > 0, r.height > 0, role != "AXWindow" {
                if !r.intersects(area) { return }
                if let c = clip, !r.intersects(c) { return }  // scrolled out of view: not shown in the area
            }
            func emit(_ t: String?) {
                // Count a run only if its centre is in the area, so neighbouring lines don't bleed in.
                guard let t, let r = rect, within.contains(CGPoint(x: r.midX, y: r.midY)) else { return }
                runs.append((r, t))
                if !inPage, titleBarButtons.contains(str(1) ?? "") || (title?.isEmpty == false && words(t) == title) {
                    titled += 1
                }
            }
            if role == "AXStaticText" { emit(str(4) ?? str(2)); return }
            if role == "AXTextArea", let r = rect, let whole = vals[4] as? String, !blank(whole) {
                // Just what it shows in the area. A text view's frame is all its text (far more than a document's
                // window shows): what's shown of it is that clipped to the scroll area it's in.
                let seen = clip.map { r.intersection($0) } ?? r
                let box = seen.intersection(within)
                guard !box.isNull, box.width >= 1, box.height >= 1 else { return }
                let room = fits(box.size), centred = within.contains(CGPoint(x: seen.midX, y: seen.midY))
                // A good part of what it shows is in the area (not a sliver of its edge): its lines there are wanted.
                let over = centred || box.height >= seen.height / 2
                let shortText = (whole as NSString).length <= room
                if shortText, over { runs.append((box, asLines(whole))); return }  // fits there: given whole
                switch shown(el, box, whole) {
                case .area(let t)?:  // the characters inside the area itself, so its centre needn't be in it
                    if !blank(t) { runs.append((box, asLines(t))) }
                case .lines(let lines)?:  // its lines in view, each where it is: those in the area
                    let t = linesIn(lines, box).joined(separator: "\n")
                    if !blank(t) { runs.append((box, asLines(t))) }
                case .visible(let t)?:  // all it shows, which may be more than the area
                    if over, !blank(t) { runs.append((box, asLines(t))) }
                    else if !over, box.height >= 8 { missed.append(box) }
                case nil where !shortText && centred:  // it doesn't say what's shown: the start, as much as the area could show
                    runs.append((box, asLines(head(whole, room)) + "…"))
                    clipped = true
                case nil:
                    if box.height >= 8 { missed.append(box) }  // which lines are there isn't known
                }
                return
            }
            if inputs.contains(role) { emit(str(4) ?? str(10)); return }
            let before = runs.count
            var inner = clip
            if role == "AXScrollArea" || role == "AXWebArea", let r = rect, r.width > 0, r.height > 0 {
                inner = clip.map { $0.intersection(r) } ?? r
            }
            let kids = vals[5] as? [AXUIElement] ?? []
            for k in kids { walk(k, depth: depth + 1, clip: inner, inPage: inPage || role == "AXWebArea") }
            if runs.count == before, labelled.contains(role) { emit(str(2) ?? str(3)) }  // e.g. an icon button
            // A web page with nothing in it yet (a web view builds its tree when first asked): its text isn't known.
            // Not a frame in a page (an empty ad or tracking frame has nothing in it either).
            if role == "AXWebArea", kids.isEmpty, !inPage, let r = rect, r.width > 0, r.height > 0 {
                let box = (inner ?? r).intersection(within)
                if !box.isNull, box.width >= 1, box.height >= 8 { pages.append(box) }
            }
            // A group holding nothing (its children unreadable or none) over a good part of the area: a web view's
            // host before it has built its page. Never a control, nor a part of a page (an empty box in it).
            if role == "AXGroup" || role == "AXScrollArea", kids.isEmpty, !inPage, let r = rect,
               let box = hollowPart(r, clip: clip, within: within) {
                hollow.append(box)
            }
        }
        walk(win, depth: 0, clip: nil)
        // All it read was the window's title: what's over groups holding nothing is unknown, as over an empty page.
        let titleOnly = !runs.isEmpty && titled == runs.count
        if titleOnly { pages += hollow }

        let unique = distinct(runs)
        var lines: [[(rect: CGRect, text: String)]] = []
        for run in unique.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let first = lines.last?.first, abs(first.rect.midY - run.rect.midY) < max(3, min(first.rect.height, run.rect.height) / 2) {
                lines[lines.count - 1].append(run)
            } else {
                lines.append([run])
            }
        }
        let out = lines.map { line -> String in
            var s = ""
            var prev: CGRect?
            for r in line.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                if let p = prev, r.rect.minX - p.maxX > 1 { s += " " }  // runs that touch are one word
                s += r.text
                prev = r.rect
            }
            return s.components(separatedBy: "\n")
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                .joined(separator: "\n")
        }
        // (Out of time with nothing read, it's read off the screen, as for an app that exposes no text.)
        if out.isEmpty { return AreaText(text: "(no text in that area)", missed: missed, pages: pages) }
        let all = out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return AreaText(text: capped(all, maxChars, note: textCapNote, cut: clipped)
            + (slow ? "\n… (cut short: the app answered slowly; zoom in with a screenshot for the rest)" : ""), missed: missed,
            pages: pages, titleOnly: titleOnly)
    }

    /// Of a text area's lines in view (`lines`, each where it is on screen), the ones in `box` (global points),
    /// in order: those whose middle is between its top and bottom, and that reach across into it (a blank line,
    /// with no width, goes by its middle alone). Their text without the line break that ends them.
    static func linesIn(_ lines: [ShownLine], _ box: CGRect) -> [String] {
        lines.filter { l in
            let r = l.rect
            guard r.midY >= box.minY, r.midY <= box.maxY else { return false }
            return r.width < 1 || (r.minX < box.maxX && r.maxX > box.minX)
        }.map { l in
            var t = Substring(l.text)
            while let last = t.last, last.isNewline { t = t.dropLast() }
            return String(t)
        }
    }

    /// `s` cut to at most `limit` characters (at the end of a line if one ends in the last fifth of them),
    /// then `note` on a line of its own. With the note anyway if it was `cut` already; else `s` as it is.
    static func capped(_ s: String, _ limit: Int, note: String, cut: Bool = false) -> String {
        guard s.count > limit else { return cut ? s + "\n" + note : s }
        var kept = s.prefix(max(0, limit))
        if let nl = kept.lastIndex(of: "\n"), kept.distance(from: kept.startIndex, to: nl) >= limit * 4 / 5 {
            kept = kept[..<nl]
        }
        return String(kept) + "\n" + note
    }

    /// `runs` without the same text again at (nearly) the same place: within `slack` points across and
    /// down, so an element reached twice, or the same label a point or so off, is given once.
    static func distinct(_ runs: [(rect: CGRect, text: String)], slack: CGFloat = 3) -> [(rect: CGRect, text: String)] {
        var at: [String: [CGPoint]] = [:]
        return runs.filter { run in
            let p = run.rect.origin
            if at[run.text]?.contains(where: { abs($0.x - p.x) < slack && abs($0.y - p.y) < slack }) == true { return false }
            at[run.text, default: []].append(p)
            return true
        }
    }

    /// About how many characters a box this size (points) can show, generously (small text, tight lines):
    /// a text area's text longer than that is more than it shows there.
    static func fits(_ size: CGSize) -> Int {
        max(100, Int(size.width / 4) * max(1, Int(size.height / 10)))
    }

    /// The start of `s`, at most `n` characters, ending at the end of a word if one ends near there.
    static func head(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let part = s.prefix(max(0, n))
        if part.endIndex < s.endIndex, s[part.endIndex].isWhitespace { return String(part) }
        if let space = part.lastIndex(where: \.isWhitespace), part.distance(from: space, to: part.endIndex) <= 40 {
            return String(part[..<space])
        }
        return String(part)
    }

    /// What a text area shows of its text, as far as its app says.
    enum Shown: Equatable {
        case area(String)  // the characters inside the area being read
        case lines([ShownLine])  // its lines scrolled into view (down to the area's bottom at least), each where it is
        case visible(String)  // the ones scrolled into view: can be more than the area
    }

    /// One line of a text area's text in view, and where it is on screen (global points).
    struct ShownLine: Equatable {
        let text: String
        let rect: CGRect
    }

    /// What text area `el` shows of its text `whole` in `box` (global points: its part of the area being
    /// read). The characters from the one at the box's top-left corner to the one at its bottom-right
    /// (`AXRangeForPosition`), kept to those scrolled into view (`AXVisibleCharacterRange`) and widened to
    /// whole words; else the lines in view, each where it is (`shownLines`); else just the characters in
    /// view; nil if the app tells none of that. Web engines (WebKit, Chromium, Gecko) give the whole text as
    /// the part in view whatever is scrolled out, which tells nothing. AppKit's text views give no character
    /// for a point off the text (the margin at a line's start, the blank past its end): the lines tell then.
    static func shownText(_ el: AXUIElement, in box: CGRect, of whole: String, budget: TimeInterval = 0.5) -> Shown? {
        let length = (whole as NSString).length
        let visible = axRange(value(el, kAXVisibleCharacterRangeAttribute)).flatMap { v in
            v.location <= 0 && v.length >= length ? nil : v
        }
        func at(_ x: CGFloat, _ y: CGFloat) -> CFRange? {
            var p = CGPoint(x: x, y: y)
            guard let pv = AXValueCreate(.cgPoint, &p),
                  let r = axRange(parameterized(el, kAXRangeForPositionParameterizedAttribute, pv)),
                  r.location >= 0, r.location <= length else { return nil }  // (not NSNotFound: no character there)
            return r
        }
        if let start = at(box.minX + 1, box.minY + 1), let end = at(box.maxX - 1, box.maxY - 1),
           let r = between(start, end, within: visible ?? CFRange(location: 0, length: length)),
           let s = substring(el, wholeWords(r, of: whole), whole) {
            return .area(s)
        }
        guard let v = visible, v.length > 0 else { return nil }
        if let lines = shownLines(el, v, of: whole, to: box.maxY, budget: budget) { return .lines(lines) }
        return substring(el, v, whole).map { .visible($0) }
    }

    /// At most this many lines of a text area are asked where they are (`shownLines`).
    static let shownLinesCap = 400

    /// The lines of text area `el`'s text `whole` in view (`v`), each with where it is on screen
    /// (`AXBoundsForRange`), from the first down to the first past `bottom` (global points). Its lines as drawn,
    /// where the app numbers them (`AXLineForIndex`, `AXRangeForLine`: a long paragraph wraps onto several),
    /// else the text's own lines. Nil if the app says where none is, or `budget` (s) or `shownLinesCap` ran out
    /// before `bottom`: then which lines are there isn't known.
    static func shownLines(_ el: AXUIElement, _ v: CFRange, of whole: String, to bottom: CGFloat,
                           budget: TimeInterval) -> [ShownLine]? {
        let ns = whole as NSString
        let lo = max(0, v.location), hi = min(ns.length, v.location + v.length)
        guard hi > lo else { return nil }
        let end = uptime() + budget
        func number(_ attr: String, _ n: Int) -> AnyObject? {
            var i = n
            guard let arg = CFNumberCreate(nil, .cfIndexType, &i) else { return nil }
            var out: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, arg, &out) == .success ? out : nil
        }
        // The ranges of its lines in view, in order.
        var ranges: [CFRange] = []
        if let first = (number(kAXLineForIndexParameterizedAttribute, lo) as? NSNumber)?.intValue,
           let last = (number(kAXLineForIndexParameterizedAttribute, hi - 1) as? NSNumber)?.intValue, last >= first {
            for line in first...min(last, first + shownLinesCap - 1) {
                guard let r = axRange(number(kAXRangeForLineParameterizedAttribute, line)) else { ranges = []; break }
                ranges.append(r)
            }
        }
        if ranges.isEmpty {
            var at = lo
            ns.enumerateSubstrings(in: NSRange(location: lo, length: hi - lo), options: [.byLines, .substringNotRequired]) { _, _, r, stop in
                ranges.append(CFRange(location: r.location, length: r.length))
                at = r.location + r.length
                if ranges.count >= shownLinesCap { stop.pointee = true }
            }
            if at < hi, ranges.count < shownLinesCap { ranges.append(CFRange(location: at, length: hi - at)) }
        }
        var out: [ShownLine] = []
        var reached = false  // a line past `bottom`
        for r in ranges {
            if uptime() >= end { return nil }
            let a = max(r.location, lo), b = min(r.location + max(r.length, 0), hi)
            guard b > a else { continue }
            var cr = CFRange(location: a, length: b - a)
            guard let rv = AXValueCreate(.cfRange, &cr),
                  let bv = parameterized(el, kAXBoundsForRangeParameterizedAttribute, rv), CFGetTypeID(bv) == AXValueGetTypeID()
            else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(bv as! AXValue, .cgRect, &rect), rect.height > 0 else { continue }
            let text = ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: a, length: b - a)))
            out.append(ShownLine(text: text, rect: rect))
            if rect.minY > bottom { reached = true; break }
        }
        guard !out.isEmpty else { return nil }
        // Every line in view was asked, or one past the bottom was reached: none of the area's is missing.
        let all = ranges.count < shownLinesCap || ranges.last.map { $0.location + $0.length >= hi } == true
        return reached || all ? out : nil
    }

    /// The characters from the one at a box's top-left corner (`start`) to the one at its bottom-right
    /// (`end`), both included, kept to `base`. nil when that tells nothing: both corners on one character
    /// (the box over blank space past the end of the text) or the wrong way round, or none of `base` left.
    static func between(_ start: CFRange, _ end: CFRange, within base: CFRange) -> CFRange? {
        guard start.location >= 0, end.location > start.location else { return nil }
        let top = base.location + base.length
        let lo = max(start.location, base.location)
        let hi = end.location >= top ? top : min(end.location + max(end.length, 0), top)  // (no overflow past `top`)
        return hi > lo ? CFRange(location: lo, length: hi - lo) : nil
    }

    /// `r` widened to whole words of `text` (UTF-16 offsets, as accessibility counts them): a corner can
    /// fall inside a word or a number, and half a price is worse than a word more.
    static func wholeWords(_ r: CFRange, of text: String) -> CFRange {
        let ns = text as NSString
        var lo = min(max(r.location, 0), ns.length)
        var hi = min(max(r.location + r.length, lo), ns.length)
        func space(_ i: Int) -> Bool {
            UnicodeScalar(ns.character(at: i)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        if lo < ns.length, !space(lo) {
            var n = 0
            while lo > 0, !space(lo - 1), n < 40 { lo -= 1; n += 1 }
        }
        if hi > lo, !space(hi - 1) {
            var n = 0
            while hi < ns.length, !space(hi), n < 40 { hi += 1; n += 1 }
        }
        return CFRange(location: lo, length: hi - lo)
    }

    /// Characters `r` of text area `el`'s text as it gives them (`AXStringForRange`), else cut from its
    /// value `whole`.
    static func substring(_ el: AXUIElement, _ r: CFRange, _ whole: String) -> String? {
        var cr = r
        if let rv = AXValueCreate(.cfRange, &cr),
           let s = parameterized(el, kAXStringForRangeParameterizedAttribute, rv) as? String { return s }
        let ns = whole as NSString
        guard r.location >= 0, r.length >= 0, r.location + r.length <= ns.length else { return nil }
        return ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: r.location, length: r.length)))
    }

    static func parameterized(_ el: AXUIElement, _ attr: String, _ arg: AXValue) -> AnyObject? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, arg, &out) == .success ? out : nil
    }

    static func axRange(_ v: AnyObject?) -> CFRange? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    /// Roles worth acting on, for the `interactive` outline.
    static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXTab",
        "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXDateField", "AXSwitch", "AXToggle", "AXCell",
        "AXRow", "AXOutlineRow",
    ]

    /// Sheets and dialogs: the `interactive` outline keeps their lines (with a heading that says something, and
    /// the text of an alert or status) to say where things are.
    static let dialogs: Set<String> = ["AXSheet", "AXDialog"]
    /// A web page's dialogs (`role="dialog"`, `"alertdialog"`): groups, shown as the dialogs they are.
    static let webDialogs: Set<String> = ["AXApplicationDialog", "AXApplicationAlertDialog"]
    /// A web page's alerts and status lines (`role="alert"`, `"status"`): an error, a result.
    static let liveRegions: Set<String> = ["AXApplicationAlert", "AXApplicationStatus"]
    /// Roles that, with no name of their own, are called what the texts in them say (a web page's link or button
    /// whose words are a text inside it): those texts aren't lines of their own then.
    static let takesChildText: Set<String> = ["AXHeading", "AXButton", "AXLink", "AXTab", "AXCheckBox", "AXRadioButton"]
    /// Where an image saying what its container says adds nothing (`<a aria-label="GitHub"><img alt="GitHub">`).
    static let saysItsImage: Set<String> = ["AXLink", "AXButton", "AXMenuButton", "AXPopUpButton"]

    private static func buildOutline(pid: pid_t, wid: CGWindowID, within: CGRect?, maxElements: Int,
                                     maxChars: Int, interactive: Bool = false) -> String? {
        guard let win = window(pid: pid, wid: wid) else { return nil }
        var visible = (frame(win) ?? Windows.info(wid)?.frame ?? .infinite).insetBy(dx: -2, dy: -2)
        if let within { visible = visible.intersection(within.insetBy(dx: -2, dy: -2)) }
        return outline(of: win, registry(wid), visible: visible, menus: menuWindows(pid), maxElements: maxElements,
                       maxChars: maxChars, interactive: interactive)
    }

    /// The outline of window element `win`, its elements in `visible` (global points) numbered in `reg`.
    /// `menus`: where the app's open menus are. `budget`, `now`, `read` and `presses` are there for tests.
    ///
    /// A control with no name of its own is called what titles it (`AXTitleUIElement`: a form's "Email" beside
    /// its field), and that text's line is left out when it's next to the control and says nothing more. A link,
    /// button, tab, checkbox, radio button or heading with no name is called what the texts in it say, and
    /// those aren't lines of their own (but for one under a heading that takes a press: it keeps its number).
    /// The name an element has itself is still what tells it's the same one later (`Node.label`).
    ///
    /// The walk gathers the lines first, then they're shaped as a tree (`shape`: empty containers and hidden bits
    /// go, texts side by side become one line with their links in it) and written out (`write`). Plain text has no
    /// number; a text keeps one when it takes a press (a clickable text alone on its line) or is cut short (for
    /// `read`). Numbers stay the element's across looks (`Registry`). The window itself has no line (the status
    /// line names it), nor has the title of its page when that's the window's.
    static func outline(of win: AXUIElement, _ reg: Registry, visible: CGRect, menus: [CGRect], maxElements: Int,
                        maxChars: Int, interactive: Bool, budget: TimeInterval = walkBudget,
                        now: () -> TimeInterval = uptime, read: (AXUIElement) -> [AnyObject]? = readAttrs,
                        presses: (AXUIElement) -> Bool = canPress) -> String {
        var items: [Entry] = []  // the lines found, in order, each at the depth the walk was at
        var more = false  // the walk stopped with more to come: far past the caps already
        var estimate = 0  // the most the lines found so far can come to written out, in characters
        var counted = 0  // the elements found so far that will have numbers (but for texts: few keep one)
        let end = now() + budget
        var slow = false
        var early: [AXUIElement: [AnyObject]] = [:]  // read before the walk got to them (a label): not read again
        var texts: [AXUIElement: String] = [:]  // the texts walked so far, and what they say
        var textsIn: [AXUIElement: [String]] = [:]  // the same by the element they're in (a label element's texts)
        var hoisted = Set<AXUIElement>()  // texts shown as the label of the control they're in instead
        var pressed = Set<AXUIElement>()  // texts that take a press under a heading they name: kept, with numbers
        // Text lines not out yet (three at most): the control right after them may be what they title.
        var held: [(el: AXUIElement, parent: AXUIElement?, label: String, entry: Entry)] = []
        var titledNext: (el: AXUIElement, label: String)?  // the control just out is titled by what comes after it
        var windowTitle: String?

        func peek(_ el: AXUIElement) -> [AnyObject]? {
            if let v = early[el] { return v }
            let v = read(el)
            if let v { early[el] = v }
            return v
        }

        /// Adds a line to those found. False once far past the caps: what's left isn't walked (the caps
        /// themselves are kept as the lines are written, shorter than found: twice them is plenty).
        func put(_ e: Entry) -> Bool {
            items.append(e)
            switch e.kind {
            case .text: estimate += min(e.body.count, proseClip) + 2
            case .element: estimate += e.body.count + 7; counted += 1
            default: estimate += e.body.count + 1
            }
            if counted > maxElements || estimate > 2 * maxChars { more = true; return false }
            return true
        }

        func isOrIn(_ el: AXUIElement, _ parent: AXUIElement?, _ title: AXUIElement) -> Bool {
            CFEqual(el, title) || parent.map { CFEqual($0, title) } == true
        }

        /// Puts out the held text lines, but for those at the end that are (or are in) `title`, what titles the
        /// control going out next, when its `label` says what they say. False once over budget.
        func flush(for title: AXUIElement? = nil, label: String? = nil) -> Bool {
            var out = held
            held = []
            if let title, let label {
                while let h = out.last, isOrIn(h.el, h.parent, title), repeats(h.label, in: label) { out.removeLast() }
            }
            for h in out {
                guard put(h.entry) else { return false }
            }
            return true
        }

        /// What `title` (the element titling a control) says: a text walked already, or the texts walked in it,
        /// else read now (and kept for when the walk gets there).
        func titleLabel(_ title: AXUIElement) -> String? {
            if let t = texts[title] { return t }
            if let ts = textsIn[title], ts.count <= 4 {
                let s = ts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return s.isEmpty ? nil : s
            }
            return titleText(title) { peek($0) }
        }

        /// The words of the texts among `kids` (an unlabelled control's or heading's children); the texts whose lines
        /// that says already (blank ones too); and (`ownNumber`, under a heading, which has no number) those that
        /// take a press, which keep their lines and numbers. Nil if there are no words, or many children, or more
        /// words than a label shows.
        func childText(_ kids: [AXUIElement], ownNumber: Bool) -> (label: String, said: [AXUIElement], pressed: [AXUIElement])? {
            guard !kids.isEmpty, kids.count <= 6 else { return nil }
            var parts: [(text: String, rect: CGRect?)] = []
            var els: [AXUIElement] = []
            for k in kids {
                guard let v = peek(k), v[0] as? String == "AXStaticText" else { continue }
                let r = AX.rect(v[6], v[7])
                if let r, r.width > 0, r.height > 0, !r.intersects(visible) { continue }
                let t = textSays(v) ?? ""
                els.append(k)
                if !t.allSatisfy(\.isWhitespace) { parts.append((t, r)) }
            }
            let label = joinRuns(parts)
            guard !label.isEmpty, label.count <= 100 else { return nil }
            let pressing = ownNumber ? els.filter(presses) : []
            return (label, els.filter { el in !pressing.contains { CFEqual($0, el) } }, pressing)
        }

        /// `parentValue`: what the field or menu it's in holds; `web`: it's in a web page.
        func walk(_ el: AXUIElement, depth: Int, indent: Int, parentLabel: String?, parent: AXUIElement? = nil,
                  parentRole: String? = nil, parentValue: String? = nil, live: Bool = false, web: Bool = false) {
            if more || slow || depth > 60 { return }
            if now() >= end { slow = true; return }
            guard let vals = early.removeValue(forKey: el) ?? read(el) else { return }
            func str(_ i: Int) -> String? {
                if let s = vals[i] as? String, !s.isEmpty { return s }
                return nil
            }
            let role = str(0) ?? "AXUnknown"
            if role == "AXColumn" { return }  // a table's columns hold the same cells as its rows
            let subrole = str(1)
            let rect = AX.rect(vals[6], vals[7])
            // Skip subtrees scrolled out of view (huge win for long web pages and lists).
            if let r = rect, r.width > 0, r.height > 0, !r.intersects(visible), role != "AXWindow" { return }
            // A pop-up's menu stays in the tree once it has been opened: only an open one is shown.
            if role == "AXMenu", !menuOpen(rect, menus) { return }

            let ownName = str(2) ?? str(3) ?? str(10)
            let title = ownName ?? str(12)  // its own name: how to tell it's the same one later
            if role == "AXWindow", depth == 0 { windowTitle = str(2) }
            var valueText: String?
            if let s = vals[4] as? String { valueText = s }
            else if let n = vals[4] as? NSNumber, CFGetTypeID(vals[4]) != AXValueGetTypeID() { valueText = compact(n.doubleValue) }
            let focused = (vals[8] as? Bool) == true
            let enabled = (vals[9] as? Bool) ?? true
            let selected = (vals[11] as? Bool) == true

            var name = roleNames[role] ?? String(role.dropFirst(2)).lowercased()
            if subrole == "AXTabButton" { name = "tab" }
            if subrole == "AXSearchField" { name = "search" }
            if subrole == "AXSecureTextField" { name = "password"; valueText = nil }
            if subrole == "AXCloseButton" || subrole == "AXMinimizeButton" || subrole == "AXZoomButton"
                || subrole == "AXFullScreenButton" { name = "" }  // traffic lights: noise
            let webDialog = webDialogs.contains(subrole ?? "")
            if webDialog { name = "dialog" }

            let wraps = transparent.contains(role) && !webDialog  // nesting, and nothing more unless it's labelled
            // Labelled by a name of its own: not by a tooltip alone, nor by the window's title over again above its
            // page (Firefox's group round the whole window).
            var wrapName = ownName
            if wraps, !web, role != "AXWindow", let n = wrapName, let w = windowTitle, repeats(n, in: w), repeats(w, in: n) {
                wrapName = nil
            }
            let isTransparent = wraps && wrapName == nil
            let isText = role == "AXStaticText"
            var label = (wraps ? wrapName : title) ?? (isText ? valueText : nil)
            if isText, let l = label, !l.allSatisfy(\.isWhitespace) {
                texts[el] = l
                if let parent { textsIn[parent, default: []].append(l) }
            }
            var include = !isTransparent && !name.isEmpty
            if role == "AXWindow" { include = false }  // the status line names the window
            if isText && (label?.isEmpty ?? true) { include = false }
            // Text that just repeats its parent's label (link "Docs" > text "Docs") adds nothing, unless it's what
            // takes a press there; nor does text showing what the field or menu it's in holds (a combo box's value).
            if isText, let l = label, let pl = parentLabel, !pressed.contains(el),
               pl.contains(l.trimmingCharacters(in: .whitespaces)) || repeats(l, in: pl) {
                include = false
            }
            if isText, let l = label, let pv = parentValue, !pressed.contains(el),
               !l.allSatisfy(\.isWhitespace), l.trimmingCharacters(in: .whitespaces) == pv.trimmingCharacters(in: .whitespaces) {
                include = false
            }
            if isText, hoisted.contains(el) { include = false }  // shown as the label of the control it's in
            if role == "AXListMarker" { include = false }
            if role == "AXImage" && title == nil { include = false }
            // Nor does an image saying what the link or button it's in says (<a aria-label="GitHub"><img alt="GitHub">).
            if role == "AXImage", let l = title, let pl = parentLabel, saysItsImage.contains(parentRole ?? ""), repeats(l, in: pl) {
                include = false
            }
            if (role == "AXRow" || role == "AXCell" || role == "AXOutlineRow") && title == nil { include = false }
            if wraps { include = include && wrapName != nil }

            // With no name of its own, a control is called what titles it; or else a link, button or heading is
            // called what the texts in it say (whose lines are left out then).
            var titleEl: AXUIElement?
            var inside: (said: [AXUIElement], pressed: [AXUIElement]) = ([], [])
            var roomy = isText  // its label is clipped as a text's is, not shorter: it's the text of one
            if include, !isText, !wraps {
                titleEl = titleElement(vals).flatMap { CFEqual($0, el) ? nil : $0 }
                if str(2) == nil, str(3) == nil, let te = titleEl, let t = titleLabel(te) {
                    label = t
                    roomy = true
                }
                if label == nil, takesChildText.contains(role),
                   let found = childText(vals[5] as? [AXUIElement] ?? [], ownNumber: role == "AXHeading") {
                    label = found.label
                    inside = (found.said, found.pressed)
                    roomy = true
                }
            }
            // The interactive outline keeps what says where things are, too.
            let landmark = dialogs.contains(role) || webDialog || (isText && live)
                || (role == "AXHeading" && !(label ?? "").allSatisfy(\.isWhitespace))
            if interactive && !actionable.contains(role) && subrole != "AXTabButton" && !landmark { include = false }
            if include {
                hoisted.formUnion(inside.said)
                pressed.formUnion(inside.pressed)
            }

            var childIndent = indent
            if include {
                var e = Entry(kind: .element, depth: indent, el: el, parent: parent, rect: rect)
                e.actionable = actionable.contains(role) || subrole == "AXTabButton"
                if transparent.contains(role) || role == "AXToolbar" || role == "AXTabGroup" || role == "AXTable"
                    || role == "AXOutline" || role == "AXList" || role == "AXWebArea" || role == "AXHeading"
                {
                    // Structural: not actionable, no number. A page's title is the window's, said by the status line
                    // already (a page in a frame keeps its own).
                    var shown = label
                    if role == "AXWebArea", !web, let l = shown, let w = windowTitle, repeats(l, in: w) { shown = nil }
                    e.kind = .container
                    e.body = name + (shown.map { " \"\(clipLabel($0, roomy ? 100 : 60))\"" } ?? "")
                    e.labelled = shown != nil
                    e.landmark = webDialog
                    e.fold = role == "AXHeading"
                } else if isText {
                    e.kind = .text
                    e.body = label ?? ""
                    e.node = Node(element: el, frame: rect, role: role, label: nil, name: name, parent: parent, shown: label)
                    e.presses = pressed.contains(el)
                } else {
                    e.node = Node(element: el, frame: rect, role: role, label: title, name: name, parent: parent, shown: label)
                    var body = name
                    if let l = label { body += " \"\(clipLabel(l, roomy ? 100 : 60))\"" }
                    var state = ""
                    if let v = valueText, !v.isEmpty, v != label {
                        if let s = stateWord(role: role, subrole: subrole, value: v, numeric: vals[4] is NSNumber) {
                            if !(s == " selected" && selected) { state = s }
                        } else {
                            body += " =\"\(clipLabel(v, 80))\""
                        }
                    }
                    body += state
                    if focused { body += " focused" }
                    if selected { body += " selected" }
                    if !enabled { body += " disabled" }
                    e.body = body
                    e.landmark = dialogs.contains(role)
                    // A link can go in a line of text as `[label](#n)`, its value (a web address) aside.
                    if role == "AXLink", let l = label, !l.allSatisfy(\.isWhitespace), !focused, !selected, enabled {
                        e.inline = clipLabel(l, roomy ? 100 : 60)
                    }
                }
                if isText {
                    if let t = titledNext, isOrIn(el, parent, t.el), let l = label, repeats(l, in: t.label) {
                        // What titles the control just out, after it: said already.
                    } else {
                        titledNext = nil
                        held.append((el, parent, label ?? "", e))
                        if held.count > 3 {
                            let h = held.removeFirst()
                            if !put(h.entry) { return }
                        }
                    }
                } else {
                    guard flush(for: titleEl, label: label), put(e) else { return }
                    titledNext = nil
                    if let te = titleEl, let l = label, texts[te] == nil, textsIn[te] == nil { titledNext = (te, l) }
                }
                childIndent += 1
            }
            if isText { return }  // static text children are just text runs
            if let kids = vals[5] as? [AXUIElement] {
                let inLive = live || liveRegions.contains(subrole ?? "")
                // (Under the window, which has no line, texts saying its title say nothing new either.)
                let below = include ? label : (role == "AXWindow" ? title : parentLabel)
                for k in kids {
                    walk(k, depth: depth + 1, indent: childIndent, parentLabel: below, parent: el,
                         parentRole: include ? role : parentRole, parentValue: include ? valueText : parentValue,
                         live: inLive, web: web || role == "AXWebArea")
                }
            }
        }

        walk(win, depth: 0, indent: 0, parentLabel: nil)
        items += held.map(\.entry)  // what's still held goes too (the caps are kept as the lines are written)
        held = []

        /// Whether a text takes a press, asked once per element (the answer's kept in `reg`).
        func takesPress(_ el: AXUIElement) -> Bool {
            if let b = reg.presses[el] { return b }
            let b = presses(el)
            if reg.presses.count >= 4000 { reg.presses.removeAll() }
            reg.presses[el] = b
            return b
        }
        let shaped = shape(tree(items), presses: { takesPress($0) })

        var lines: [String] = []
        var numbered: [(Int, String)] = []
        var unnumbered: [(String, String)] = []
        var keyed: [OutlineDiff.Line] = []
        var again: [String: Int] = [:]  // how often each unnumbered line has come so far
        var seen = Set<Int>()
        var chars = 0  // what the lines take but for their indents
        var cut = false

        /// Writes out `e`'s line at `depth`. False once past a cap.
        func line(_ e: Entry, depth: Int) -> Bool {
            var ids: [(Int, String)] = []
            var own: [OutlineDiff.Line] = []  // its elements' own lines, for what changed
            /// `shows`: an interactive outline shows it too (a control, a sheet or dialog).
            func number(_ n: Node, _ body: String, shows: Bool = false) -> Int {
                let id = reg.number(n)
                ids.append((id, "#\(id) " + body))
                own.append(OutlineDiff.Line(.id(id), "#\(id) " + body, inline: e.kind == .run, interactive: shows))
                return id
            }
            var text: String
            switch e.kind {
            case .container:
                text = e.body
            case .element:
                text = "#\(number(e.node!, e.body, shows: e.actionable || e.landmark)) " + e.body
            case .text:
                let (shown, short) = prose(e.body)
                if e.presses || short {
                    let body = "text \"\(shown)\""
                    text = "#\(number(e.node!, body)) " + body
                } else {
                    text = bareLine(neutral(shown))
                }
            case .run:
                var segments: [Segment] = []
                for p in e.parts {
                    let lead = p.body.first?.isWhitespace == true, trail = p.body.last?.isWhitespace == true
                    if p.kind == .text {
                        let (shown, short) = prose(p.body)
                        if p.presses {
                            let id = number(p.node!, "text \"\(shown)\"")
                            segments.append(("[\(neutral(shown))](#\(id))", lead, trail, p.rect))
                        } else if short {
                            // Cut short: the rest is read by its number.
                            let id = number(p.node!, "text \"\(shown)\"")
                            let some = shown.hasSuffix("…") ? String(shown.dropLast()) : shown
                            segments.append((neutral(some) + "[…](#\(id))", lead, trail, p.rect))
                        } else {
                            segments.append((neutral(shown), lead, trail, p.rect))
                        }
                    } else {
                        let id = number(p.node!, p.body, shows: p.actionable || p.landmark)
                        segments.append(("[\(neutral(p.inline ?? ""))](#\(id))", false, false, p.rect))
                    }
                }
                text = bareLine(joinSegments(segments))
            }
            text = e.lead + text
            chars += text.count + 1
            if numbered.count + ids.count > maxElements || chars > maxChars { cut = true; return false }
            lines.append(String(repeating: " ", count: min(depth, indentCap)) + text)
            numbered += ids
            seen.formUnion(ids.map(\.0))
            if ids.isEmpty || e.kind == .run {
                let n = (again[text] ?? 0) + 1
                again[text] = n
                let key = n == 1 ? text : "\(text) (\(n))"
                unnumbered.append((key, text))
                keyed.append(OutlineDiff.Line(.text(key), text))
            }
            keyed += own
            return true
        }

        func write(_ es: [Entry], depth: Int) -> Bool {
            for e in es {
                guard line(e, depth: depth), write(e.kids, depth: depth + 1) else { return false }
            }
            return true
        }

        _ = write(shaped, depth: 0)
        reg.lines = numbered
        reg.unnumbered = unnumbered
        reg.keyed = keyed
        reg.cutShort = slow
        reg.truncated = more || cut
        if !slow { reg.prune(keeping: seen) }  // what a walk cut short didn't reach may still be there: keep its numbers
        if more || cut { lines.append(truncatedNote) }
        if slow { lines.append("… (outline cut short: the app answered slowly; look again later or use a screenshot)") }
        return lines.joined(separator: "\n")
    }

    /// The note an outline that ran past its caps ends with (the rest of the window isn't in it).
    static let truncatedNote = "… (truncated; zoom with region or use a screenshot)"
    /// How much of a text an outline shows (a paragraph's words between its links, say): more than a control's
    /// label, as reading it is often the point. A text cut short keeps its number, for `read`.
    static let proseClip = 200
    /// How long a web address can be in an outline before it's cut in the middle (`shortURL`).
    static let urlClip = 60
    /// How far an outline indents: lines deeper down stay at this depth.
    static let indentCap = 6

    /// A line of an outline between the walk and the writing: what the walk found, as a tree (by depth), shaped
    /// (`shape`), then written out.
    struct Entry {
        enum Kind { case element, container, text, run }
        var kind: Kind
        var depth = 0  // how deep the walk found it, in lines
        let el: AXUIElement
        var parent: AXUIElement?  // the element it's in: only what's side by side in one element is one line
        var rect: CGRect?
        var body = ""  // what follows an element's number; all of a container's line; a text's words, as it has them
        var node: Node?  // an element's, numbered as it's written; a text's, numbered only if it takes a press or is cut
        var presses = false  // a text that takes a press: it keeps its number
        var inline: String?  // a link's label, when it can go in a line of text: `[label](#n)`
        var actionable = false
        var labelled = false  // a container with a name of its own
        var landmark = false  // a sheet or dialog: kept, empty or round one line
        var fold = false  // a heading: with no name, it goes on the front of the one line in it
        var lead = ""  // what goes before its line: "heading "
        var parts: [Entry] = []  // a run's texts and links, in order
        var kids: [Entry] = []

        init(kind: Kind, depth: Int = 0, el: AXUIElement, parent: AXUIElement?, rect: CGRect?) {
            (self.kind, self.depth, self.el, self.parent, self.rect) = (kind, depth, el, parent, rect)
        }
    }

    /// The walk's lines (in order, with depths) as a tree.
    static func tree(_ flat: [Entry]) -> [Entry] {
        var i = 0
        func kids(_ depth: Int) -> [Entry] {
            var out: [Entry] = []
            while i < flat.count, flat[i].depth >= depth {
                var e = flat[i]
                i += 1
                e.kids = kids(e.depth + 1)
                out.append(e)
            }
            return out
        }
        return kids(0)
    }

    /// The tree made shorter, from the bottom up. What has no size, nothing in it, and can't be acted on goes (a web
    /// page's hidden bits); so does a container with no name left with nothing in it; one left round a single line
    /// gives way to it (a heading goes on that line's front). Texts side by side in one element, with the links among
    /// them, become one line (`merged`), and a blank text left alone goes. `presses`: whether a text takes a press,
    /// asked only of a line's one text: the texts of a paragraph go with the paragraph, whatever a press on them does.
    static func shape(_ kids: [Entry], presses: (AXUIElement) -> Bool) -> [Entry] {
        var out: [Entry] = []
        for var k in kids {
            k.kids = shape(k.kids, presses: presses)
            if k.kids.isEmpty, !k.actionable, let r = k.rect, r.width == 0 || r.height == 0 { continue }
            if k.kind == .container, !k.labelled, !k.landmark {
                if k.kids.isEmpty { continue }
                if k.kids.count == 1, !k.fold {
                    out.append(k.kids[0])
                    continue
                }
                if k.kids.count == 1, k.kids[0].kind != .container {
                    var only = k.kids[0]
                    only.lead = "heading " + only.lead
                    out.append(only)
                    continue
                }
            }
            out.append(k)
        }
        out = merged(out)
        out.removeAll { $0.kind == .text && $0.body.allSatisfy(\.isWhitespace) }
        func blank(_ e: Entry) -> Bool { e.body.allSatisfy(\.isWhitespace) }
        // (A text cut short has its number anyway: not asked.)
        func ask(_ e: inout Entry) { if !e.presses, !prose(e.body).cut { e.presses = presses(e.el) } }
        for i in out.indices {
            if out[i].kind == .text {
                ask(&out[i])
            } else if out[i].kind == .run {
                let words = out[i].parts.indices.filter { out[i].parts[$0].kind == .text && !blank(out[i].parts[$0]) }
                if words.count == 1 { ask(&out[i].parts[words[0]]) }
            }
        }
        return out
    }

    /// `kids` with each stretch of texts side by side (in one element, on one line of the screen), and the links
    /// among them, made one line: a run. Not links alone: those keep their own lines.
    static func merged(_ kids: [Entry]) -> [Entry] {
        func joins(_ e: Entry) -> Bool { e.kids.isEmpty && e.lead.isEmpty && (e.kind == .text || e.inline != nil) }
        func sameParent(_ a: Entry, _ b: Entry) -> Bool {
            a.parent.map { p in b.parent.map { CFEqual(p, $0) } ?? false } ?? false
        }
        var out: [Entry] = []
        var i = 0
        while i < kids.count {
            var j = i
            if joins(kids[i]) {
                while j + 1 < kids.count, joins(kids[j + 1]), sameParent(kids[j], kids[j + 1]),
                      oneLine(kids[j].rect, kids[j + 1].rect) { j += 1 }
            }
            let group = Array(kids[i...j])
            if group.count > 1, group.contains(where: { $0.kind == .text && !$0.body.allSatisfy(\.isWhitespace) }) {
                var run = Entry(kind: .run, depth: group[0].depth, el: group[0].el, parent: group[0].parent, rect: nil)
                run.parts = group
                out.append(run)
            } else {
                out.append(contentsOf: group)
            }
            i = j + 1
        }
        return out
    }

    /// Whether two frames share a line of the screen: they overlap down the screen by most of a line (a
    /// paragraph's text and the link at the end of its last line do; one line and the next don't). A frame not
    /// known, or of no size, can't tell, so it does.
    static func oneLine(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b, a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return true }
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= min(8, min(a.height, b.height) / 2)
    }

    /// A part of a run: what's written, whether its text had a space before or after it, and its frame.
    typealias Segment = (text: String, lead: Bool, trail: Bool, rect: CGRect?)

    /// A run's parts as one line: a space where a text has one at that edge (or is blank), or between parts that
    /// neither touch nor meet at punctuation ("(see" [link] ")"). Not within a word split in two ("$" "9.99").
    static func joinSegments(_ segments: [Segment]) -> String {
        var s = ""
        var prev: Segment?
        var gap = false  // a blank text since the last part
        for seg in segments {
            if seg.text.isEmpty {
                gap = gap || seg.lead || seg.trail
                continue
            }
            if let p = prev {
                let touching = p.rect.flatMap { a in seg.rect.map { b in abs(b.minX - a.maxX) <= 1 && abs(b.midY - a.midY) < 3 } } ?? false
                let closes = seg.text.first.map { ")]}.,;:!?%”’".contains($0) } ?? false
                let opens = p.text.last.map { "([{“‘".contains($0) } ?? false
                if gap || p.trail || seg.lead || !(touching || closes || opens) { s += " " }
            }
            s += seg.text
            prev = seg
            gap = false
        }
        return s
    }

    /// A text as an outline shows it: on one line, spaces run together, at most `proseClip` characters (ending at a
    /// word's end), a long web address cut in the middle. And whether that cut it short.
    static func prose(_ s: String) -> (shown: String, cut: Bool) {
        let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if one.count > urlClip, isURL(one) { return (shortURL(one), true) }
        guard one.count > proseClip else { return (one, false) }
        return (head(one, proseClip - 1) + "…", true)
    }

    /// Words from the window that would read as an outline's own: `[label](#n)` (an element's number) is broken up.
    static func neutral(_ s: String) -> String {
        s.replacingOccurrences(of: "](#", with: "] (#")
    }

    /// A line of text as the outline writes it: one that would read as a numbered line (`#12 …`) or as the note an
    /// outline ends with starts with a backslash.
    static func bareLine(_ s: String) -> String {
        s.hasPrefix("#") || s.hasPrefix("… (") ? "\\" + s : s
    }

    /// A label or value at most `n` characters long on one line (`clip`); a web address cut in the middle instead,
    /// to `urlClip` at most (`shortURL`).
    static func clipLabel(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return isURL(t) ? shortURL(t, min(n, urlClip)) : clip(s, n)
    }

    /// Whether `s` is a web (or file) address: a scheme and "://", or "www.", and no spaces.
    static func isURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return false }
        if s.lowercased().hasPrefix("www.") { return true }
        guard let r = s.range(of: "://"), r.lowerBound > s.startIndex else { return false }
        return s[..<r.lowerBound].allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }

    /// Web address `s` cut in the middle to `n` characters if it's longer: its query (or fragment) first, keeping
    /// the address before it whole when that leaves room (`https://example.com/search?q=cats&…&page=2`), else the
    /// middle of the whole (`https://example.com/a/b/c…/page.html`).
    static func shortURL(_ s: String, _ n: Int = urlClip) -> String {
        guard s.count > n, n > 8 else { return s }
        func middle(_ t: Substring, _ room: Int) -> String {  // `t` in `room` characters, "…" among them
            let front = (room - 1) * 2 / 3
            return String(t.prefix(front)) + "…" + String(t.suffix(room - 1 - front))
        }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            let base = String(s[..<q])
            if base.count + 8 <= n { return base + middle(s[q...], n - base.count) }
        }
        return middle(s[...], n)
    }

    /// What a control's value says when it's an on/off state: " checked" (a checkbox, radio button, switch or toggle,
    /// or a button that stays pressed), " expanded" (a disclosure triangle) or " selected" (a tab) when it's on, and
    /// nothing when it's off. Nil when the value isn't a state: then it's shown as the value.
    static func stateWord(role: String, subrole: String?, value v: String, numeric: Bool) -> String? {
        let on = v == "1"
        switch role {
        case "AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle": return on ? " checked" : ""
        case "AXDisclosureTriangle": return on ? " expanded" : (v == "0" ? "" : nil)
        case "AXTab" where numeric && (on || v == "0"): return on ? " selected" : ""
        case "AXButton" where numeric && (on || v == "0"): return on ? " checked" : ""
        default: break
        }
        if subrole == "AXSwitch" || subrole == "AXToggle" { return on ? " checked" : "" }
        return nil
    }

    /// The element numbered `index` in this window, checked to still be there and still be the same thing
    /// (same role, same title). If it was replaced in place (a list re-rendered), the one element now in
    /// its old container with that role and title is used instead; otherwise this fails rather than act on
    /// something else (a row deleted, the next row's "Delete" is in another container: not used).
    static func node(_ wid: CGWindowID, _ index: Int) throws -> Node {
        guard let reg = registries[wid], !reg.nodes.isEmpty else {
            throw HelperError("no element numbers for this window yet: get an outline (text=true) or use find")
        }
        guard let n = reg.nodes[index] else { throw HelperError("no element \(index) in this window (numbers come from its outline or find)") }
        let role = value(n.element, kAXRoleAttribute) as? String
        if role == n.role, n.label == nil || label(n.element) == n.label { return n }
        let was = "\(n.name) \((n.label ?? n.shown).map { "\"\(clip($0, 40))\"" } ?? "")".trimmingCharacters(in: .whitespaces)
        var like: [(id: Int, frame: CGRect?)] = []
        if let label = n.label, let pid = pidOf(n.element) ?? Windows.info(wid)?.pid {
            let same = search(pid: pid, windows: [wid], query: label, limit: 20).filter {
                $0.exact && (value($0.element, kAXRoleAttribute) as? String) == n.role
            }
            func parentOf(_ el: AXUIElement) -> AXUIElement? {
                value(el, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            }
            let here = n.parent.map { parent in same.filter { m in parentOf(m.element).map { CFEqual($0, parent) } == true } } ?? []
            if here.count == 1, let parent = n.parent {
                let again = Node(element: here[0].element, frame: here[0].frame, role: n.role, label: n.label, name: n.name,
                                 parent: parent, shown: n.shown)
                reg.ids[n.element] = nil
                reg.ids[again.element] = index
                reg.nodes[index] = again
                remarks.append("element \(index) had been replaced; used the \(was) there now")
                return again
            }
            // Elsewhere (another row, say) it's not used, but listed: the agent picks.
            like = same.prefix(5).map { m in
                (reg.number(Node(element: m.element, frame: m.frame, role: n.role, label: AX.label(m.element), name: n.name,
                                 parent: parentOf(m.element))), m.frame)
            }
        }
        throw Gone(index: index, was: was, like: like)
    }

    /// An element number whose element is gone or changed, and the ones like it in the window now.
    struct Gone: Error, CustomStringConvertible {
        let index: Int
        let was: String
        let like: [(id: Int, frame: CGRect?)]
        var description: String { text(nil) }

        /// `place` says where a frame is (screenshot pixels), if it can.
        func text(_ place: ((CGRect) -> String?)?) -> String {
            let head = "element \(index) (\(was)) is gone or changed"
            guard !like.isEmpty else { return head + ": look again (outline or find) for its new number" }
            let list = like.map { m in "[\(m.id)]" + (m.frame.flatMap { place?($0) }.map { " at \($0)" } ?? "") }
            return head + "; the window now shows \(like.count == 1 ? "one" : "\(like.count)") like it: "
                + list.joined(separator: ", ") + ". If that's what you meant, use its number (it isn't picked for you)"
        }
    }

    /// Title, description, placeholder or help: what an element is called (not what it contains).
    static func label(_ el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let s = value(el, attr) as? String, !s.isEmpty { return s }
        }
        return nil
    }

    static func pidOf(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }

    static func center(_ n: Node) -> CGPoint? {
        guard let r = frame(n.element) ?? n.frame, r.width > 0 else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    static func perform(_ n: Node, _ action: String) -> Bool {
        let names: [String]
        let key = action.lowercased().filter { $0.isLetter }  // "show_menu", "ShowMenu", "show menu" alike
        switch key {
        case "press", "click": names = [kAXPressAction, kAXConfirmAction, "AXPick"]
        case "showmenu", "menu", "rightclick", "contextmenu": names = [kAXShowMenuAction]
        case "increment": names = [kAXIncrementAction]
        case "decrement": names = [kAXDecrementAction]
        case "raise": names = [kAXRaiseAction]
        case "cancel": names = [kAXCancelAction]
        case "confirm": names = [kAXConfirmAction]
        case "pick": names = ["AXPick"]
        case "scrolltovisible", "scrollto", "scrollintoview", "reveal": names = ["AXScrollToVisible"]
        case "expand", "collapse": return setExpanded(n.element, key == "expand")
        default: names = [action.hasPrefix("AX") ? action : "AX" + action.prefix(1).uppercased() + action.dropFirst()]
        }
        // Some (SwiftUI) elements report success for any action name; only try ones they list.
        let supported = Set(actionNames(n))
        return names.contains { (supported.isEmpty || supported.contains($0))
            && act(n.element, $0) == .success }
    }

    /// Whether a disclosure triangle, outline row or expandable element is open (nil if it isn't one).
    static func expanded(_ el: AXUIElement) -> Bool? {
        if let b = value(el, "AXExpanded") as? Bool { return b }
        if let b = value(el, "AXDisclosing") as? Bool { return b }
        if (value(el, kAXRoleAttribute) as? String) == "AXDisclosureTriangle",
           let n = value(el, kAXValueAttribute) as? NSNumber { return n.intValue != 0 }
        return nil
    }

    /// Open or close it, checking that it took: some elements accept the attribute and ignore it, so
    /// fall back to pressing (only if that would change the state).
    static func setExpanded(_ el: AXUIElement, _ open: Bool) -> Bool {
        guard let state = expanded(el) else { return false }  // not expandable: never press it blindly
        if state == open { return true }
        for attr in ["AXExpanded", "AXDisclosing"] {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success, settable.boolValue,
               write(el, attr, open as CFBoolean) == .success {
                usleep(60_000)
                if expanded(el) == open { return true }
            }
        }
        guard act(el, kAXPressAction) == .success else { return false }
        usleep(60_000)
        return expanded(el).map { $0 == open } ?? true
    }

    /// The action names an element supports, e.g. ["AXPress", "AXShowMenu"], for error messages.
    static func actionNames(_ n: Node) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(n.element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func setValue(_ n: Node, _ text: String) -> Bool {
        write(n.element, kAXFocusedAttribute, kCFBooleanTrue)
        return write(n.element, kAXValueAttribute, text as CFString) == .success
    }

    static func focus(_ n: Node) -> Bool {
        write(n.element, kAXFocusedAttribute, kCFBooleanTrue) == .success
    }

    /// One-line description of the app's focused element, e.g. `field "Search"`.
    /// What has the keyboard focus. With `wid`, only if it's in that window: the app's focus may be in
    /// another of its windows (the user's).
    static func focusedSummary(pid: pid_t, wid: CGWindowID? = nil) -> String? {
        let app = appElement(pid)
        guard let f = value(app, kAXFocusedUIElementAttribute) else { return nil }
        let el = f as! AXUIElement
        let role = value(el, kAXRoleAttribute) as? String ?? ""
        guard role != "AXWindow", role != "AXApplication" else { return nil }
        if let wid, wid != 0, let other = windowID(el), other != wid { return "in another window (#\(other))" }
        let subrole = value(el, kAXSubroleAttribute) as? String
        var name = roleNames[role] ?? String(role.dropFirst(2)).lowercased()
        if subrole == "AXSecureTextField" { name = "password" }
        let label = (value(el, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (value(el, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (value(el, kAXPlaceholderValueAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        return label.map { "\(name) \"\(clip($0, 40))\"" } ?? name
    }

    /// Background apps don't route key equivalents (cmd+z, cmd+t, …) through their menus, so find the
    /// menu item carrying that shortcut and press it via accessibility instead.
    static func pressMenuShortcut(pid: pid_t, keys: [String]) -> String? {
        guard let (item, title) = menuItem(pid: pid, shortcut: keys),
              act(item, kAXPressAction) == .success else { return nil }
        return title
    }

    /// The menu item whose shortcut is `keys` (cmd+…), and its title. Not in Services.
    static func menuItem(pid: pid_t, shortcut keys: [String]) -> (AXUIElement, String)? {
        var mods = 0  // AXMenuItemCmdModifiers: 0 = cmd only; +1 shift, +2 option, +4 control, +8 no-cmd
        var hasCmd = false
        var main: String?
        for k in keys {
            switch Keys.normalize(k) {
            case "cmd", "command", "meta", "super", "win", "windows": hasCmd = true
            case "shift": mods |= 1
            case "alt", "option", "opt": mods |= 2
            case "ctrl", "control": mods |= 4
            case let n: main = Keys.symbols[n] ?? (k.count == 1 ? k : n)
            }
        }
        guard hasCmd, let key = main else { return nil }
        // Named keys appear as virtual keycodes in menus (e.g. cmd+Delete, cmd+Left).
        let virtualKey = Keys.named[Keys.normalize(key)].map { Int($0) }
        let wantChar = key.count == 1 ? key.uppercased() : nil
        let app = appElement(pid)
        guard let bar = value(app, kAXMenuBarAttribute) else { return nil }
        let start = Date()
        let fields = ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", kAXEnabledAttribute,
                      kAXChildrenAttribute, kAXTitleAttribute] as CFArray

        // Breadth-first: top-level items of every menu first (where nearly all shortcuts live), then submenus.
        var queue: [AXUIElement] = (value(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .compactMap { (value($0, kAXChildrenAttribute) as? [AXUIElement])?.first }  // bar item → its AXMenu
        var level = 0
        while !queue.isEmpty, level < 3, Date().timeIntervalSince(start) < 2 {
            var next: [AXUIElement] = []
            for menu in queue {
                guard let items = value(menu, kAXChildrenAttribute) as? [AXUIElement], items.count <= 150 else { continue }
                for item in items {
                    var raw: CFArray?
                    guard AXUIElementCopyMultipleAttributeValues(item, fields, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                          let v = raw as? [AnyObject], v.count == 6 else { continue }
                    let ch = (v[0] as? String) ?? ""
                    let m = (v[1] as? Int) ?? 0
                    let vk = v[2] as? Int
                    let hit = (wantChar != nil && !ch.isEmpty && ch.uppercased() == wantChar)
                        || (virtualKey != nil && vk == virtualKey && ch.isEmpty)
                    // (AXEnabled reads false for every item of a background app's unvalidated menus; ignore it.)
                    if hit && m == mods { return (item, (v[5] as? String) ?? "menu item") }
                    if let sub = (v[4] as? [AXUIElement])?.first, menuKey((v[5] as? String) ?? "") != "services" { next.append(sub) }
                }
            }
            queue = next
            level += 1
        }
        return nil
    }

    /// The app's key window, as its accessibility reports it.
    static func focusedWindow(pid: pid_t) -> CGWindowID? {
        guard let w = value(appElement(pid), kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w as! AXUIElement, &id) == .success ? id : nil
    }

    static func closeWindow(pid: pid_t, wid: CGWindowID) -> Bool {
        guard let w = window(pid: pid, wid: wid), let b = value(w, kAXCloseButtonAttribute) else { return false }
        return act(b as! AXUIElement, kAXPressAction) == .success
    }

    static func raise(pid: pid_t, wid: CGWindowID) {
        guard !Connection.hungUp else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
        if let w = window(pid: pid, wid: wid) {
            act(w, kAXRaiseAction)
            write(w, kAXMainAttribute, kCFBooleanTrue)
        }
    }
}
