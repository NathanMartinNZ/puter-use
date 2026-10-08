import AppKit
import CoreGraphics

struct WinInfo {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect  // global points, top-left origin
    let layer: Int
    let onScreen: Bool
    var alpha: Double = 1

    var json: [String: Any] {
        [
            "id": Int(id), "pid": Int(pid), "app": app, "title": title, "on_screen": onScreen,
            "frame": [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)],
        ]
    }
}

enum Windows {
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// All windows, front-to-back for on-screen ones.
    static func all(onScreenOnly: Bool = false) -> [WinInfo] {
        let opts: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b)
            else { return nil }
            return WinInfo(
                id: id, pid: pid,
                app: d[kCGWindowOwnerName as String] as? String ?? "",
                title: d[kCGWindowName as String] as? String ?? "",
                frame: frame,
                layer: d[kCGWindowLayer as String] as? Int ?? 0,
                onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false,
                alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    static func info(_ id: CGWindowID) -> WinInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = list.first,
              let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let b = d[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b)
        else { return nil }
        return WinInfo(
            id: id, pid: pid,
            app: d[kCGWindowOwnerName as String] as? String ?? "",
            title: d[kCGWindowName as String] as? String ?? "",
            frame: frame,
            layer: d[kCGWindowLayer as String] as? Int ?? 0,
            onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false,
            alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
    }

    /// The app owning a pid. (Looked up per pid: on macOS 27 NSWorkspace.runningApplications can report pid -1.)
    static func app(_ pid: pid_t) -> NSRunningApplication? {
        guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
        else { return nil }
        return app
    }

    nonisolated(unsafe) private static var chromiumCache: [pid_t: Bool] = [:]

    /// Chromium-based browsers and Electron apps need a few extra workarounds for background input.
    static func isChromium(_ pid: pid_t) -> Bool {
        if let hit = chromiumCache[pid] { return hit }
        var hit = false
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL {
            let fw = url.appendingPathComponent("Contents/Frameworks")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []
            hit = names.contains { n in ["Electron", "Chromium", "Chrome", "Edge", "Brave", "Opera", "Vivaldi", "Arc"].contains { n.contains($0) } }
        }
        chromiumCache[pid] = hit
        return hit
    }

    /// Electron apps (VS Code, Slack, …) are Chromium inside but not browsers.
    static func isElectron(_ pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Normal app windows an agent can target (layer 0, regular apps, reasonably sized).
    static func targetable(app query: String? = nil) -> [WinInfo] {
        var apps: [pid_t: NSRunningApplication?] = [:]
        return all().filter { w in
            guard w.layer == 0, w.frame.width >= 80, w.frame.height >= 60 else { return false }
            if apps[w.pid] == nil { apps[w.pid] = .some(app(w.pid)) }
            guard let app = apps[w.pid] ?? nil else { return false }
            // Hidden helper windows are off-screen and untitled; keep minimized/other-Space windows that have titles.
            guard w.onScreen || !w.title.isEmpty else { return false }
            if let q = query { return matches(app, q) }
            return true
        }
    }

    static func matches(_ app: NSRunningApplication, _ query: String) -> Bool {
        let q = query.lowercased()
        return app.localizedName?.lowercased() == q || app.bundleIdentifier?.lowercased() == q
            || app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == q
    }

    static func runningApp(_ query: String) -> NSRunningApplication? {
        let pids = Set(all().map(\.pid)).union(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        return pids.lazy.compactMap { app($0) }.first { matches($0, query) }
    }

    /// The login window is over everything: windows can't be read (no accessibility, a blank capture).
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// A menu, popover or sheet of `w`'s app lying over `p`; clicks there belong to it, not to `w`.
    /// Mirrors what `Capture.planWindow` composites into `w`'s screenshot.
    static func popup(over w: WinInfo, at p: CGPoint) -> WinInfo? { popups(over: w).first { $0.frame.contains(p) } }

    /// The app's menus, popovers and sheets over window `w`, front to back.
    static func popups(over w: WinInfo) -> [WinInfo] {
        let mine = all(onScreenOnly: true).filter { $0.pid == w.pid }  // front to back
        guard let i = mine.firstIndex(where: { $0.id == w.id }) else { return [] }
        return mine[..<i].filter { $0.frame.width > 1 && ($0.layer > w.layer || w.frame.contains($0.frame)) }
    }

    /// Topmost on-screen window at a global point (used for whole-screen mode), skipping our overlays.
    static func at(_ p: CGPoint) -> WinInfo? {
        all(onScreenOnly: true).first { $0.pid != ownPID && $0.layer < 1000 && $0.frame.contains(p) && $0.frame.width > 1 }
    }

    static func appURL(_ query: String) -> URL? {
        let ws = NSWorkspace.shared
        if query.hasPrefix("/") { return URL(fileURLWithPath: query) }
        if query.contains("."), let u = ws.urlForApplication(withBundleIdentifier: query) { return u }
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        let target = query.lowercased().replacingOccurrences(of: ".app", with: "")
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased() == target + ".app" }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        return nil
    }

    /// Launch (or reopen) an app without activating it, then wait for a targetable window.
    static func launch(_ query: String, timeout: Double = 10) async throws -> [WinInfo] {
        if let running = runningApp(query), !targetable(app: query).isEmpty {
            _ = running
            return targetable(app: query)
        }
        guard let url = appURL(query) ?? runningApp(query)?.bundleURL else {
            throw HelperError("app not found: \(query)")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let wins = targetable(app: query)
            if !wins.isEmpty { return wins }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw HelperError("\(query) launched but has no window yet (try again, or open one with cmd+n)")
    }
}
