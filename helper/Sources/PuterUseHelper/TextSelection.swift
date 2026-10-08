import ApplicationServices

/// Selecting text by dragging over it or shift-clicking, in apps that judge those gestures by the real
/// mouse and keyboard. AppKit's text views (TextEdit, Notes, any text field being edited) end a press
/// when the hardware button is up and check the hardware Shift key, not the events they are sent. In
/// the background the hardware button is up and Shift isn't held, so a hand-paced drag selects a
/// character or two and a shift-click only moves the caret. The gesture's events still go out as a
/// hand makes them; afterwards, if the app didn't select what the gesture covered, the selection is set
/// through accessibility.
extension AX {
    struct TextSpot {
        let element: AXUIElement
        let index: Int  // the caret position nearest the point
    }

    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// The editable text element of window `wid` at global point `p`, and the caret position there.
    static func textSpot(pid: pid_t, wid: CGWindowID, at p: CGPoint) -> TextSpot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)  // it delays a click: give up quickly on a busy app
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success,
              var el = hit else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.3)
        for _ in 0..<4 {  // the hit can be a part (a text run, a cell) of the text element
            if let role = value(el, kAXRoleAttribute) as? String, textRoles.contains(role) { break }
            guard let parent = value(el, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            el = parent as! AXUIElement
            AXUIElementSetMessagingTimeout(el, 0.3)
        }
        guard let role = value(el, kAXRoleAttribute) as? String, textRoles.contains(role) else { return nil }
        var id: CGWindowID = 0
        if let w = value(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID(),
           _AXUIElementGetWindow(w as! AXUIElement, &id) == .success, id != wid { return nil }
        var pt = p
        guard let pv = AXValueCreate(.cgPoint, &pt),
              let r = range(param(el, kAXRangeForPositionParameterizedAttribute, pv)) else { return nil }
        var index = r.location
        // The point is on a character: the caret goes before or after it, whichever edge is nearer.
        var cr = r
        if r.length > 0, let rv = AXValueCreate(.cfRange, &cr),
           let b = param(el, kAXBoundsForRangeParameterizedAttribute, rv), CFGetTypeID(b) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.width > 0, p.x > rect.midX { index += r.length }
        }
        if let text = value(el, kAXValueAttribute) as? String {  // after a line's last character, not past its newline
            let ns = text as NSString
            if index > 0, index <= ns.length, r.location == index - r.length,
               ns.substring(with: NSRange(location: r.location, length: r.length)) == "\n" { index = r.location }
            index = min(index, ns.length)
        }
        return TextSpot(element: el, index: index)
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? { range(value(el, kAXSelectedTextRangeAttribute)) }

    @discardableResult
    static func select(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// The selection once the app has finished with a gesture: the same twice in a row, 40 ms apart
    /// (at most `timeout`).
    @MainActor static func settledSelection(_ el: AXUIElement, timeout: Double = 0.35) async -> CFRange? {
        var last = selectedRange(el)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await Input.ms(40)
            let now = selectedRange(el)
            if let a = now, let b = last, a.location == b.location, a.length == b.length { return now }
            last = now
        }
        return last
    }

    /// A click inside the selection leaves AppKit's text views waiting to learn (from the hardware button)
    /// whether the selection is being dragged away; in the background they never do, and the next key or
    /// click lands in that half-finished gesture. So the caret goes to the click point first, and the
    /// click lands on plain text. True if it did.
    static func clearForClick(_ spot: TextSpot, _ before: CFRange?) -> Bool {
        guard let b = before, b.length > 0, spot.index > b.location, spot.index < b.location + b.length else { return false }
        return select(spot.element, CFRange(location: spot.index, length: 0))
    }

    /// After a drag from `start` to `end` over text: select what it covered unless the app already did.
    /// Not when the drag began inside the selection: that drags the selected text somewhere.
    @MainActor static func settleDragSelection(_ start: TextSpot, before: CFRange?, pid: pid_t, wid: CGWindowID, end p: CGPoint) async {
        if let b = before, b.length > 0, start.index > b.location, start.index < b.location + b.length { return }
        guard let end = textSpot(pid: pid, wid: wid, at: p), CFEqual(end.element, start.element) else { return }
        let want = CFRange(location: min(start.index, end.index), length: abs(end.index - start.index))
        _ = await settledSelection(start.element)
        Trace.log(["k": "selection", "gesture": "drag", "before": before.map { [$0.location, $0.length] } ?? [],
                   "now": selectedRange(start.element).map { [$0.location, $0.length] } ?? [],
                   "want": [want.location, want.length]])
        guard want.length > 0, let now = selectedRange(start.element),
              now.location != want.location || now.length != want.length else { return }
        select(start.element, want)
    }

    /// After a plain click that was inside the selection (see `clearForClick`): the caret must be where
    /// the click was, whatever the app made of it.
    @MainActor static func settleClick(_ spot: TextSpot, before: CFRange?) async {
        guard let b = before, b.length > 0, spot.index > b.location, spot.index < b.location + b.length,
              let now = await settledSelection(spot.element), now.length > 0 || abs(now.location - spot.index) > 1 else { return }
        Trace.log(["k": "selection", "gesture": "click", "before": [b.location, b.length], "now": [now.location, now.length],
                   "want": [spot.index, 0]])
        select(spot.element, CFRange(location: spot.index, length: 0))
    }

    /// After a shift-click at `spot`: extend the selection that was there to it, unless the app already did.
    @MainActor static func settleShiftClick(_ spot: TextSpot, before: CFRange?) async {
        guard let b = before, let now = await settledSelection(spot.element) else { return }
        let want = spot.index >= b.location
            ? CFRange(location: b.location, length: spot.index - b.location)
            : CFRange(location: spot.index, length: b.location + b.length - spot.index)
        Trace.log(["k": "selection", "gesture": "shift-click", "before": [b.location, b.length],
                   "now": [now.location, now.length], "want": [want.location, want.length], "at": spot.index])
        guard want.length > 0, now.location != want.location || now.length != want.length else { return }
        select(spot.element, want)
    }

    private static func param(_ el: AXUIElement, _ attr: String, _ arg: AXValue) -> AnyObject? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, arg, &out) == .success ? out : nil
    }

    private static func range(_ v: AnyObject?) -> CFRange? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }
}
