import CoreGraphics
import Foundation

/// Opt-in JSON-lines log (PUTER_USE_TRACE=<file>) of every event the helper sends, every planned pointer
/// path and every pointer frame, timestamped in seconds of system uptime (the clock NSEvent uses), so
/// scripts/check_motion.py can compare the motion with what the target app actually received.
enum Trace {
    nonisolated(unsafe) private static var path: String?
    nonisolated(unsafe) private static var handle: FileHandle?
    /// Tags the events being posted, e.g. "primer" for the activation-click workaround.
    nonisolated(unsafe) static var label: String?

    static func configure(_ p: String?) {
        let p = p.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        guard p != path || (p != nil && !FileManager.default.fileExists(atPath: p!)) else { return }
        try? handle?.close()
        handle = nil
        path = p
        guard let p else { return }
        if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
        handle = FileHandle(forWritingAtPath: p)
        handle?.seekToEndOfFile()
    }

    static var on: Bool { handle != nil }

    static func log(_ obj: [String: Any]) {
        guard let handle else { return }
        var o = obj
        o["t"] = ProcessInfo.processInfo.systemUptime
        guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0x0A)
        handle.write(d)
    }

    static func plan(_ id: Int, path: [String: Any], from: CGPoint, to: CGPoint, duration: Double, speed: Double) {
        guard on else { return }
        var o = path
        o.merge(["k": "plan", "id": id, "from": [from.x, from.y], "to": [to.x, to.y], "duration": duration,
                 "speed": speed]) { _, new in new }
        log(o)
    }

    static func pointer(_ id: Int, _ p: CGPoint) {
        guard on else { return }
        log(["k": "pointer", "id": id, "x": p.x, "y": p.y])
    }

    static let names: [CGEventType: String] = [
        .mouseMoved: "move", .leftMouseDown: "down", .leftMouseUp: "up", .rightMouseDown: "rdown",
        .rightMouseUp: "rup", .otherMouseDown: "mdown", .otherMouseUp: "mup", .leftMouseDragged: "drag",
        .rightMouseDragged: "rdrag", .otherMouseDragged: "mdrag", .scrollWheel: "scroll", .keyDown: "keydown",
        .keyUp: "keyup", .flagsChanged: "flags",
    ]

    /// An event as it's posted. `p` is its global location (points) for pointer events.
    static func event(_ e: CGEvent, at p: CGPoint?, pid: pid_t, wid: CGWindowID) {
        guard on else { return }
        var o: [String: Any] = ["k": "event", "type": names[e.type] ?? "\(e.type.rawValue)", "pid": Int(pid),
                                "wid": Int(wid), "flags": e.flags.rawValue]
        if let p { o["x"] = p.x; o["y"] = p.y }
        if let label { o["label"] = label }
        if [.keyDown, .keyUp, .flagsChanged].contains(e.type) {
            o["code"] = e.getIntegerValueField(.keyboardEventKeycode)
            var len = 0
            var chars = [UniChar](repeating: 0, count: 8)
            e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &chars)
            if len > 0 { o["chars"] = String(utf16CodeUnits: chars, count: len) }
        }
        log(o)
    }
}
