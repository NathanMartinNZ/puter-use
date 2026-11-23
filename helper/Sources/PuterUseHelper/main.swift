import AppKit

// PuterUse helper: a background (LSUIElement) app that owns the Screen Recording and
// Accessibility permissions, serves a JSON-lines API on a Unix socket, and draws the
// agent's own cursor + "agent in control" badge so the user's real cursor is never used.

let version = "1.2.0"

func socketPath() -> String {
    if let p = ProcessInfo.processInfo.environment["PUTER_USE_SOCKET"], !p.isEmpty { return p }
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/puter-use", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("helper.sock").path
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: Server?
    var signals: [DispatchSourceSignal] = []

    /// An AppKit quit (logout's quit event, `osascript … quit`, Activity Monitor's Quit): batches under way
    /// stop and let go of what they hold first, as on `quit` and a signal (bounded: `stopAll`'s 1 s and the
    /// clipboard's give-back). After `quit`, which has done that already, it ends at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if Run.stopped { return .terminateNow }
            Task { @MainActor in
                await Run.stopAll(within: 1)
                await Clipboard.finish()
                Run.exitLater()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Clipboard.putBack()
            Hold.releaseAll()
            AgentBrowser.check(exiting: true)  // the agent's own Firefox goes too, unless it has a window of the user's
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Keys.prepare()  // keyboard-layout lookups must happen on the main thread
        _ = Handlers.builtAt  // read now, before a rebuild can replace the file
        let path = socketPath()
        if Server.isAlive(path) {
            FileHandle.standardError.write("puter-use helper already running at \(path)\n".data(using: .utf8)!)
            exit(0)
        }
        do {
            server = try Server(path: path)
            server?.start()
        } catch {
            FileHandle.standardError.write("failed to start server: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        // Stopped by a signal (kill, pkill, Ctrl-C): batches under way stop and let go of what they hold
        // (within 1 s, as on quit), the user's clipboard comes back if a paste had borrowed it, and the apps
        // kept active for agents are let go of. A logout's quit comes as an AppKit quit instead
        // (`applicationShouldTerminate`).
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Task { @MainActor in
                    await Run.stopAll(within: 1)
                    Hold.releaseAll()
                    await Clipboard.finish()
                    AgentBrowser.check(exiting: true)
                    exit(0)
                }
            }
            src.resume()
            signals.append(src)
        }
        if CommandLine.arguments.contains("--request-permissions") {
            _ = Permissions.request()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
