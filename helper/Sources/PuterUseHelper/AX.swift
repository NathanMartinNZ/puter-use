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
    }

    /// Element numbers per window, stable across looks: an element keeps its number for as long as it
    /// exists, so numbers from an earlier outline (or find) still work after the window changes, and a
    /// number whose element is gone fails instead of hitting something else.
    final class Registry {
        var ids: [AXUIElement: Int] = [:]
        var nodes: [Int: Node] = [:]
        var next = 1
        var lines: [(Int, String)] = []  // the last outline's numbered lines, in order (for "what changed")

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
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
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
        return AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v) == .success
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
    ]

    /// Containers that add nesting but no meaning unless labelled.
    static let transparent: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXMatte",
        "AXRuler", "AXBrowser", "AXGrid", "AXColumn", "AXWindow", "AXDrawer", "AXRadioGroup", "AXLandmark",
    ]

    static let attrs: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXFocusedAttribute, kAXEnabledAttribute,
        kAXPlaceholderValueAttribute, kAXSelectedAttribute, kAXHelpAttribute,
    ]

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    nonisolated(unsafe) static var enhanced: Set<pid_t> = []
    nonisolated(unsafe) static var lastCount: [CGWindowID: Int] = [:]  // elements numbered by the last outline

    /// Indexed outline, e.g. `[3] button "Back"` / ` [7] field "Search" ="cats" focused`.
    /// `within` (global points) limits it to elements overlapping that area, e.g. one table row.
    static func outline(pid: pid_t, wid: CGWindowID, within: CGRect? = nil, maxElements: Int = 300,
                        maxChars: Int = 8000, interactive: Bool = false) -> String? {
        let text = buildOutline(pid: pid, wid: wid, within: within, maxElements: maxElements, maxChars: maxChars,
                                interactive: interactive)
        // Firefox/Gecko only builds its accessibility tree once a client asks for "enhanced" UI.
        if (lastCount[wid] ?? 0) < 3, !enhanced.contains(pid) {
            enhanced.insert(pid)
            AXUIElementSetAttributeValue(appElement(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            usleep(400_000)
            return buildOutline(pid: pid, wid: wid, within: within, maxElements: maxElements, maxChars: maxChars,
                                interactive: interactive)
        }
        return text
    }

    /// The text inside `within` (global points) in reading order, one line per visual line, unclipped:
    /// for reading values exactly (a table row, a price) without a zoomed screenshot.
    static func text(pid: pid_t, wid: CGWindowID, within: CGRect) -> String? {
        guard let win = window(pid: pid, wid: wid) else { return nil }
        let area = within.insetBy(dx: -2, dy: -2)
        let inputs: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        let labelled: Set<String> = ["AXButton", "AXLink", "AXPopUpButton", "AXMenuButton", "AXCheckBox",
                                     "AXRadioButton", "AXMenuItem", "AXCell"]
        var runs: [(rect: CGRect, text: String)] = []

        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 60, runs.count < 500 else { return }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let vals = raw as? [AnyObject], vals.count == attrs.count
            else { return }
            func str(_ i: Int) -> String? {  // keeps edge spaces: pages split "380 points" / " by " / "hn_acker"
                guard let s = vals[i] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return s.replacingOccurrences(of: "\n", with: " ")
            }
            let role = str(0) ?? ""
            if role == "AXColumn" || str(1) == "AXSecureTextField" { return }
            var rect: CGRect?
            var pt = CGPoint.zero, sz = CGSize.zero
            if CFGetTypeID(vals[6]) == AXValueGetTypeID(), CFGetTypeID(vals[7]) == AXValueGetTypeID(),
               AXValueGetValue(vals[6] as! AXValue, .cgPoint, &pt), AXValueGetValue(vals[7] as! AXValue, .cgSize, &sz) {
                rect = CGRect(origin: pt, size: sz)
            }
            if let r = rect, r.width > 0, r.height > 0, !r.intersects(area), role != "AXWindow" { return }
            func emit(_ t: String?) {
                // Count a run only if its centre is in the area, so neighbouring lines don't bleed in.
                if let t, let r = rect, within.contains(CGPoint(x: r.midX, y: r.midY)) { runs.append((r, t)) }
            }
            if role == "AXStaticText" { emit(str(4) ?? str(2)); return }
            if inputs.contains(role) { emit(str(4) ?? str(10)); return }
            let before = runs.count
            for k in vals[5] as? [AXUIElement] ?? [] { walk(k, depth: depth + 1) }
            if runs.count == before, labelled.contains(role) { emit(str(2) ?? str(3)) }  // e.g. an icon button
        }
        walk(win, depth: 0)

        var seen = Set<String>()
        let unique = runs.filter { seen.insert("\($0.text)@\(Int($0.rect.minX)),\(Int($0.rect.minY))").inserted }
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
            return s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return out.isEmpty ? "(no text in that area)" : out.joined(separator: "\n")
    }

    /// Roles worth acting on, for the `interactive` outline.
    static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXTab",
        "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXDateField", "AXSwitch", "AXToggle", "AXCell",
        "AXRow", "AXOutlineRow",
    ]

    private static func buildOutline(pid: pid_t, wid: CGWindowID, within: CGRect?, maxElements: Int,
                                     maxChars: Int, interactive: Bool = false) -> String? {
        guard let win = window(pid: pid, wid: wid) else { return nil }
        let reg = registry(wid)
        var seen = Set<Int>()
        var visible = (frame(win) ?? Windows.info(wid)?.frame ?? .infinite).insetBy(dx: -2, dy: -2)
        if let within { visible = visible.intersection(within.insetBy(dx: -2, dy: -2)) }
        var nodes: [Node] = []
        var lines: [String] = []
        var numbered: [(Int, String)] = []
        var chars = 0
        var truncated = false

        let menus = menuWindows(pid)
        func walk(_ el: AXUIElement, depth: Int, indent: Int, parentLabel: String?, parent: AXUIElement? = nil) {
            if truncated || depth > 60 { return }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let vals = raw as? [AnyObject], vals.count == attrs.count
            else { return }
            func str(_ i: Int) -> String? {
                if let s = vals[i] as? String, !s.isEmpty { return s }
                return nil
            }
            let role = str(0) ?? "AXUnknown"
            if role == "AXColumn" { return }  // a table's columns hold the same cells as its rows
            let subrole = str(1)
            var rect: CGRect?
            if CFGetTypeID(vals[6]) == AXValueGetTypeID(), CFGetTypeID(vals[7]) == AXValueGetTypeID() {
                var pt = CGPoint.zero, sz = CGSize.zero
                if AXValueGetValue(vals[6] as! AXValue, .cgPoint, &pt), AXValueGetValue(vals[7] as! AXValue, .cgSize, &sz) {
                    rect = CGRect(origin: pt, size: sz)
                }
            }
            // Skip subtrees scrolled out of view (huge win for long web pages and lists).
            if let r = rect, r.width > 0, r.height > 0, !r.intersects(visible), role != "AXWindow" { return }
            // A pop-up's menu stays in the tree once it has been opened: only an open one is shown.
            if role == "AXMenu", !menuOpen(rect, menus) { return }

            let title = str(2) ?? str(3) ?? str(10) ?? str(12)
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

            let isTransparent = transparent.contains(role) && title == nil
            let isText = role == "AXStaticText"
            let label = title ?? (isText ? valueText : nil)
            var include = !isTransparent && !name.isEmpty
            if interactive && !actionable.contains(role) && subrole != "AXTabButton" { include = false }
            if isText && (label?.isEmpty ?? true) { include = false }
            // Text that just repeats its parent's label (link "Docs" > text "Docs") adds nothing.
            if isText, let l = label, let pl = parentLabel, pl.contains(l.trimmingCharacters(in: .whitespaces)) { include = false }
            if role == "AXListMarker" { include = false }
            if role == "AXImage" && title == nil { include = false }
            if (role == "AXRow" || role == "AXCell" || role == "AXOutlineRow") && title == nil { include = false }
            if transparent.contains(role) { include = include && title != nil }

            var childIndent = indent
            if include {
                var line = String(repeating: " ", count: min(indent, 10))
                var lineID: Int?
                if transparent.contains(role) || role == "AXToolbar" || role == "AXTabGroup" || role == "AXTable"
                    || role == "AXOutline" || role == "AXList" || role == "AXWebArea" || role == "AXHeading"
                {
                    line += "\(name)"  // structural: not actionable, no index
                    if let l = label { line += " \"\(clip(l, 60))\"" }
                } else {
                    let id = reg.number(Node(element: el, frame: rect, role: role, label: isText ? nil : title, name: name,
                                             parent: parent))
                    nodes.append(reg.nodes[id]!)
                    seen.insert(id)
                    lineID = id
                    line += "[\(id)] \(name)"
                    if let l = label { line += " \"\(clip(l, isText ? 100 : 60))\"" }
                    if !isText, let v = valueText, !v.isEmpty, v != label {
                        if role == "AXCheckBox" || role == "AXRadioButton" || subrole == "AXSwitch" {
                            line += v == "1" ? " checked" : ""
                        } else {
                            line += " =\"\(clip(v, 80))\""
                        }
                    }
                    if focused { line += " focused" }
                    if selected { line += " selected" }
                    if !enabled { line += " disabled" }
                }
                chars += line.count + 1
                if nodes.count > maxElements || chars > maxChars { truncated = true; return }
                lines.append(line)
                if let lineID { numbered.append((lineID, line.trimmingCharacters(in: .whitespaces))) }
                childIndent += 1
            }
            if isText { return }  // static text children are just text runs
            if let kids = vals[5] as? [AXUIElement] {
                for k in kids { walk(k, depth: depth + 1, indent: childIndent, parentLabel: include ? label : parentLabel, parent: el) }
            }
        }

        walk(win, depth: 0, indent: 0, parentLabel: nil)
        lastCount[wid] = nodes.count
        reg.lines = numbered
        reg.prune(keeping: seen)
        if truncated { lines.append("… (truncated; zoom with region or use a screenshot)") }
        return lines.joined(separator: "\n")
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
        let was = "\(n.name) \(n.label.map { "\"\(clip($0, 40))\"" } ?? "")".trimmingCharacters(in: .whitespaces)
        if let label = n.label, let parent = n.parent, let pid = pidOf(n.element) ?? Windows.info(wid)?.pid {
            let same = search(pid: pid, windows: [wid], query: label, limit: 20).filter {
                $0.exact && (value($0.element, kAXRoleAttribute) as? String) == n.role
            }.filter { m in
                value(m.element, kAXParentAttribute).map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, parent) } == true
            }
            if same.count == 1 {
                let again = Node(element: same[0].element, frame: same[0].frame, role: n.role, label: n.label, name: n.name,
                                 parent: parent)
                reg.ids[n.element] = nil
                reg.ids[again.element] = index
                reg.nodes[index] = again
                remarks.append("element \(index) had been replaced; used the \(was) there now")
                return again
            }
        }
        throw HelperError("element \(index) (\(was)) is gone or changed: look again (outline or find) for its new number")
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
            && AXUIElementPerformAction(n.element, $0 as CFString) == .success }
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
               AXUIElementSetAttributeValue(el, attr as CFString, open as CFBoolean) == .success {
                usleep(60_000)
                if expanded(el) == open { return true }
            }
        }
        guard AXUIElementPerformAction(el, kAXPressAction as CFString) == .success else { return false }
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
        AXUIElementSetAttributeValue(n.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(n.element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    static func focus(_ n: Node) -> Bool {
        AXUIElementSetAttributeValue(n.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// One-line description of the app's focused element, e.g. `field "Search"`.
    static func focusedSummary(pid: pid_t) -> String? {
        let app = appElement(pid)
        guard let f = value(app, kAXFocusedUIElementAttribute) else { return nil }
        let el = f as! AXUIElement
        let role = value(el, kAXRoleAttribute) as? String ?? ""
        guard role != "AXWindow", role != "AXApplication" else { return nil }
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
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return nil }
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
        return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
    }

    static func raise(pid: pid_t, wid: CGWindowID) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        if let w = window(pid: pid, wid: wid) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
}
