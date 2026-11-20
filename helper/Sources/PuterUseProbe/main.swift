import AppKit
import WebKit

// PuterUseProbe: a test window for checking puter-use against an app that reports what it received.
// Every event that reaches its windows is logged as a JSON line (PROBE_LOG, default
// ~/Library/Caches/puter-use/probe.jsonl) with NSEvent's timestamp (seconds of system uptime, the clock
// the helper's PUTER_USE_TRACE uses) and window-local top-left coordinates; scripts/check_motion.py
// compares the two. It also has a few ordinary controls, menus and slow actions to act on.

let logPath = ProcessInfo.processInfo.environment["PROBE_LOG"].map { ($0 as NSString).expandingTildeInPath }
    ?? (NSHomeDirectory() + "/Library/Caches/puter-use/probe.jsonl")
try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
FileManager.default.createFile(atPath: logPath, contents: nil)
let log = FileHandle(forWritingAtPath: logPath)!

func record(_ obj: [String: Any]) {
    var o = obj
    if o["t"] == nil { o["t"] = ProcessInfo.processInfo.systemUptime }
    guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
    d.append(0x0A)
    log.write(d)
}

/// Global top-left-origin frame, as the helper and CGWindowList report it.
/// Move a window that's just been shown to where the environment says (its bottom-left, Cocoa "x,y"):
/// PROBE_AT for the main window, PROBE_CHILD_AT for New Window's. Tests use them to put windows partly off
/// screen, as an app's own placement can (a window created there is pulled back on screen).
func moveAsTold(_ w: NSWindow, from key: String) {
    let n = (ProcessInfo.processInfo.environment[key] ?? "").split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    if n.count == 2 { w.setFrameOrigin(NSPoint(x: n[0], y: n[1])) }
}

func globalFrame(_ w: NSWindow) -> [Double] {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return [w.frame.minX, h - w.frame.maxY, w.frame.width, w.frame.height]
}

let names: [NSEvent.EventType: String] = [
    .mouseMoved: "move", .leftMouseDown: "down", .leftMouseUp: "up", .rightMouseDown: "rdown",
    .rightMouseUp: "rup", .otherMouseDown: "mdown", .otherMouseUp: "mup", .leftMouseDragged: "drag",
    .rightMouseDragged: "rdrag", .otherMouseDragged: "mdrag", .scrollWheel: "scroll", .keyDown: "keydown",
    .keyUp: "keyup", .flagsChanged: "flags", .mouseEntered: "enter", .mouseExited: "exit",
]

/// Log an event as the app receives it, before any window or menu sees it (so shortcuts that a menu
/// handles are logged too).
func logEvent(_ event: NSEvent) {
    guard let name = names[event.type] else { return }
    var o: [String: Any] = ["k": "event", "t": event.timestamp, "type": name, "window": event.windowNumber,
                            "title": event.window?.title ?? "", "flags": event.modifierFlags.rawValue]
    if [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
        o["code"] = Int(event.keyCode)
        if event.type != .flagsChanged {
            o["chars"] = event.characters ?? ""
            o["repeat"] = event.isARepeat
        }
    } else if let w = event.window {
        let p = event.locationInWindow
        o["x"] = p.x
        o["y"] = w.frame.height - p.y  // top-left origin, like the helper
        if event.type == .scrollWheel { o["dx"] = event.scrollingDeltaX; o["dy"] = event.scrollingDeltaY }
        else { o["clicks"] = event.clickCount }
    }
    record(o)
}

/// Draws the pointer path the window received (moves grey, drags blue, clicks red), so a screenshot
/// shows what arrived.
final class Canvas: NSView {
    var trail: [(NSPoint, NSColor)] = []
    var clicks: [NSPoint] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.97, alpha: 1).setFill()
        bounds.fill()
        for (p, c) in trail.suffix(4000) {
            c.setFill()
            NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2).fill()
        }
        NSColor.systemRed.setStroke()
        for c in clicks.suffix(200) { NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).stroke() }
    }
    override func mouseMoved(with e: NSEvent) { add(e, .gray) }
    override func mouseDragged(with e: NSEvent) { add(e, .systemBlue) }
    override func mouseDown(with e: NSEvent) { clicks.append(convert(e.locationInWindow, from: nil)); needsDisplay = true }
    private func add(_ e: NSEvent, _ c: NSColor) { trail.append((convert(e.locationInWindow, from: nil), c)); needsDisplay = true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}

/// A text view that logs how long its own mouse tracking (selection by dragging) lasts.
final class NotesView: NSTextView {
    override func mouseDown(with e: NSEvent) {
        record(["k": "track", "phase": "begin", "buttons": NSEvent.pressedMouseButtons])
        super.mouseDown(with: e)
        record(["k": "track", "phase": "end", "buttons": NSEvent.pressedMouseButtons,
                "selection": NSStringFromRange(selectedRange())])
    }
}

/// PROBE_SLOW_AX=<ms>: an app that answers accessibility slowly but answers (a page loading, an IDE indexing).
/// A column of `count` lines of text down the window's right edge, each line taking <ms> to answer its role
/// while `slow`. View > Slow Accessibility turns that off and on.
final class SlowColumn: NSView {
    let delay: TimeInterval
    var slow = true
    let count: Int
    lazy var lines: [SlowLine] = (1...count).map { SlowLine(self, $0) }
    init(count: Int, delay: TimeInterval) {
        (self.count, self.delay) = (count, delay)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (slow ? NSColor.systemOrange : NSColor.systemGreen).withAlphaComponent(0.2).setFill()
        bounds.fill()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { lines }
}

final class SlowLine: NSAccessibilityElement {
    unowned let column: SlowColumn
    let index: Int
    init(_ column: SlowColumn, _ index: Int) {
        (self.column, self.index) = (column, index)
        super.init()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityParent() -> Any? { column }
    override func accessibilityRole() -> NSAccessibility.Role? {
        if column.slow { Thread.sleep(forTimeInterval: column.delay) }
        return .staticText
    }
    override func accessibilityValue() -> Any? { "Slow \(index)" }
    override func accessibilityFrame() -> NSRect {
        let h = column.bounds.height / CGFloat(column.count)
        let r = NSRect(x: 0, y: CGFloat(index - 1) * h, width: column.bounds.width, height: h)
        return column.window?.convertToScreen(column.convert(r, to: nil)) ?? .zero
    }
}

final class FlippedView: NSView {  // top-down layout, for PROBE_LONG_LIST's list
    override var isFlipped: Bool { true }
}

/// PROBE_LONG_LIST's "Flat Far": a button with no height, as accessibility reports it.
final class FlatButton: NSAccessibilityElement {
    unowned let host: NSView
    let press: () -> Void
    init(_ host: NSView, press: @escaping () -> Void) {
        (self.host, self.press) = (host, press)
        super.init()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityParent() -> Any? { host }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { "Flat Far" }
    override func accessibilityFrame() -> NSRect {
        host.window?.convertToScreen(host.convert(NSRect(x: 4, y: 12, width: 52, height: 0), to: nil)) ?? .zero
    }
    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

final class Probe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var slowColumn: SlowColumn?  // PROBE_SLOW_AX's
    let status = NSTextField(labelWithString: "status: ready")
    let name = NSTextField()
    let password = NSSecureTextField()
    let color = NSPopUpButton()
    let subscribe = NSButton(checkboxWithTitle: "Subscribe", target: nil, action: nil)
    let size = NSComboBox()
    let notes = NSTextView()
    var children: [NSWindow] = []
    var panels: [NSPanel] = []  // Sheet Later's, with PROBE_LATER_PANEL
    var webWindow: NSWindow?  // PROBE_WEBVIEW's

    func applicationDidFinishLaunching(_ n: Notification) {
        NSEvent.isMouseCoalescingEnabled = false  // log every move the app is sent
        NSEvent.addLocalMonitorForEvents(matching: .any) { e in logEvent(e); return e }
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 804, height: 560),  // 720 before Sheet Later
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "puter-use probe"
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        let v = NSView(frame: window.contentLayoutRect)
        window.contentView = v

        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x, y: 560 - y - h, width: w, height: h)  // top-left layout
            v.addSubview(view)
        }
        name.placeholderString = "Name"
        name.setAccessibilityLabel("Name")
        password.placeholderString = "Password"
        password.setAccessibilityLabel("Password")
        color.addItems(withTitles: ["Red", "Green", "Blue"])
        color.setAccessibilityLabel("Color")
        color.target = self
        color.action = #selector(changed(_:))
        subscribe.target = self
        subscribe.action = #selector(changed(_:))
        place(name, 16, 16, 220, 24)
        place(password, 248, 16, 180, 24)
        place(color, 440, 14, 120, 28)
        place(subscribe, 576, 18, 130, 20)
        var x: CGFloat = 16
        for title in ["Save", "Delete", "Send", "Slow", "Open Sheet", "New Window", "Sheet Later"] {
            let b = NSButton(title: title, target: self, action: #selector(button(_:)))
            b.bezelStyle = .push
            if title == "Save" { b.toolTip = "Saves nothing: a test button" }  // tooltips are windows too
            place(b, x, 52, 100, 30)
            x += 112
        }
        place(status, 16, 90, 400, 20)
        size.addItems(withObjectValues: ["Small", "Medium", "Large"])
        size.placeholderString = "Size"
        size.setAccessibilityLabel("Size")
        size.target = self
        size.action = #selector(changed(_:))
        place(size, 440, 87, 140, 26)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        notes.isRichText = false
        notes.setAccessibilityLabel("Notes")
        notes.autoresizingMask = [.width]
        notes.isAutomaticSpellingCorrectionEnabled = false
        notes.isAutomaticTextCompletionEnabled = false
        notes.isAutomaticQuoteSubstitutionEnabled = false
        notes.isAutomaticDashSubstitutionEnabled = false
        notes.isAutomaticTextReplacementEnabled = false
        notes.isContinuousSpellCheckingEnabled = false
        scroll.documentView = notes
        place(scroll, 16, 118, 688, 150)
        notes.frame = NSRect(x: 0, y: 0, width: 670, height: 150)
        let canvas = Canvas()
        canvas.setAccessibilityLabel("Canvas")
        place(canvas, 16, 280, 688, 264)
        if ProcessInfo.processInfo.environment["PROBE_CONTEXT_MENU"] != nil {  // a right-click menu on the Canvas
            let m = NSMenu()
            for t in ["Mark One", "Mark Two"] { m.addItem(withTitle: t, action: #selector(mark(_:)), keyEquivalent: "").target = self }
            canvas.menu = m
        }
        if let ms = Double(ProcessInfo.processInfo.environment["PROBE_SLOW_AX"] ?? ""), ms > 0 {
            slowColumn = SlowColumn(count: 100, delay: ms / 1000)
            place(slowColumn!, 716, 118, 80, 426)
        }
        if ProcessInfo.processInfo.environment["PROBE_LONG_LIST"] != nil { place(longList(), 716, 118, 80, 426) }
        if ProcessInfo.processInfo.environment["PROBE_WEBVIEW"] != nil { openWebWindow() }
        // PROBE_WIDE=<pt>: the window that wide, Notes stretched with it, like an agent's default-sized window
        // (a screenshot's change cells there are ~6 pt, not ~3).
        if let wide = Double(ProcessInfo.processInfo.environment["PROBE_WIDE"] ?? ""), wide > 804 {
            window.setContentSize(NSSize(width: wide, height: 560))
            scroll.frame.size.width = wide - 116
        }

        window.orderFront(nil)  // not activated: it starts in the background like any other app
        moveAsTold(window, from: "PROBE_AT")
        record(["k": "start", "pid": Int(ProcessInfo.processInfo.processIdentifier), "window": window.windowNumber,
                "frame": globalFrame(window)])
        print("probe pid \(ProcessInfo.processInfo.processIdentifier) window \(window.windowNumber) log \(logPath)")
        fflush(stdout)
    }

    func set(_ s: String) {
        status.stringValue = "status: \(s)"
        record(["k": "status", "status": s])
    }

    @objc func button(_ b: NSButton) {
        switch b.title {
        case "Slow": set("working…"); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.set("Done") }
        case "Open Sheet": openSheet()
        case "Sheet Later":  // the same sheet, a while after the click: PROBE_SHEET_LATER seconds (default 0.4)
            // PROBE_LATER_PANEL=1: a small panel over the window instead, which unlike a sheet isn't its child window.
            // PROBE_LATER_PANEL=slide: that panel at once, during the press, 60 pt above its place, sliding down
            // to it over PROBE_SLIDE s (default 0.35) after the press has returned, as an app's animated dialog can.
            let env = ProcessInfo.processInfo.environment
            if env["PROBE_LATER_PANEL"] == "slide" {
                openPanel(slide: Double(env["PROBE_SLIDE"] ?? "") ?? 0.35)
            } else {
                let delay = Double(env["PROBE_SHEET_LATER"] ?? "") ?? 0.4
                record(["k": "pressed", "button": b.title, "delay": delay])  // logged only: the window doesn't change yet
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    env["PROBE_LATER_PANEL"] == nil ? self.openSheet() : self.openPanel()
                }
            }
        case "New Window": newWindow(nil)
        default: set("\(b.title) pressed")
        }
    }

    /// PROBE_LONG_LIST=1: a list longer than its view, down the right edge (where PROBE_SLOW_AX's column goes):
    /// buttons "Row 1"…"Row 80" (about 16 show; a press sets the status to "Row N pressed"), then a "Far Box"
    /// checkbox, a "Far Field" text field, a "Delete Far" button (a press that needs the user's OK), a "Later"
    /// button (on screen only "Sheet Later" contains that) and a "Flat Far" button of no height in a group; and a
    /// "Ghost" button kept far to the left of the list, where no scrolling can show it.
    func longList() -> NSScrollView {
        let rows = 80, h: CGFloat = 26
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 64, height: CGFloat(rows + 5) * h + 8))
        for i in 1...rows {
            let b = NSButton(title: "Row \(i)", target: self, action: #selector(button(_:)))
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.frame = NSRect(x: 0, y: CGFloat(i - 1) * h + 2, width: 64, height: 22)
            doc.addSubview(b)
        }
        let box = NSButton(checkboxWithTitle: "Far Box", target: self, action: #selector(farBox(_:)))
        box.frame = NSRect(x: 2, y: CGFloat(rows) * h + 4, width: 62, height: 20)
        doc.addSubview(box)
        let field = NSTextField(frame: NSRect(x: 2, y: CGFloat(rows + 1) * h + 4, width: 60, height: 22))
        field.placeholderString = "Far Field"
        field.setAccessibilityLabel("Far Field")
        doc.addSubview(field)
        let delete = NSButton(title: "Delete Far", target: self, action: #selector(button(_:)))
        delete.bezelStyle = .push
        delete.controlSize = .small
        delete.font = .systemFont(ofSize: 11)
        delete.frame = NSRect(x: 0, y: CGFloat(rows + 2) * h + 4, width: 64, height: 22)
        doc.addSubview(delete)
        let whole = NSButton(title: "Later", target: self, action: #selector(button(_:)))
        whole.bezelStyle = .push
        whole.controlSize = .small
        whole.font = .systemFont(ofSize: 11)
        whole.frame = NSRect(x: 0, y: CGFloat(rows + 3) * h + 4, width: 64, height: 22)
        doc.addSubview(whole)
        let group = NSView(frame: NSRect(x: 0, y: CGFloat(rows + 4) * h + 2, width: 64, height: 24))
        group.setAccessibilityElement(true)
        group.setAccessibilityRole(.group)
        group.setAccessibilityLabel("Flat Group")
        group.setAccessibilityChildren([FlatButton(group) { [unowned self] in self.set("Flat Far pressed") }])
        doc.addSubview(group)
        let ghost = NSButton(title: "Ghost", target: self, action: #selector(button(_:)))
        ghost.frame = NSRect(x: -2000, y: 400, width: 64, height: 22)
        doc.addSubview(ghost)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        return scroll
    }

    @objc func farBox(_ b: NSButton) { set("Far Box \(b.state == .on ? "on" : "off")") }

    func openSheet() {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled],
                             backing: .buffered, defer: false)
        let ok = NSButton(title: "OK", target: self, action: #selector(closeSheet(_:)))
        ok.frame = NSRect(x: 220, y: 16, width: 80, height: 30)
        ok.keyEquivalent = "\r"
        sheet.contentView?.addSubview(ok)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet(_:)))
        cancel.frame = NSRect(x: 130, y: 16, width: 80, height: 30)
        cancel.keyEquivalent = "\u{1b}"
        sheet.contentView?.addSubview(cancel)
        let label = NSTextField(labelWithString: "A sheet appeared")
        label.frame = NSRect(x: 20, y: 70, width: 280, height: 20)
        sheet.contentView?.addSubview(label)
        window.beginSheet(sheet)
        set("sheet open")
    }

    /// A dialog-like panel over the middle of the window, just above it (not above other apps' windows),
    /// and too small to be followed as a new window. `slide` (s): it opens 60 pt higher and slides down into place.
    func openPanel(slide: Double = 0) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 76), styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closePanel(_:)))
        cancel.frame = NSRect(x: 50, y: 12, width: 80, height: 30)
        panel.contentView?.addSubview(cancel)
        let label = NSTextField(labelWithString: "A panel appeared")
        label.frame = NSRect(x: 20, y: 48, width: 150, height: 20)
        panel.contentView?.addSubview(label)
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - panel.frame.width / 2,
                                     y: window.frame.midY - panel.frame.height / 2 + (slide > 0 ? 60 : 0)))
        panel.order(.above, relativeTo: window.windowNumber)
        panels.append(panel)
        set("panel open")
        if slide > 0 {
            let to = panel.frame.offsetBy(dx: 0, dy: -60)
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = slide
                panel.animator().setFrame(to, display: true)
            }, completionHandler: { self.set("panel in place") })
        }
    }

    @objc func closePanel(_ b: NSButton) {
        b.window?.orderOut(nil)
        set("panel closed by \(b.title)")
    }

    @objc func closeSheet(_ b: NSButton) {
        if let s = window.attachedSheet { window.endSheet(s) }
        set("sheet closed by \(b.title)")
    }

    @objc func newWindow(_ sender: Any?) {
        // PROBE_WINDOW_LATER=<s>: the window comes that long after the command, which shows "opening a window"
        // at once, as an app's document window can come a moment after a double-click.
        if sender as? String != "later", let later = Double(ProcessInfo.processInfo.environment["PROBE_WINDOW_LATER"] ?? ""), later > 0 {
            set("opening a window")
            DispatchQueue.main.asyncAfter(deadline: .now() + later) { self.newWindow("later") }
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 260, y: 160, width: 480, height: 320),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "probe child \(children.count + 1)"
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "A new window")
        label.frame = NSRect(x: 20, y: 260, width: 300, height: 20)
        w.contentView?.addSubview(label)
        w.orderFront(nil)
        moveAsTold(w, from: "PROBE_CHILD_AT")
        children.append(w)
        set("new window \(w.windowNumber)")
    }

    /// PROBE_WEBVIEW=1: a second window, "probe web", showing a web page in a system web view (WKWebView), as
    /// apps that aren't browsers do (Mail's message view, Tauri apps). Web Button counts its clicks.
    func openWebWindow() {
        let w = NSWindow(contentRect: NSRect(x: 320, y: 120, width: 480, height: 320), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "probe web"
        w.isReleasedWhenClosed = false
        let web = WKWebView(frame: w.contentLayoutRect)
        web.loadHTMLString("""
            <html><body style="font: 15px -apple-system; margin: 24px"><script>var c = 0</script>
            <h3>A web page</h3>
            <button onclick="document.getElementById('n').textContent = 'clicked ' + (++c)">Web Button</button>
            <p id="n">not clicked</p></body></html>
            """, baseURL: nil)
        w.contentView = web
        w.orderFront(nil)
        webWindow = w
    }

    @objc func changed(_ sender: Any?) {
        set("color \(color.titleOfSelectedItem ?? "?"), subscribe \(subscribe.state == .on ? "on" : "off"), size \(size.stringValue.isEmpty ? "-" : size.stringValue)")
    }

    @objc func exportPDF(_ sender: Any?) { set("Exported") }
    @objc func emailLink(_ sender: Any?) { set("Emailed link") }
    @objc func toggleThing(_ sender: Any?) { set("Toggled") }
    @objc func mark(_ sender: NSMenuItem) { set("marked \(sender.title)") }  // PROBE_CONTEXT_MENU's items
    @objc func toggleSlowAX(_ sender: Any?) {
        guard let c = slowColumn else { return }
        c.slow.toggle()
        c.needsDisplay = true
        set("accessibility \(c.slow ? "slow" : "fast")")
    }

    func windowDidMove(_ n: Notification) { record(["k": "frame", "window": window.windowNumber, "frame": globalFrame(window)]) }
    func windowDidResize(_ n: Notification) { windowDidMove(n) }

    func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            top.submenu = m
            bar.addItem(top)
        }
        // Own actions go to self; standard ones (nil target) to the first responder, e.g. the text field.
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command,
                  own: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            if own { i.target = self }
            return i
        }
        menu("PuterUseProbe", [item("Quit Probe", #selector(NSApplication.terminate(_:)), "q", own: false)])
        let share = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        share.submenu = NSMenu(title: "Share")
        share.submenu?.addItem(item("Email Link", #selector(emailLink(_:)), ""))
        menu("File", [item("New Window", #selector(newWindow(_:)), "n"),
                      item("Export as PDF…", #selector(exportPDF(_:)), "e", [.command, .shift]), share])
        menu("Edit", [item("Undo", Selector(("undo:")), "z", own: false),
                      item("Redo", Selector(("redo:")), "z", [.command, .shift], own: false), .separator(),
                      item("Cut", #selector(NSText.cut(_:)), "x", own: false),
                      item("Copy", #selector(NSText.copy(_:)), "c", own: false),
                      item("Paste", #selector(NSText.paste(_:)), "v", own: false),
                      item("Select All", #selector(NSText.selectAll(_:)), "a", own: false)])
        menu("View", [item("Toggle Thing", #selector(toggleThing(_:)), "t", [.command, .option])]
             + (ProcessInfo.processInfo.environment["PROBE_SLOW_AX"] == nil ? [] : [item("Slow Accessibility", #selector(toggleSlowAX(_:)), "")]))
        // PROBE_BIG_MENUS=<n>: a browser-like menu bar, for timing the menu walk. Go adds 9 shortcuts (12 with the
        // ones above), then History has <n> pages and Bookmarks <n>/10 folders of 10. Go's places do nothing; its
        // second Email Link (a name in two menus), a page or a bookmark shows "marked <its title>" in the status (a
        // name alone in `menu` must never run one).
        if let n = Int(ProcessInfo.processInfo.environment["PROBE_BIG_MENUS"] ?? ""), n > 0 {
            menu("Go", (1...9).map { item("Go to Place \($0)", nil, "\($0)", [.command, .option]) }
                 + [item("Email Link", #selector(mark(_:)), "")])
            menu("History", (1...n).map { item("Visited Page \($0)", #selector(mark(_:)), "") })
            menu("Bookmarks", (1...max(1, n / 10)).map { f in
                let folder = NSMenuItem(title: "Folder \(f)", action: nil, keyEquivalent: "")
                folder.submenu = NSMenu(title: "Folder \(f)")
                for b in 1...10 { folder.submenu?.addItem(item("Bookmark \(f).\(b)", #selector(mark(_:)), "")) }
                return folder
            })
        }
        NSApp.mainMenu = bar
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe()
app.delegate = probe
app.run()
