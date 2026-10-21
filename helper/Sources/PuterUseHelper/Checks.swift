import AppKit
import ApplicationServices

/// Checks that keep an action from doing what a person at the screen couldn't, or wouldn't mean to:
/// pressing a control behind a sheet, or typing into something that isn't a text field.
extension AX {
    /// Something text can be typed into.
    static func isTextInput(_ el: AXUIElement) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(value(el, kAXRoleAttribute) as? String ?? "")
    }

    /// The window (`wid`) an element is in, as accessibility reports it.
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        guard let w = value(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w as! AXUIElement, &id) == .success ? id : nil
    }

    /// Whether the element is in window `wid` (for elements from the app's focus, which may be another
    /// window of it: the user's).
    static func isInWindow(_ el: AXUIElement, _ wid: CGWindowID) -> Bool {
        wid == 0 || windowID(el) == wid
    }

    /// A browser's own text field (its address bar, find bar, …) rather than something in the page: one
    /// holds a single address, so clicking it selects what's there and typing replaces it.
    @MainActor static func isBrowserAddressBar(_ el: AXUIElement, pid: pid_t) -> Bool {
        guard Handlers.isBrowser(pid), isTextInput(el) else { return false }
        var cur = el
        for _ in 0..<40 {
            guard let p = value(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            cur = p as! AXUIElement
            switch value(cur, kAXRoleAttribute) as? String {
            case "AXWebArea": return false  // part of the page
            case "AXToolbar": return true
            default: continue
            }
        }
        return true  // it tops out in the browser's chrome, not in a page
    }

    /// Controls whose accessibility press is what a click does. A click on anything else (a text field,
    /// a list row, a picture) means where it lands: that one gets a real click.
    static let pressable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXLink", "AXDisclosureTriangle", "AXSwitch", "AXToggle", "AXIncrementor",
    ]

    static func isPressable(_ el: AXUIElement) -> Bool { pressable.contains(value(el, kAXRoleAttribute) as? String ?? "") }

    /// Where the app's open menus are (menu windows on screen).
    static func menuWindows(_ pid: pid_t) -> [CGRect] {
        Windows.all(onScreenOnly: true).filter { $0.pid == pid && $0.layer >= 100 && $0.layer < 1000 }.map(\.frame)
    }

    /// An accessibility menu that's showing: it has a size and a menu window is where it is.
    static func menuOpen(_ rect: CGRect?, _ menus: [CGRect]) -> Bool {
        guard let r = rect, r.width > 0, r.height > 0 else { return false }
        return menus.contains { $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: r.midX, y: r.midY)) }
    }

    /// The app's focused element.
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = appElement(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let f = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (f as! AXUIElement)
    }

    /// The text an element shows as its name (not its value).
    static func caption(_ el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let s = value(el, attr) as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// `button "Send"`, for messages.
    static func describe(_ el: AXUIElement) -> String {
        let role = value(el, kAXRoleAttribute) as? String ?? "AXUnknown"
        let name = roleNames[role] ?? String(role.dropFirst(2)).lowercased()
        return caption(el).map { "\(name) \"\(clip($0, 40))\"" } ?? name
    }

    static func isInside(_ el: AXUIElement, _ ancestor: AXUIElement) -> Bool {
        var cur = el
        for _ in 0..<40 {
            if CFEqual(cur, ancestor) { return true }
            guard let p = value(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return false }
            cur = p as! AXUIElement
        }
        return false
    }

    /// A sheet's or dialog's title, or else its buttons, for messages.
    static func gist(_ win: AXUIElement) -> String {
        if let t = value(win, kAXTitleAttribute) as? String, !t.isEmpty { return " (\"\(clip(t, 40))\")" }
        var buttons: [String] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 6, buttons.count < 4 else { return }
            for k in children(el) {
                if value(k, kAXRoleAttribute) as? String == "AXButton", let t = caption(k) { buttons.append(t) }
                walk(k, depth + 1)
            }
        }
        walk(win, 0)
        return buttons.isEmpty ? "" : " (buttons: \(buttons.joined(separator: ", ")))"
    }

    /// The sheet or modal dialog a person would have to deal with before they could reach `el`, or nil.
    /// Accessibility actions go past them, so pressing through one would do what no click could.
    static func blockedBy(_ el: AXUIElement) -> String? {
        guard let w = value(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let win = w as! AXUIElement
        if value(win, kAXRoleAttribute) as? String == "AXSheet" { return nil }
        for k in children(win) where value(k, kAXRoleAttribute) as? String == "AXSheet" && !isInside(el, k) {
            return "a sheet" + gist(k)
        }
        if let pid = pidOf(el) {
            for other in value(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
            where !CFEqual(other, win) && value(other, "AXModal") as? Bool == true {
                return "a dialog" + gist(other)
            }
        }
        return nil
    }
}

extension Handlers {
    /// Throws if a sheet or dialog stands between the user and element `n`.
    static func reachable(_ el: AXUIElement, _ name: String) throws {
        if let why = AX.blockedBy(el) {
            throw HelperError("\(name) is behind \(why) that's open over the window: deal with that first")
        }
    }
}
