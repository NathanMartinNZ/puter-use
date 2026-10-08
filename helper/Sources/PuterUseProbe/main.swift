import AppKit

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

final class Probe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let status = NSTextField(labelWithString: "status: ready")
    let name = NSTextField()
    let password = NSSecureTextField()
    let color = NSPopUpButton()
    let subscribe = NSButton(checkboxWithTitle: "Subscribe", target: nil, action: nil)
    let size = NSComboBox()
    let notes = NSTextView()
    var children: [NSWindow] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSEvent.isMouseCoalescingEnabled = false  // log every move the app is sent
        NSEvent.addLocalMonitorForEvents(matching: .any) { e in logEvent(e); return e }
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 720, height: 560),
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
        for title in ["Save", "Delete", "Send", "Slow", "Open Sheet", "New Window"] {
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

        window.orderFront(nil)  // not activated: it starts in the background like any other app
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
        case "Open Sheet":
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
        case "New Window": newWindow(nil)
        default: set("\(b.title) pressed")
        }
    }

    @objc func closeSheet(_ b: NSButton) {
        if let s = window.attachedSheet { window.endSheet(s) }
        set("sheet closed by \(b.title)")
    }

    @objc func newWindow(_ sender: Any?) {
        let w = NSWindow(contentRect: NSRect(x: 260, y: 160, width: 480, height: 320),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "probe child \(children.count + 1)"
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "A new window")
        label.frame = NSRect(x: 20, y: 260, width: 300, height: 20)
        w.contentView?.addSubview(label)
        w.orderFront(nil)
        children.append(w)
        set("new window \(w.windowNumber)")
    }

    @objc func changed(_ sender: Any?) {
        set("color \(color.titleOfSelectedItem ?? "?"), subscribe \(subscribe.state == .on ? "on" : "off"), size \(size.stringValue.isEmpty ? "-" : size.stringValue)")
    }

    @objc func exportPDF(_ sender: Any?) { set("Exported") }
    @objc func emailLink(_ sender: Any?) { set("Emailed link") }
    @objc func toggleThing(_ sender: Any?) { set("Toggled") }

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
        menu("View", [item("Toggle Thing", #selector(toggleThing(_:)), "t", [.command, .option])])
        NSApp.mainMenu = bar
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe()
app.delegate = probe
app.run()
