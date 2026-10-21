import AppKit

// PuterUse helper: a background (LSUIElement) app that owns the Screen Recording and
// Accessibility permissions, serves a JSON-lines API on a Unix socket, and draws the
// agent's own cursor + "agent in control" badge so the user's real cursor is never used.

let version = "1.0.1"

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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Clipboard.putBack()
            Hold.releaseAll()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Keys.prepare()  // keyboard-layout lookups must happen on the main thread
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
        // Stopped (pkill, logout): give the user's clipboard back if a paste had borrowed it, and let go of
        // the apps kept active for agents.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Task { @MainActor in
                    await Run.abandonAll()
                    Hold.releaseAll()
                    await Clipboard.finish()
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
