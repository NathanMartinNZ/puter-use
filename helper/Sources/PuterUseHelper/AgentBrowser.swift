import AppKit

/// The agent's own Firefox (`PUTER_USE_BROWSER_PROFILE=agent`, or a profile folder): a second instance of the
/// installed Firefox, on a profile of puter-use's own, started in the background for navigate. Its keyboard is its own
/// (the user's windows are in another process), it has none of the user's saved cards, logins or tabs, and it keeps
/// drawing its covered windows (`MOZ_WINDOW_OCCLUSION=0`, which reaches only that process).
///
/// Both instances have one bundle id, so it's told apart by its process: the Firefox whose command line names the
/// profile. Only windows the agent opened in it are the agent's, as anywhere: a link the user opens can land there
/// too, in a window of its own.
@MainActor
enum AgentBrowser {
    nonisolated static let bundleID = "org.mozilla.firefox"
    /// What an app name can say for Firefox (any case): its name, its bundle id.
    nonisolated static let names = ["firefox", bundleID]
    /// Added to its app's name where windows are listed or described ("Firefox (agent)"); that name reaches it too.
    nonisolated static let suffix = " (agent)"
    /// It's quit after this long with no session using it.
    nonisolated static let idleQuit: TimeInterval = 30 * 60

    /// puter-use's own profile folder, beside the helper's socket: the one `agent` means.
    nonisolated static var defaultProfile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/puter-use/firefox", isDirectory: true)
    }

    /// Where its profile is: puter-use's own folder, or the one the setting names instead (`use`).
    private(set) static var profile = defaultProfile

    /// Whether its profile is a folder the setting named rather than puter-use's own: then only a Firefox puter-use
    /// started there is it (`isAgents`), and puter-use sets up only a folder that's new, empty or its own (`mayUse`).
    static var custom: Bool { profile.standardizedFileURL.path != defaultProfile.standardizedFileURL.path }

    /// The profile folder a request asks for (`browser_profile`, from the setting): puter-use's own for "agent" (any
    /// case), else the absolute path it gives, standardized (no trailing slash, `.` or `..`). Nil for anything else:
    /// the setting is off.
    nonisolated static func requested(_ p: [String: Any]) -> String? {
        guard let s = (p["browser_profile"] as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.lowercased() == "agent" { return defaultProfile.standardizedFileURL.path }
        guard s.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: s, isDirectory: true).standardizedFileURL.path
    }

    /// Whether a request asks for it (`requested`).
    nonisolated static func wanted(_ p: [String: Any]) -> Bool { requested(p) != nil }

    /// Makes `path` (from `requested`) the profile it's started on. Refused while it runs on another one (the
    /// setting was another as it started, or another client's is): one instance at a time, and its windows may be in
    /// use.
    static func use(_ path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path != profile.standardizedFileURL.path else { return }
        if starting != nil || running() != nil {
            throw HelperError(otherProfile(running: profile.path, asked: url.path))
        }
        profile = url
        known = nil
        others = [:]
    }

    /// Why navigate didn't use the profile it asked for (`asked`): the instance runs on another (`running`).
    nonisolated static func otherProfile(running: String, asked: String) -> String {
        "your own Firefox is already running on the profile in \(running), not \(asked) (PUTER_USE_BROWSER_PROFILE): it's "
            + "quit once no agent has used it for 30 minutes, or the user can quit it (the second Firefox in the Dock)"
    }

    // MARK: - the profile

    /// A pref's value as `user.js` writes it.
    enum Pref: Equatable {
        case bool(Bool), int(Int), string(String)

        var js: String {
            switch self {
            case .bool(let b): return b ? "true" : "false"
            case .int(let n): return String(n)
            case .string(let s): return AgentBrowser.quoted(s)
            }
        }
    }

    /// What puter-use sets in the profile, written again on each start (so a changed list takes effect):
    /// - no first-run pages, Terms of Use, data-reporting notice, What's New or default-browser prompt;
    /// - no remote tiles, stories, weather or trending searches on new tabs and in the address bar;
    /// - no translation pop-up, and no saved addresses, cards or logins (nothing to autofill into a form);
    /// - a blank start with no session restored, after a crash too (old pages would come back each start);
    /// - links from other apps in a window of their own, which is the user's, never the agent's;
    /// - no quit or close warnings, which would hold up its quit.
    nonisolated static let prefs: [(name: String, value: Pref)] = [
        ("browser.preonboarding.enabled", .bool(false)),
        ("browser.aboutwelcome.enabled", .bool(false)),
        ("trailhead.firstrun.didSeeAboutWelcome", .bool(true)),
        ("datareporting.policy.dataSubmissionEnabled", .bool(false)),
        ("datareporting.policy.dataSubmissionPolicyBypassNotification", .bool(true)),
        ("toolkit.telemetry.reportingpolicy.firstRun", .bool(false)),
        ("browser.startup.homepage_override.mstone", .string("ignore")),
        ("browser.shell.checkDefaultBrowser", .bool(false)),
        ("browser.newtabpage.enabled", .bool(false)),
        ("browser.newtabpage.activity-stream.feeds.topsites", .bool(false)),
        ("browser.newtabpage.activity-stream.feeds.section.topstories", .bool(false)),
        ("browser.newtabpage.activity-stream.showWeather", .bool(false)),
        ("browser.urlbar.suggest.trending", .bool(false)),
        ("browser.translations.automaticallyPopup", .bool(false)),
        ("extensions.formautofill.creditCards.enabled", .bool(false)),
        ("extensions.formautofill.addresses.enabled", .bool(false)),
        ("signon.rememberSignons", .bool(false)),
        ("signon.autofillForms", .bool(false)),
        ("browser.startup.page", .int(0)),
        ("browser.sessionstore.resume_from_crash", .bool(false)),
        ("browser.link.open_newwindow.override.external", .int(2)),
        ("browser.warnOnQuit", .bool(false)),
        ("browser.warnOnQuitShortcut", .bool(false)),
        ("browser.tabs.warnOnClose", .bool(false)),
    ]

    /// How the `user.js` puter-use writes begins: how a folder it set up is told from others (`mayUse`).
    nonisolated static let userJSMark = "// Written by puter-use"

    /// The profile's `user.js`: a line saying who writes it, then a `user_pref(…)` per pref, in order.
    nonisolated static func userJS(_ prefs: [(name: String, value: Pref)]) -> String {
        let head = userJSMark + " each time it starts the agent's own Firefox: changes here are replaced."
        return ([head] + prefs.map { "user_pref(\(quoted($0.name)), \($0.value.js));" }).joined(separator: "\n") + "\n"
    }

    /// Whether puter-use may set up a profile in a folder the setting named: one that's new or empty (`contents`: the
    /// names in it, nil when there's no such folder), or that it set up before (its `user.js`, `userJS`, begins as
    /// puter-use's does). Never a profile of the user's own: the `user.js` written there would replace theirs, and
    /// its settings (no saved logins, no session restore, …) would stay in the profile.
    nonisolated static func mayUse(contents: [String]?, userJS: String?) -> Bool {
        if let userJS { return userJS.hasPrefix(userJSMark) }
        return (contents ?? []).allSatisfy { $0 == ".DS_Store" }
    }

    /// Why a folder the setting named wasn't set up (`mayUse`).
    nonisolated static func notOurs(_ path: String) -> String {
        "PUTER_USE_BROWSER_PROFILE names \(path), which has files puter-use didn't put there (it may be a profile of the "
            + "user's): puter-use writes its own settings into the profile, so it uses only a new or empty folder, or one "
            + "it set up. Your own Firefox wasn't started"
    }

    /// `s` as a JavaScript string literal: in double quotes, with quotes, backslashes and control characters escaped.
    nonisolated static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029:
                out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// Stops a start on a folder the setting named that `mayUse` doesn't allow.
    static func checkFolder() throws {
        guard custom else { return }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: profile.path)
        let js = try? String(contentsOf: profile.appendingPathComponent("user.js"), encoding: .utf8)
        guard mayUse(contents: contents, userJS: js) else { throw HelperError(notOurs(profile.path)) }
    }

    /// Makes the profile's folder if it's missing (only the user can read it: it holds their sign-ins there) and
    /// writes its `user.js`.
    static func writeProfile() throws {
        do {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(userJS(prefs).utf8).write(to: profile.appendingPathComponent("user.js"), options: .atomic)
        } catch {
            throw HelperError("couldn't set up your own Firefox's profile in \(profile.path): \(error.localizedDescription)")
        }
    }

    // MARK: - which process it is

    /// A process's arguments and environment from its `KERN_PROCARGS2` record: the argument count (a 4-byte int),
    /// the executable's path, NUL padding, then each argument and each environment string, NUL-terminated (an empty
    /// one ends the environment). Nil for bytes that aren't such a record.
    nonisolated static func procArgs(_ bytes: [UInt8]) -> (argv: [String], env: [String])? {
        let n = bytes.count
        guard n >= 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0, argc <= 65_536 else { return nil }
        var i = 4
        while i < n, bytes[i] != 0 { i += 1 }  // the executable's path
        while i < n, bytes[i] == 0 { i += 1 }  // and its padding
        func next() -> String? {
            guard i < n else { return nil }
            var j = i
            while j < n, bytes[j] != 0 { j += 1 }
            defer { i = j + 1 }
            return String(decoding: bytes[i..<j], as: UTF8.self)
        }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let a = next() else { return nil }
            argv.append(a)
        }
        var env: [String] = []
        while let e = next(), !e.isEmpty { env.append(e) }
        return (argv, env)
    }

    /// The profile folder a Firefox command line names: the argument after `--profile` (or `-profile`), or in
    /// `--profile=<path>`; else the one a restart of Firefox's own carries in its environment (`XRE_PROFILE_PATH`).
    nonisolated static func profilePath(argv: [String], env: [String] = []) -> String? {
        for (i, a) in argv.enumerated().dropFirst() {
            if a == "--profile" || a == "-profile" { return i + 1 < argv.count ? argv[i + 1] : nil }
            for flag in ["--profile=", "-profile="] where a.hasPrefix(flag) { return String(a.dropFirst(flag.count)) }
        }
        let key = "XRE_PROFILE_PATH="
        return env.first { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
    }

    /// Whether a Firefox command line names `profile` as its profile (`profilePath`: the same folder, with or without
    /// a trailing slash, `.` or `..`).
    nonisolated static func namesProfile(argv: [String], env: [String] = [], profile: String) -> Bool {
        guard let p = profilePath(argv: argv, env: env), !p.isEmpty else { return false }
        return URL(fileURLWithPath: p).standardizedFileURL.path == URL(fileURLWithPath: profile).standardizedFileURL.path
    }

    /// Whether a Firefox command line is the agent's instance: it names `profile` as its profile (`namesProfile`). On
    /// a folder the setting named (`custom`), only one puter-use started is (its environment has `marker`, which a
    /// restart of Firefox's own keeps): a Firefox the user started there is theirs. puter-use's own folder nothing
    /// else uses, so there the profile is enough.
    nonisolated static func isAgents(argv: [String], env: [String] = [], profile: String, custom: Bool = false) -> Bool {
        namesProfile(argv: argv, env: env, profile: profile) && (!custom || env.contains(marker))
    }

    /// Another Firefox using `profile`, which the instance can't be started on: the first of the running Firefoxes'
    /// command lines (`lines`, by pid, none the instance's) that names it, else the process holding its lock
    /// (`holder`). Its pid, nil when there's none.
    nonisolated static func profileUser(_ lines: [(pid: pid_t, argv: [String], env: [String])], holder: pid_t?,
                                        profile: String) -> pid_t? {
        lines.first { namesProfile(argv: $0.argv, env: $0.env, profile: profile) }?.pid ?? holder
    }

    /// Why the instance wasn't started: another Firefox (`pid`) is using its profile (`path`), and Firefox would only
    /// say it's already running.
    nonisolated static func inUse(_ path: String, pid: pid_t) -> String {
        "another Firefox (pid \(pid)) is using the profile in \(path), so your own Firefox wasn't started on it: ask the "
            + "user to quit that Firefox, or to set PUTER_USE_BROWSER_PROFILE to agent or another folder"
    }

    /// The process holding a profile's lock: a running Firefox keeps its profile's `.parentlock` locked (`fcntl`), the
    /// one it found in `profiles.ini` too, with no profile on its command line. Nil when none does, or there's no lock
    /// file. Only asked, never taken.
    nonisolated static func lockHolder(_ profile: URL) -> pid_t? {
        let fd = open(profile.appendingPathComponent(".parentlock").path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_RDLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK), lock.l_pid > 0 else { return nil }
        return lock.l_pid
    }

    /// Another Firefox using the profile now (`profileUser`): a Gecko app's process whose command line names it, or
    /// the one holding its lock.
    static func otherUser() -> pid_t? {
        let lines = NSWorkspace.shared.runningApplications.compactMap { app -> (pid: pid_t, argv: [String], env: [String])? in
            let pid = app.processIdentifier
            guard pid > 0, !app.isTerminated, Windows.isGecko(pid), !isInstance(pid), let c = commandLine(pid) else { return nil }
            return (pid, c.argv, c.env)
        }
        return profileUser(lines, holder: lockHolder(profile).flatMap { isInstance($0) ? nil : $0 }, profile: profile.path)
    }

    /// Process `pid`'s command line and environment, nil if they can't be read (it's gone, or not the user's).
    nonisolated static func commandLine(_ pid: pid_t) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return procArgs(Array(buf.prefix(size)))
    }

    /// Process `pid`'s command line is the instance's (`isAgents`), read now.
    static func confirmed(_ pid: pid_t) -> Bool {
        guard let c = commandLine(pid) else { return false }
        return isAgents(argv: c.argv, env: c.env, profile: profile.path, custom: custom)
    }

    /// The instance as last confirmed: its pid, and when that process started (a pid used again later is another one).
    private static var known: (pid: pid_t, started: Date)?
    /// Firefox processes found not to be it, with when each started, so listings don't read their command lines again.
    private static var others: [pid_t: Date] = [:]

    /// Whether process `pid` is the agent's instance: a Firefox whose command line is its (`isAgents`). Read once per
    /// process.
    static func isInstance(_ pid: pid_t) -> Bool {
        guard pid > 0, let started = Run.startTime(pid) else { return false }
        if let k = known, k.pid == pid {
            if k.started == started { return true }
            known = nil
        }
        if others[pid] == started { return false }
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() == bundleID,
              let c = commandLine(pid) else { return false }
        if isAgents(argv: c.argv, env: c.env, profile: profile.path, custom: custom) {
            known = (pid, started)
            others[pid] = nil
            return true
        }
        if others.count >= 32 { others = [:] }
        others[pid] = started
        return false
    }

    /// The instance running now, looked for again each time: the process last confirmed while it runs, else any
    /// Firefox whose command line names the profile (Firefox can start itself again under another pid, as after an
    /// update). Running Firefoxes are found by their windows too: the system's list of apps can miss one.
    static func running() -> NSRunningApplication? {
        if let k = known, let app = NSRunningApplication(processIdentifier: k.pid), !app.isTerminated, isInstance(k.pid) {
            return app
        }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
            .union(Windows.all().map(\.pid))
        return pids.filter { $0 > 0 }.sorted().lazy.filter(isInstance)
            .compactMap { NSRunningApplication(processIdentifier: $0) }.first { !$0.isTerminated }
    }

    /// How window `w`'s app is named where windows are listed or described: "Firefox (agent)" for the instance's.
    static func label(_ w: WinInfo) -> String { label(w.app, agents: isInstance(w.pid)) }

    nonisolated static func label(_ app: String, agents: Bool) -> String { agents ? app + suffix : app }

    /// The instance's windows an agent can target (`Windows.targetable`), front to back.
    static func windows(_ pid: pid_t) -> [WinInfo] { Windows.targetable().filter { $0.pid == pid } }

    /// Those of the instance running now, none if it isn't.
    static func windows() -> [WinInfo] { running().map { windows($0.processIdentifier) } ?? [] }

    // MARK: - where navigate goes

    /// How an act begun with navigate names its window.
    enum Aim: Equatable {
        case none  // no window given
        case id  // a window's id: whichever window that is, the user's Firefox's too
        case firefox  // Firefox's name or bundle id
        case agent  // "Firefox (agent)", the instance as listings name it
        case other  // another app's name, or "screen"
    }

    /// The window the session is on, for an act with no window.
    enum On: Equatable {
        case none  // none, or not a browser's
        case agents  // one of the instance's
        case usersFirefox  // one of another Firefox's: the user's
        case otherBrowser  // another browser's (Safari, Chrome, …): the agent chose that one
    }

    /// How act's `window` (`v`) names one (`names`: Firefox's, as an app name gives them, any case).
    nonisolated static func aim(_ v: Any?, names: [String] = names) -> Aim {
        if v == nil || v is NSNull { return .none }
        if Handlers.num(v) != nil, !(v is String && Int(v as! String) == nil) { return .id }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return .other }
        let known = Set(names.map { $0.lowercased() })
        if s.hasSuffix(suffix), known.contains(String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)) {
            return .agent
        }
        return known.contains(s) ? .firefox : .other
    }

    /// Whether an act begun with navigate goes to the instance (`Handlers.actTarget`). With the setting on
    /// (`enabled`), one with no window goes there, instead of the user's Firefox or the default browser, unless the
    /// session is on another browser's window; so does one that names Firefox. A window's id still reaches that
    /// window, the user's Firefox's included. Its own name ("Firefox (agent)") goes there with the setting off too,
    /// while it runs.
    nonisolated static func routes(_ aim: Aim, on: On, enabled: Bool) -> Bool {
        switch aim {
        case .agent: return true
        case .id, .other: return false
        case .firefox: return enabled
        case .none: return enabled && on != .otherBrowser
        }
    }

    /// What `routes` needs to know of the session's window.
    static func on() -> On {
        guard let cur = Handlers.current, cur != 0, let w = Windows.info(cur), Handlers.isBrowser(w.pid) else { return .none }
        if isInstance(w.pid) { return .agents }
        return NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier?.lowercased() == bundleID ? .usersFirefox : .otherBrowser
    }

    nonisolated static let notInstalled = "your own Firefox (PUTER_USE_BROWSER_PROFILE) needs Firefox, which isn't installed"
    nonisolated static let absent = "your own Firefox isn't running or has no window (navigate opens one when "
        + "PUTER_USE_BROWSER_PROFILE=agent is set)"

    /// The Firefox app it's an instance of.
    static func appURL() -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    // MARK: - starting it

    /// The instance asked to quit, until it's gone: no other starts on the profile while it still holds it.
    private static var quitting: pid_t?
    /// A start under way: another session's navigate waits for it rather than start a second instance on the
    /// profile (Firefox would put up its "already running" alert).
    private static var starting: Task<NSRunningApplication, Error>?

    /// The instance, started first if it isn't running (`launch`): and whether it was started now (then it has a
    /// window, its first).
    static func instance(launch: Bool) async throws -> (app: NSRunningApplication, started: Bool) {
        touch()
        if let q = quitting {
            let gone = try await Run.pollUntil(floor: 0, every: 0.1, cap: 5) {
                NSRunningApplication(processIdentifier: q)?.isTerminated != false
            }
            guard gone else { throw HelperError("your own Firefox is still quitting: try again in a few seconds") }
            quitting = nil
        }
        if let pending = starting { return (try await pending.value, false) }
        if let app = running() {
            watch()
            return (app, false)
        }
        guard launch else { throw HelperError("your own Firefox isn't running: it's started only when PUTER_USE_BROWSER_PROFILE=agent is set") }
        // Not given up when this request's client hangs up (it's bounded): a session waiting for it would get no reply.
        let task = Task { try await Connection.ungated { try await start() } }
        starting = task
        defer { starting = nil }
        let app = try await task.value
        touch()
        return (app, true)
    }

    /// Its command line's arguments: the profile (its path one argument, though it has a space), and no talk with
    /// another Firefox (links and windows aren't handed to the user's, nor theirs to it).
    nonisolated static func launchArguments(_ profile: String) -> [String] { ["--profile", profile, "--no-remote"] }

    /// Its environment, on top of what the system gives an app: covered windows keep drawing (Firefox otherwise stops
    /// drawing a window no part of which shows unless it's key, and drops its page's accessibility tree:
    /// `Handlers.drawsCovered`), and a mark that puter-use started it (`marker`).
    nonisolated static let launchEnvironment = ["MOZ_WINDOW_OCCLUSION": "0", "PUTER_USE_AGENT_FIREFOX": "1"]

    /// The mark in its environment, as the process's record gives it.
    nonisolated static let marker = "PUTER_USE_AGENT_FIREFOX=1"

    /// Starts the instance in the background and waits for its first window.
    ///
    /// Through the system's app launcher, never as a child process: the helper would be its "responsible process"
    /// then, and Firefox would get the helper's Screen Recording and Accessibility permissions. A new instance even
    /// while the user's Firefox runs, on the profile, which nothing else may use (`--no-remote`: links aren't passed
    /// to another Firefox); not on a folder of the setting's that isn't puter-use's to set up (`checkFolder`), nor
    /// while another Firefox is using the profile (`otherUser`).
    static func start() async throws -> NSRunningApplication {
        guard let url = appURL() else { throw HelperError(notInstalled) }
        try checkFolder()
        if let pid = otherUser() { throw HelperError(inUse(profile.path, pid: pid)) }
        try writeProfile()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.arguments = launchArguments(profile.path)
        cfg.environment = launchEnvironment
        try Connection.check()
        let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        // Its first window, of whichever process names the profile by then.
        let found = try await Run.poll(floor: 0.2, every: 0.2, cap: 20, { () -> NSRunningApplication? in
            guard let app = running(), !windows(app.processIdentifier).isEmpty else { return nil }
            return app
        }) { $0 != nil }
        if let found {
            watch()
            return found
        }
        if !launched.isTerminated, !isInstance(launched.processIdentifier) {
            throw HelperError("Firefox didn't start apart from the user's Firefox, so nothing was done in it")
        }
        watch()
        throw HelperError("your own Firefox started but has no window yet: try again")
    }

    /// Opens a window in the running instance through its File menu (no keys, so none go to a window of the user's
    /// there): the new window once it's there.
    static func openWindow(_ pid: pid_t) async throws -> WinInfo {
        // Not while another session's act drives it: that act could take the new window for one its batch opened.
        try await AppLocks.acquire(pid)
        defer { AppLocks.release(pid) }
        let before = Set(windows(pid).map(\.id))
        guard AX.pressMenuShortcut(pid: pid, keys: ["cmd", "n"]) != nil else {
            throw HelperError("couldn't open a window in your own Firefox (its New Window menu item didn't take)")
        }
        let w = try await Run.poll(floor: 0.1, every: 0.1, cap: 5, { windows(pid).first { !before.contains($0.id) } }) { $0 != nil }
        guard let w else { throw HelperError("your own Firefox opened no new window: try again") }
        return w
    }

    // MARK: - quitting it

    /// When a session last used it (a request aimed at one of its windows, or navigate's start).
    static var lastUse = Date()
    /// Its windows a session opened, kept past that session (an idle one is let go), less those the user has used or
    /// taken over since (`sync`).
    static var opened = Set<CGWindowID>()
    private static var timer: Timer?

    static func touch() { lastUse = Date() }

    /// Whether to quit the instance now: never while it has a window the agent didn't open (`windows` not all in
    /// `agents`: a link the user opened there, or one of the agent's they've used or taken over), nor while an act is
    /// driving it (`busy`); otherwise as the helper exits, or after `idleQuit` with no session using it (`idle`).
    nonisolated static func quits(windows: [CGWindowID], agents: Set<CGWindowID>, idle: TimeInterval, exiting: Bool,
                                  busy: Bool = false) -> Bool {
        guard !busy, windows.allSatisfy(agents.contains) else { return false }
        return exiting || idle >= idleQuit
    }

    /// Brings `opened` up to date with the sessions: the instance's windows (`ids`) in one's own, less those one has
    /// given to the user or that the user has used (`Owner.shared`); windows that closed go.
    static func sync(_ ids: Set<CGWindowID>) {
        let sessions = Array(Session.all.values)
        opened.formUnion(ids.intersection(sessions.flatMap(\.agentWindows)))
        for s in sessions {
            opened.subtract(s.given)
            opened.subtract(s.owned.filter { $0.value.userUsed }.keys)
        }
        opened.formIntersection(ids)
    }

    /// Looks every minute, once it's been started or found for navigate, whether to quit it (`check`).
    static func watch() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    /// Quits the instance if `quits` says so (`exiting`: the helper is). Not while it's starting: it has no window yet.
    static func check(exiting: Bool = false) {
        guard exiting || starting == nil else { return }
        guard let app = running() else {
            timer?.invalidate()
            timer = nil
            return
        }
        let pid = app.processIdentifier, ids = windows(pid).map(\.id)
        sync(Set(ids))
        guard quits(windows: ids, agents: opened, idle: Date().timeIntervalSince(lastUse), exiting: exiting,
                    busy: AppLocks.holder(pid) != nil) else { return }
        // Its command line once more, right before: never another Firefox.
        guard confirmed(pid) else { return }
        quitting = pid
        app.terminate()
        timer?.invalidate()
        timer = nil
    }
}

extension Handlers {
    /// The window an act begun with navigate works in when it goes to the agent's own Firefox (`AgentBrowser.routes`):
    /// the session's window there, or its own there it used last; with none, the instance is started (`launch`: with
    /// the setting on) and its first window is the agent's, or, running, it's given a new window of the agent's
    /// through its menu. Once the policy is known to allow it, read by bundle id before anything starts. With the
    /// setting on, on the profile it names (`AgentBrowser.use`).
    static func agentBrowserTarget(_ first: [String: Any], _ p: [String: Any], launch: Bool) async throws -> Target {
        guard let url = AgentBrowser.appURL() else { throw HelperError(AgentBrowser.notInstalled) }
        do { try checkLaunch(url, first) } catch {
            throw HelperError("nothing was run: action \(max(int(p["first"], 1), 1)) (\(kind(first))) is \(error)")
        }
        if launch, let path = AgentBrowser.requested(p) { try AgentBrowser.use(path) }
        let (app, started) = try await AgentBrowser.instance(launch: launch)
        let pid = app.processIdentifier
        reviewOwnership(pid)  // a window the user took over isn't the session's to pick
        let s = Session.current
        var mine = AgentBrowser.windows(pid).filter { s.agentWindows.contains($0.id) }
        if mine.isEmpty {
            let w: WinInfo
            if started, let launchWindow = AgentBrowser.windows(pid).first { w = launchWindow } else { w = try await AgentBrowser.openWindow(pid) }
            s.agentWindows.insert(w.id)
            AgentBrowser.opened.insert(w.id)
            if let box = Opts(p).windowBox { _ = AX.fit(pid: pid, wid: w.id, box: box) }
            let name = AgentBrowser.label(w.app, agents: true)
            Connection.current?.ownerNotes.append(started
                ? "started your own Firefox (\"\(name)\"), apart from the user's: #\(w.id) is yours. Sites there don't have "
                    + "the user's sign-ins: if one asks, the user can sign in there once"
                : "opened your own window #\(w.id) in \(name)")
            mine = [Windows.info(w.id) ?? w]
        }
        guard let w = pick(mine, current: current, own: s.ownRecent)?.0 else {
            throw HelperError("no window of yours in your own Firefox")
        }
        return used(w)
    }
}
