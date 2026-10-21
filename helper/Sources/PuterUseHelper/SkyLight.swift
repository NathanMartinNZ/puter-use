import CoreGraphics
import Foundation

/// Private WindowServer (SkyLight) calls used for background input, resolved at runtime.
/// Technique as used by OpenAI's Codex Computer Use, open-codex-computer-use and cua-driver.
enum SkyLight {
    private static let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let appServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    typealias PostRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    typealias FrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32

    /// Like CGEventPostToPid, but goes through the activity-monitor path so apps treat events as live input.
    static let postToPid = sym(sl, "SLEventPostToPid", PostToPid.self)
    /// Stamps the window-local (top-left origin, points) location AppKit uses for hit-testing.
    static let setWindowLocation = sym(sl, "CGEventSetWindowLocation", SetWindowLocation.self)
    private static let postEventRecordTo = sym(sl, "SLPSPostEventRecordTo", PostRecord.self)
    private static let getProcessForPID = sym(appServices, "GetProcessForPID", ProcessForPID.self)
    private static let getFrontProcess = sym(sl, "_SLPSGetFrontProcess", FrontProcess.self)

    /// Whether `pid` is the WindowServer's front process: really active, as opposed to only AppKit-active
    /// through `setAppKitActive`. nil if it can't be determined.
    static func isFrontProcess(_ pid: pid_t) -> Bool? {
        guard let getFront = getFrontProcess, let getPSN = getProcessForPID else { return nil }
        var front = [UInt32](repeating: 0, count: 2), psn = [UInt32](repeating: 0, count: 2)
        guard front.withUnsafeMutableBytes({ getFront($0.baseAddress!) }) == 0,
              psn.withUnsafeMutableBytes({ getPSN(pid, $0.baseAddress!) }) == 0 else { return nil }
        return front == psn
    }

    private static func record(_ pid: pid_t, _ fill: (inout [UInt8]) -> Void) -> Bool {
        guard let post = postEventRecordTo, let getPSN = getProcessForPID else { return false }
        var psn = [UInt32](repeating: 0, count: 2)
        guard psn.withUnsafeMutableBytes({ getPSN(pid, $0.baseAddress!) }) == 0 else { return false }
        var r = [UInt8](repeating: 0, count: 0x100)  // 0xF8-byte record; 0x100 buffer (newer macOS reads past 0xF8)
        r[0x04] = 0xF8
        fill(&r)
        return psn.withUnsafeMutableBytes { p in r.withUnsafeMutableBytes { post(p.baseAddress!, $0.baseAddress!) } } == 0
    }

    private static func putWindow(_ r: inout [UInt8], _ wid: CGWindowID) {
        withUnsafeBytes(of: wid.littleEndian) { for (i, b) in $0.enumerated() { r[0x3C + i] = b } }
    }

    /// Make the app's AppKit layer believe it is (or isn't) active, with `wid` as its focused window.
    /// WindowServer focus (and so the user's frontmost app and keyboard) is untouched.
    @discardableResult
    static func setAppKitActive(pid: pid_t, wid: CGWindowID, _ active: Bool) -> Bool {
        record(pid) { r in
            r[0x08] = 0x0D  // AppKit-defined event
            putWindow(&r, wid)
            r[0x8A] = active ? 0x01 : 0x02
        }
    }

    /// Make `wid` the key window of its app without raising it (needed by Chromium-based apps to accept text).
    static func makeKeyWindow(pid: pid_t, wid: CGWindowID) {
        for type: UInt8 in [0x01, 0x02] {
            _ = record(pid) { r in
                r[0x08] = type
                r[0x3A] = 0x10
                for i in 0x20..<0x30 { r[i] = 0xFF }
                putWindow(&r, wid)
            }
        }
    }
}
