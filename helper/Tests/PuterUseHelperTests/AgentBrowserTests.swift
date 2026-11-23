import XCTest

@testable import PuterUseHelper

/// The agent's own Firefox: told apart from the user's by the profile its command line names, set up by a `user.js`
/// puter-use writes, where navigate goes when it's on, and when it's quit.
@MainActor
final class AgentBrowserTests: XCTestCase {
    let path = "/Users/ada/Library/Application Support/puter-use/firefox"

    /// A `KERN_PROCARGS2` record as the kernel writes it: the argument count, the executable's path and its padding,
    /// the arguments, the environment, an empty string, then the strings the loader keeps.
    static func record(_ argv: [String], env: [String], argc: Int32? = nil) -> [UInt8] {
        var count = argc ?? Int32(argv.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/Applications/Firefox.app/Contents/MacOS/firefox".utf8) + [0, 0, 0, 0]
        for s in argv + env { bytes += Array(s.utf8) + [0] }
        bytes += [0] + Array("ptr_munge=".utf8) + [0, 0]
        return bytes
    }

    // MARK: - which process it is

    /// The arguments and the environment come apart at the count; the loader's strings after the environment aren't in
    /// it, and an empty argument keeps its place.
    func testACommandLineIsReadFromItsRecord() {
        let argv = ["/Applications/Firefox.app/Contents/MacOS/firefox", "--profile", path, "", "--no-remote"]
        let parsed = AgentBrowser.procArgs(Self.record(argv, env: ["MOZ_WINDOW_OCCLUSION=0", "HOME=/Users/ada"]))
        XCTAssertEqual(parsed?.argv, argv)
        XCTAssertEqual(parsed?.env, ["MOZ_WINDOW_OCCLUSION=0", "HOME=/Users/ada"])
        XCTAssertEqual(AgentBrowser.procArgs(Self.record(["firefox"], env: []))?.env, [])
    }

    /// A running process's own record reads back as its arguments; it isn't the agent's Firefox.
    func testARealProcesssCommandLine() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(AgentBrowser.commandLine(me)?.argv, CommandLine.arguments)
        XCTAssertFalse(AgentBrowser.commandLine(me)?.env.isEmpty ?? true)
        XCTAssertFalse(AgentBrowser.isInstance(me))
        XCTAssertNil(AgentBrowser.commandLine(-1))
    }

    /// Bytes that aren't a whole record read as none, not as a guess.
    func testABrokenRecordReadsAsNone() {
        XCTAssertNil(AgentBrowser.procArgs([]))
        XCTAssertNil(AgentBrowser.procArgs([1, 0]))
        XCTAssertNil(AgentBrowser.procArgs(Self.record(["firefox", "--profile"], env: [], argc: 9)), "fewer arguments than counted")
        XCTAssertNil(AgentBrowser.procArgs(Self.record(["firefox"], env: [], argc: -1)))
    }

    /// Its own command line: the profile after --profile (or -profile, or --profile=), the same folder however it's
    /// written. The user's Firefox, another profile, or a folder beside or inside it isn't it.
    func testOnlyACommandLineNamingTheProfileIsTheAgents() {
        func agents(_ argv: [String], env: [String] = []) -> Bool {
            AgentBrowser.isAgents(argv: ["/Applications/Firefox.app/Contents/MacOS/firefox"] + argv, env: env, profile: path)
        }
        XCTAssertTrue(agents(["--profile", path, "--no-remote"]))
        XCTAssertTrue(agents(["--no-remote", "-profile", path]))
        XCTAssertTrue(agents(["--profile=\(path)"]))
        XCTAssertTrue(agents(["--profile", path + "/"]))
        XCTAssertTrue(agents(["--profile", "/Users/ada/Library/Application Support/puter-use/./firefox"]))
        XCTAssertTrue(agents(["--profile", "/Users/ada/Library/Application Support/puter-use/x/../firefox"]))
        XCTAssertFalse(agents([]), "the user's Firefox")
        XCTAssertFalse(agents(["-P", "default-release"]))
        XCTAssertFalse(agents(["--profile", "/Users/ada/Library/Application Support/Firefox/Profiles/abc.default"]))
        XCTAssertFalse(agents(["--profile", path + "-old"]))
        XCTAssertFalse(agents(["--profile", path + "/sub"]))
        XCTAssertFalse(agents(["--profile"]), "no folder after it")
        XCTAssertFalse(agents(["--profile", ""]))
        XCTAssertFalse(agents(["--url", path]), "the folder elsewhere on the line")
        XCTAssertFalse(AgentBrowser.isAgents(argv: ["--profile", path], profile: path), "the program's own name isn't an argument")
    }

    /// Firefox starting itself again (after an update) may carry the profile in its environment instead; the command
    /// line's own profile comes first.
    func testARestartsProfileComesFromTheEnvironment() {
        XCTAssertTrue(AgentBrowser.isAgents(argv: ["firefox"], env: ["XRE_PROFILE_PATH=\(path)"], profile: path))
        XCTAssertFalse(AgentBrowser.isAgents(argv: ["firefox"], env: ["XRE_PROFILE_PATH=/tmp/other"], profile: path))
        XCTAssertFalse(AgentBrowser.isAgents(argv: ["firefox", "--profile", "/tmp/other"], env: ["XRE_PROFILE_PATH=\(path)"],
                                             profile: path))
        XCTAssertNil(AgentBrowser.profilePath(argv: ["firefox"], env: ["HOME=/Users/ada"]))
    }

    /// What it's started with is what it's known by: the profile is one argument, spaces and all, and its environment
    /// has the mark, on a folder of the setting's too.
    func testItIsKnownByWhatItIsStartedWith() {
        let args = AgentBrowser.launchArguments(path)
        XCTAssertEqual(args, ["--profile", path, "--no-remote"])
        XCTAssertTrue(AgentBrowser.isAgents(argv: ["firefox"] + args, profile: path))
        XCTAssertEqual(AgentBrowser.launchEnvironment, ["MOZ_WINDOW_OCCLUSION": "0", "PUTER_USE_AGENT_FIREFOX": "1"])
        let env = AgentBrowser.launchEnvironment.map { "\($0.key)=\($0.value)" }
        XCTAssertTrue(env.contains(AgentBrowser.marker))
        XCTAssertTrue(AgentBrowser.isAgents(argv: ["firefox"] + args, env: env, profile: path, custom: true))
        XCTAssertTrue(AgentBrowser.profile.path.hasSuffix("/Library/Application Support/puter-use/firefox"))
        XCTAssertEqual(AgentBrowser.profile, AgentBrowser.defaultProfile)
        XCTAssertFalse(AgentBrowser.custom)
    }

    /// On a folder the setting named, only a Firefox puter-use started is the agent's: the user's own Firefox started
    /// on that folder (no mark) isn't, nor is one with the mark on another folder. On puter-use's own folder, the
    /// profile alone tells, as before the mark.
    func testOnAFolderOfTheSettingsOnlyAFirefoxPuterUseStartedIsTheAgents() {
        let argv = ["/Applications/Firefox.app/Contents/MacOS/firefox", "--profile", path]
        let marked = ["HOME=/Users/ada", AgentBrowser.marker]
        XCTAssertTrue(AgentBrowser.isAgents(argv: argv, env: marked, profile: path, custom: true))
        XCTAssertFalse(AgentBrowser.isAgents(argv: argv, env: ["HOME=/Users/ada"], profile: path, custom: true))
        XCTAssertFalse(AgentBrowser.isAgents(argv: argv + ["--no-remote"], env: [], profile: path, custom: true),
                       "the user's, started apart from their other Firefox")
        XCTAssertFalse(AgentBrowser.isAgents(argv: argv, env: ["PUTER_USE_AGENT_FIREFOX=0"], profile: path, custom: true))
        XCTAssertFalse(AgentBrowser.isAgents(argv: argv, env: marked, profile: "/tmp/other", custom: true))
        XCTAssertTrue(AgentBrowser.isAgents(argv: ["firefox"], env: ["XRE_PROFILE_PATH=\(path)", AgentBrowser.marker],
                                            profile: path, custom: true), "restarted by Firefox: the mark stays")
        XCTAssertTrue(AgentBrowser.isAgents(argv: argv, env: [], profile: path), "puter-use's own folder")
        XCTAssertTrue(AgentBrowser.namesProfile(argv: argv, env: [], profile: path + "/"))
    }

    /// The setting as the request carries it: "agent" (any case) for puter-use's own folder, or an absolute path,
    /// standardized. A relative path, a `~` one (the server expands that) or anything else is off.
    func testTheProfileARequestAsksFor() {
        let own = AgentBrowser.defaultProfile.standardizedFileURL.path
        XCTAssertEqual(AgentBrowser.requested(["browser_profile": "agent"]), own)
        XCTAssertEqual(AgentBrowser.requested(["browser_profile": " AGENT "]), own)
        XCTAssertEqual(AgentBrowser.requested(["browser_profile": "/tmp/pu-firefox/"]), "/tmp/pu-firefox")
        XCTAssertEqual(AgentBrowser.requested(["browser_profile": " /a/./b/../Test Profile "]), "/a/Test Profile")
        XCTAssertNil(AgentBrowser.requested([:]))
        for v: Any in ["", "  ", "user", "profiles/test", "~/firefox", true, 1] {
            XCTAssertNil(AgentBrowser.requested(["browser_profile": v]), "\(v)")
        }
        XCTAssertTrue(AgentBrowser.wanted(["browser_profile": "/tmp/pu-firefox"]))
    }

    /// Another Firefox on the profile stops a start: the first command line naming it (however it's written), else
    /// the process holding its lock (the user's Firefox started from the Dock names no profile).
    func testAnotherFirefoxOnTheProfileIsFound() {
        let theirs = (pid: pid_t(41), argv: ["firefox", "--profile", path + "/"], env: [String]())
        let other = (pid: pid_t(40), argv: ["firefox", "-P", "work"], env: [String]())
        let restarted = (pid: pid_t(42), argv: ["firefox"], env: ["XRE_PROFILE_PATH=\(path)"])
        XCTAssertEqual(AgentBrowser.profileUser([other, theirs], holder: nil, profile: path), 41)
        XCTAssertEqual(AgentBrowser.profileUser([other, theirs], holder: 77, profile: path), 41)
        XCTAssertEqual(AgentBrowser.profileUser([restarted], holder: nil, profile: path), 42)
        XCTAssertEqual(AgentBrowser.profileUser([other], holder: 77, profile: path), 77)
        XCTAssertNil(AgentBrowser.profileUser([other], holder: nil, profile: path))
        XCTAssertNil(AgentBrowser.profileUser([], holder: nil, profile: path))
        let msg = AgentBrowser.inUse(path, pid: 41)
        XCTAssertTrue(msg.hasPrefix("another Firefox (pid 41) is using the profile in \(path)"), msg)
        XCTAssertTrue(msg.contains("PUTER_USE_BROWSER_PROFILE"), msg)
    }

    /// A profile's lock is found only while a process holds it; a missing folder or lock file, or one no process
    /// locks, has none. The lock is only asked about: it can still be taken after.
    func testAProfilesLockHolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pu-lock-\(UUID().uuidString)")
        XCTAssertNil(AgentBrowser.lockHolder(dir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(AgentBrowser.lockHolder(dir))
        let file = dir.appendingPathComponent(".parentlock")
        try Data().write(to: file)
        XCTAssertNil(AgentBrowser.lockHolder(dir))
        // A process holding it as Firefox does: a write lock over the whole file, by fcntl.
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else { throw XCTSkip("no perl to hold the lock") }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: perl)
        p.arguments = ["-e", "use Fcntl; $| = 1; open(my $f, '>', $ARGV[0]) or die; "
            + "fcntl($f, F_SETLK, pack('q q l s s', 0, 0, 0, F_WRLCK, SEEK_SET)) or die $!; print \"locked\\n\"; sleep 20",
            file.path]
        p.standardOutput = out
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        XCTAssertEqual(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self), "locked\n")
        XCTAssertEqual(AgentBrowser.lockHolder(dir), p.processIdentifier)
        p.terminate()
        p.waitUntilExit()
        XCTAssertNil(AgentBrowser.lockHolder(dir), "let go as it quit")
    }

    /// A folder the setting names is set up only when it's new or empty, or puter-use set it up before (its user.js
    /// is puter-use's): never a profile of the user's, whose user.js and settings it would replace.
    func testOnlyANewEmptyOrOwnFolderIsSetUp() {
        XCTAssertTrue(AgentBrowser.mayUse(contents: nil, userJS: nil), "no such folder yet")
        XCTAssertTrue(AgentBrowser.mayUse(contents: [], userJS: nil))
        XCTAssertTrue(AgentBrowser.mayUse(contents: [".DS_Store"], userJS: nil))
        XCTAssertTrue(AgentBrowser.mayUse(contents: ["user.js", "prefs.js", "cookies.sqlite"],
                                          userJS: AgentBrowser.userJS(AgentBrowser.prefs)))
        XCTAssertFalse(AgentBrowser.mayUse(contents: ["prefs.js", "times.json", "logins.json"], userJS: nil), "the user's profile")
        XCTAssertFalse(AgentBrowser.mayUse(contents: ["user.js", "prefs.js"], userJS: "user_pref(\"a\", true);\n"),
                       "a user.js of the user's own")
        XCTAssertFalse(AgentBrowser.mayUse(contents: ["notes.txt"], userJS: nil))
        XCTAssertTrue(AgentBrowser.notOurs("/tmp/p").hasPrefix("PUTER_USE_BROWSER_PROFILE names /tmp/p, which has files"))
    }

    /// While it runs on one profile, a request for another is told so, naming both.
    func testARequestForAnotherProfileWhileItRuns() {
        let msg = AgentBrowser.otherProfile(running: path, asked: "/tmp/p")
        XCTAssertTrue(msg.hasPrefix("your own Firefox is already running on the profile in \(path), not /tmp/p"), msg)
        XCTAssertNoThrow(try AgentBrowser.use(AgentBrowser.defaultProfile.path + "/"), "the profile it has: nothing to do")
        XCTAssertEqual(AgentBrowser.profile, AgentBrowser.defaultProfile)
    }

    // MARK: - the profile

    /// One `user_pref` line per pref, in order, under a line saying who writes the file; strings are quoted.
    func testTheUserJSHasALinePerPref() {
        let js = AgentBrowser.userJS([("a.b", .bool(false)), ("c", .int(2)), ("d", .string("say \"hi\"\\\n"))])
        XCTAssertEqual(js.split(separator: "\n", omittingEmptySubsequences: false), [
            "// Written by puter-use each time it starts the agent's own Firefox: changes here are replaced.",
            "user_pref(\"a.b\", false);",
            "user_pref(\"c\", 2);",
            "user_pref(\"d\", \"say \\\"hi\\\"\\\\\\n\");",
            "",
        ])
        XCTAssertEqual(AgentBrowser.quoted("ignore"), "\"ignore\"")
        XCTAssertEqual(AgentBrowser.quoted("a\u{1}b"), "\"a\\u0001b\"")
    }

    /// The profile has no first-run pages, remote New Tab content, translation pop-up, autofill or saved logins, no
    /// restored session, links from other apps in their own window, and nothing asking to be the default browser.
    func testTheProfilesPrefs() {
        var prefs: [String: AgentBrowser.Pref] = [:]
        for (name, value) in AgentBrowser.prefs {
            XCTAssertNil(prefs[name], "\(name) is set once")
            prefs[name] = value
        }
        let expected: [String: AgentBrowser.Pref] = [
            "browser.preonboarding.enabled": .bool(false),
            "browser.aboutwelcome.enabled": .bool(false),
            "datareporting.policy.dataSubmissionEnabled": .bool(false),
            "datareporting.policy.dataSubmissionPolicyBypassNotification": .bool(true),
            "toolkit.telemetry.reportingpolicy.firstRun": .bool(false),
            "browser.shell.checkDefaultBrowser": .bool(false),
            "browser.startup.homepage_override.mstone": .string("ignore"),
            "trailhead.firstrun.didSeeAboutWelcome": .bool(true),
            "browser.newtabpage.enabled": .bool(false),
            "browser.newtabpage.activity-stream.feeds.topsites": .bool(false),
            "browser.newtabpage.activity-stream.feeds.section.topstories": .bool(false),
            "browser.translations.automaticallyPopup": .bool(false),
            "extensions.formautofill.creditCards.enabled": .bool(false),
            "extensions.formautofill.addresses.enabled": .bool(false),
            "signon.rememberSignons": .bool(false),
            "signon.autofillForms": .bool(false),
            "browser.startup.page": .int(0),
            "browser.sessionstore.resume_from_crash": .bool(false),
            "browser.link.open_newwindow.override.external": .int(2),
            "browser.warnOnQuit": .bool(false),
        ]
        for (name, value) in expected { XCTAssertEqual(prefs[name], value, name) }
        XCTAssertFalse(prefs.keys.contains { $0.contains("defaultBrowser") && $0 != "browser.shell.checkDefaultBrowser" })
        let js = AgentBrowser.userJS(AgentBrowser.prefs)
        XCTAssertTrue(js.contains("user_pref(\"browser.link.open_newwindow.override.external\", 2);"))
        XCTAssertEqual(js.split(separator: "\n").count, AgentBrowser.prefs.count + 1)
    }

    // MARK: - where navigate goes

    /// How act's window names one: an id (as a number or digits), Firefox (by name or bundle id, any case), its
    /// agent instance as listings name it, or anything else.
    func testHowAWindowIsNamed() {
        XCTAssertEqual(AgentBrowser.aim(nil), .none)
        XCTAssertEqual(AgentBrowser.aim(NSNull()), .none)
        XCTAssertEqual(AgentBrowser.aim(244), .id)
        XCTAssertEqual(AgentBrowser.aim("244"), .id)
        XCTAssertEqual(AgentBrowser.aim(NSNumber(value: 244)), .id)
        XCTAssertEqual(AgentBrowser.aim("Firefox"), .firefox)
        XCTAssertEqual(AgentBrowser.aim(" firefox "), .firefox)
        XCTAssertEqual(AgentBrowser.aim("org.mozilla.firefox"), .firefox)
        XCTAssertEqual(AgentBrowser.aim("Firefox (agent)"), .agent)
        XCTAssertEqual(AgentBrowser.aim("firefox (AGENT)"), .agent)
        XCTAssertEqual(AgentBrowser.aim("Safari"), .other)
        XCTAssertEqual(AgentBrowser.aim("screen"), .other)
        XCTAssertEqual(AgentBrowser.aim("#244"), .other, "an element's number, not a window's")
        XCTAssertEqual(AgentBrowser.aim("Firefox agent"), .other)
        XCTAssertEqual(AgentBrowser.aim("Safari (agent)"), .other)
        XCTAssertEqual(AgentBrowser.aim(""), .other)
    }

    /// With the setting on, navigate with no window, or aimed at Firefox by name, goes to the agent's own Firefox
    /// (unless the session is on another browser's window); an id still reaches any window. Off, only its own name
    /// does. Another app's name never.
    func testWhereNavigateGoes() {
        typealias A = AgentBrowser
        for on: A.On in [.none, .agents, .usersFirefox] {
            XCTAssertTrue(A.routes(.none, on: on, enabled: true), "\(on)")
            XCTAssertFalse(A.routes(.none, on: on, enabled: false), "\(on)")
        }
        XCTAssertFalse(A.routes(.none, on: .otherBrowser, enabled: true), "the agent chose that browser")
        for on: A.On in [.none, .agents, .usersFirefox, .otherBrowser] {
            XCTAssertTrue(A.routes(.firefox, on: on, enabled: true))
            XCTAssertFalse(A.routes(.firefox, on: on, enabled: false))
            XCTAssertFalse(A.routes(.id, on: on, enabled: true), "a window's id reaches that window")
            XCTAssertFalse(A.routes(.other, on: on, enabled: true))
            XCTAssertTrue(A.routes(.agent, on: on, enabled: true))
            XCTAssertTrue(A.routes(.agent, on: on, enabled: false), "named, it's used while it runs")
        }
    }

    /// The setting as the request carries it.
    func testTheRequestAsksForIt() {
        XCTAssertTrue(AgentBrowser.wanted(["browser_profile": "agent"]))
        XCTAssertTrue(AgentBrowser.wanted(["browser_profile": " Agent "]))
        XCTAssertTrue(AgentBrowser.wanted(["browser_profile": "/Users/ada/pu-firefox"]))
        XCTAssertFalse(AgentBrowser.wanted([:]))
        XCTAssertFalse(AgentBrowser.wanted(["browser_profile": "user"]))
        XCTAssertFalse(AgentBrowser.wanted(["browser_profile": true]))
    }

    /// Listings and replies name its windows' app apart from the user's Firefox; that name reaches it again.
    func testItsAppIsNamedApart() {
        XCTAssertEqual(AgentBrowser.label("Firefox", agents: true), "Firefox (agent)")
        XCTAssertEqual(AgentBrowser.label("Firefox", agents: false), "Firefox")
        XCTAssertEqual(AgentBrowser.aim(AgentBrowser.label("Firefox", agents: true)), .agent)
    }

    // MARK: - when it's quit

    /// Never while it has a window the agent didn't open, nor while an act drives it; else as the helper exits, or
    /// after 30 minutes with no session using it. With no window at all, the same.
    func testWhenItIsQuit() {
        let mine: Set<CGWindowID> = [5, 6]
        func quits(_ wins: [CGWindowID], idle: TimeInterval, exiting: Bool = false, busy: Bool = false) -> Bool {
            AgentBrowser.quits(windows: wins, agents: mine, idle: idle, exiting: exiting, busy: busy)
        }
        XCTAssertFalse(quits([5], idle: 60))
        XCTAssertFalse(quits([5, 6], idle: 30 * 60 - 1))
        XCTAssertTrue(quits([5, 6], idle: 30 * 60))
        XCTAssertTrue(quits([5], idle: 0, exiting: true))
        XCTAssertTrue(quits([], idle: 31 * 60))
        XCTAssertTrue(quits([], idle: 0, exiting: true))
        XCTAssertFalse(quits([5, 9], idle: 3 * 3600), "a link the user opened there")
        XCTAssertFalse(quits([9], idle: 0, exiting: true), "the user's window, as the helper exits too")
        XCTAssertFalse(quits([5], idle: 3600, busy: true))
        XCTAssertFalse(quits([5], idle: 0, exiting: true, busy: true))
    }
}
