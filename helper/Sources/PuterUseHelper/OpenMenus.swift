import AppKit
import ApplicationServices

/// Menus an action opens (a context menu, a toolbar button's menu). While one is open it takes the
/// keyboard, the user's included, so none is left open between calls: an action that opens one names
/// the item to choose (`item`), and a menu still open at the end of a batch is listed and closed.
extension AX {
    /// The menu the app has open, if any.
    static func openMenu(pid: pid_t) -> AXUIElement? {
        let shown = menuWindows(pid)
        guard !shown.isEmpty else { return nil }
        // A context menu isn't among the app's children: find it by what's at the menu window.
        let app = appElement(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for f in shown {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(f.midX), Float(f.minY + min(24, f.height / 2)), &hit) == .success,
                  var el = hit else { continue }
            for _ in 0..<6 {
                if value(el, kAXRoleAttribute) as? String == "AXMenu" { return el }
                guard let p = value(el, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
                el = p as! AXUIElement
            }
        }
        return nil
    }

    /// Its items, "Font >" for one with a submenu, skipping separators and disabled items.
    static func menuTitles(_ menu: AXUIElement) -> [String] {
        children(menu).compactMap { item in
            guard let t = value(item, kAXTitleAttribute) as? String, !t.isEmpty,
                  value(item, kAXEnabledAttribute) as? Bool != false else { return nil }
            return children(item).isEmpty ? t : t + " >"
        }
    }

    /// The element at global point `p` in the app.
    static func element(pid: pid_t, at p: CGPoint) -> AXUIElement? {
        let app = appElement(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success else { return nil }
        return hit
    }

    static func closeMenu(_ menu: AXUIElement) {
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }

    /// The titled items of a menu level.
    static func titledItems(_ menu: AXUIElement) -> [(AXUIElement, String)] {
        children(menu).compactMap { item in
            guard let t = value(item, kAXTitleAttribute) as? String, !t.isEmpty else { return nil }
            return (item, t)
        }
    }

    static func matchItem(_ items: [(AXUIElement, String)], _ want: String) throws -> (AXUIElement, String) {
        let k = menuKey(want)
        var hits = items.filter { menuKey($0.1) == k }
        if hits.isEmpty { hits = items.filter { menuKey($0.1).hasPrefix(k) } }
        if hits.isEmpty { hits = items.filter { menuKey($0.1).contains(k) } }
        guard hits.count == 1 else {
            let names = (hits.isEmpty ? items : hits).prefix(30).map(\.1).joined(separator: ", ")
            throw HelperError(hits.isEmpty ? "no \"\(want)\" in the menu (has: \(names))" : "\"\(want)\" is ambiguous: \(names)")
        }
        guard value(hits[0].0, kAXEnabledAttribute) as? Bool != false else { throw HelperError("\"\(hits[0].1)\" is disabled") }
        return hits[0]
    }
}

extension Handlers {
    /// After a click that opens a menu: choose `item` in it (closing it if that fails), as a person does:
    /// the pointer goes to the item and clicks it, resting on an item with a submenu until that opens.
    /// (Pressing a menu item through accessibility doesn't work in a menu the app is tracking.) An item
    /// scrolled out of a long menu is reached with the arrow keys instead.
    ///
    /// An open menu also follows the user's real mouse (moving it clears the highlight) and a click
    /// anywhere closes it. So nothing is sent once the menu has gone (a click would land on the window
    /// beneath; Return could press its default button), and the highlight is checked before choosing.
    static func pickFromMenu(_ a: [String: Any], _ r: Route, _ t: Target) async throws {
        let path = AX.menuPath(a["item"])
        guard !path.isEmpty else { throw HelperError("item needs the menu item's title, e.g. \"Copy\" or \"Font > Bold\"") }
        let wanted = path.joined(separator: " > ")
        var menu: AXUIElement?
        for _ in 0..<15 {  // menus take a moment to come up
            menu = AX.openMenu(pid: r.pid)
            if menu != nil { break }
            await Input.ms(40)
        }
        guard let menu else { throw HelperError("no menu opened to choose \"\(wanted)\" from") }
        Trace.log(["k": "menu", "open": true])  // what's sent into it now is the menu's (scripts/check_motion.py)
        defer { Trace.log(["k": "menu", "open": false]) }
        func closed() -> HelperError {
            HelperError("the menu closed before \"\(wanted)\" was chosen (a click anywhere closes it, the user's too): "
                + "nothing was chosen")
        }
        func stillOpen() throws { if AX.openMenu(pid: r.pid) == nil { throw closed() } }
        /// Where a person would point at an item (over its title), with the route to its menu window; nil
        /// when it isn't showing (scrolled out of a long menu).
        func spot(_ el: AXUIElement) throws -> (CGPoint, Route)? {
            guard let f = AX.frame(el), f.width > 4, f.height > 4 else { return nil }
            let p = CGPoint(x: f.minX + Double.random(in: 14...max(15, min(f.width * 0.45, 80))),
                            y: f.midY + Double.random(in: -f.height * 0.15...f.height * 0.15))
            guard AX.menuWindows(r.pid).contains(where: { $0.insetBy(dx: 1, dy: 1).contains(p) }) else { return nil }
            let mr = try route(t, at: p, foreground: false)
            return mr.wid == r.wid ? nil : (p, mr)  // routed to the menu's own window, not the one beneath
        }
        func selected(_ el: AXUIElement) -> Bool { AX.value(el, kAXSelectedAttribute) as? Bool == true }

        await Input.sleep(clickTiming.aim())  // reading it, as a person would
        do {
            var level = menu
            var chosen: [String] = []
            for (i, want) in path.enumerated() {
                let items = AX.titledItems(level)
                let (el, title) = try AX.matchItem(items, want)
                if AX.menuKey(title) == "services" {
                    throw HelperError("Services hand what's selected to other apps; puter-use doesn't use them")
                }
                chosen.append(title)
                let last = i == path.count - 1
                if last {  // as matched (the menu is closed again if it refuses)
                    do { try Policy.checkItem(a, title) } catch var stop as Policy.NeedsOK {
                        stop.partly = "its menu was opened to find the item and closed again without choosing it"
                        throw stop
                    }
                    try Policy.checkPointerItem(r.pid, title)
                }
                let deadline = Date().addingTimeInterval(3)
                // With the pointer, if this menu follows it (some, like a pop-up button's, follow only the
                // real mouse: those get the keys).
                if let (p, mr) = try spot(el) {
                    try stillOpen()
                    // Inside a submenu, the pointer stays over it: straying onto the menu beside it would
                    // switch submenus.
                    await pointer.move(to: p, mr, lane: i > 0 ? AX.frame(level)?.insetBy(dx: 3, dy: 3) : nil, follow: router(t))
                    if last {
                        await Input.sleep(clickTiming.aim())
                        // The user's mouse may have taken the highlight meanwhile: point again.
                        let hover = Date().addingTimeInterval(0.4)
                        while !selected(el), Date() < hover {
                            try stillOpen()
                            Input.mouse(.mouseMoved, p, mr)
                            await Input.ms(40)
                        }
                        if selected(el) {
                            guard let (_, now) = try spot(el), now.wid == mr.wid else { throw closed() }
                            pointer.click()
                            await Input.press(p, mr, typist: clickTiming)
                            break
                        }
                    } else {
                        // Rest on it until its submenu opens (a click opens it too).
                        var sub: AXUIElement?
                        for k in 0..<12 {
                            if let s = AX.children(el).first, AX.menuOpen(AX.frame(s), AX.menuWindows(r.pid)) { sub = s; break }
                            try stillOpen()
                            if k == 6, selected(el) {
                                pointer.click()
                                await Input.press(p, mr, typist: clickTiming)
                            } else if !selected(el) {
                                Input.mouse(.mouseMoved, p, mr)
                            }
                            await Input.ms(60)
                        }
                        if let sub {
                            // Across into the submenu along the item's row before going up or down it, as a
                            // hand does (straying onto the next item would switch submenus).
                            if let sf = AX.frame(sub), let f = AX.frame(el) {
                                let across = CGPoint(x: sf.minX + Double.random(in: 12...24), y: min(max(p.y, sf.minY + 6), sf.maxY - 6))
                                let row = CGRect(x: f.minX, y: f.minY + 3, width: across.x + 8 - f.minX, height: f.height - 6)
                                if AX.menuWindows(r.pid).contains(where: { $0.contains(across) }),
                                   let ar = try? route(t, at: across, foreground: false), ar.wid != r.wid {
                                    try stillOpen()
                                    await pointer.move(to: across, ar, lane: row.contains(across) ? row : nil, follow: router(t))
                                }
                            }
                            level = sub
                            continue
                        }
                    }
                }
                // With the keys: walk the highlight there with the arrows. Not where the policy allows no
                // keys (a terminal): if the menu closed under them, Return would reach the app.
                if Policy.level(r.pid) < .full {
                    throw HelperError("couldn't choose \"\(title)\" with the pointer, and puter-use's policy allows no keys in "
                        + "\(Policy.appName(r.pid))")
                }
                while !selected(el) {
                    guard Date() < deadline else {
                        throw HelperError("couldn't get to \"\(title)\" in the menu (the user's mouse moving over it takes the highlight)")
                    }
                    try stillOpen()
                    // A pop-up's menu opens on its current item: the target may be above it. With nothing
                    // highlighted, Down starts from the top and Up from the bottom.
                    let goal = items.firstIndex { CFEqual($0.0, el) } ?? 0
                    let at = items.firstIndex { selected($0.0) }
                    let up = at.map { goal < $0 } ?? (goal >= items.count / 2)
                    try await press([up ? "Up" : "Down"], r)
                    await Input.sleep(typist.instant ? 0.03 : Double.random(in: 0.05...0.09))
                }
                try stillOpen()
                if last {
                    try await press(["Return"], r)
                    break
                }
                guard let sub = AX.children(el).first else { throw HelperError("\"\(title)\" has no submenu") }
                try await press(["Right"], r)
                await Input.ms(150)
                level = sub
            }
            // A chosen item closes its menu (it fades out); one still open means it didn't take.
            var gone = false
            for _ in 0..<10 {
                await Input.ms(100)
                if AX.openMenu(pid: r.pid) == nil { gone = true; break }
            }
            if !gone { throw HelperError("\(chosen.joined(separator: " > ")) didn't respond") }
            let name = chosen.joined(separator: " > ")
            if AX.menuKey(name) != AX.menuKey(wanted) { notes.append("chose \(name)") }
        } catch {
            if let open = AX.openMenu(pid: r.pid) { AX.closeMenu(open) }
            AX.closeMenu(menu)
            throw error
        }
    }

    /// The pop-up button at an element (or holding it). Its item is chosen through accessibility (as
    /// `select` does): a pop-up's open menu follows only the real mouse, which belongs to the user.
    static func popUpButton(_ el: AXUIElement?) -> AXUIElement? {
        var cur = el
        for _ in 0..<3 {
            guard let c = cur else { return nil }
            if AX.value(c, kAXRoleAttribute) as? String == "AXPopUpButton" { return c }
            cur = AX.value(c, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return nil
    }

    /// At the end of a batch: close a menu left open, telling the agent what was in it. After a click
    /// (`wait`), one may still be on its way up.
    static func closeLeftOpenMenu(pid: pid_t, wait: Bool) async {
        var menu = AX.openMenu(pid: pid)
        for _ in 0..<(wait && menu == nil ? 8 : 0) {
            await Input.ms(50)
            menu = AX.openMenu(pid: pid)
            if menu != nil { break }
        }
        guard let menu else { return }
        Trace.log(["k": "menu", "open": true])  // what went into it was the menu's (scripts/check_motion.py)
        await Input.ms(120)  // let it finish appearing before it's told to close
        let titles = AX.menuTitles(menu).filter { AX.menuKey($0) != "services >" && AX.menuKey($0) != "services" }
        AX.closeMenu(menu)
        Trace.log(["k": "menu", "open": false])
        notes.append("a menu opened (" + titles.prefix(25).joined(separator: " · ") + (titles.count > 25 ? " · …" : "")
            + "); it's closed again, as an open menu takes the user's typing. Open it and choose in one step: "
            + "the same click with item: \"…\" (\"Font > Bold\" for a submenu)")
    }
}
