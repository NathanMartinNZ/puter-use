import AppKit
import ApplicationServices

/// Windows their app has stopped drawing. Browsers stop drawing a window no part of which shows (Firefox one that
/// wasn't its key window as it got covered, and it stays so until part of it shows again, key or not; Chrome and
/// Safari throttle one too): a capture then gives the window as it last drew it, while its title goes on changing, and
/// a page that loaded meanwhile may have no accessibility tree. Being
/// covered doesn't prove it (a covered window can draw on, and frame sums miss rounded corners and see-through
/// overlays), so a window counts as not drawn only on direct evidence, and only while none of it shows (`notDrawn`);
/// what's over it says why. A Firefox started with `MOZ_WINDOW_OCCLUSION` off draws its covered windows on, so one of
/// its windows that's only covered is in view (`drawsCovered`). It's worked out only on a sign (a title that changed, a page whose address can't be read,
/// a look that found nothing), never on every act. Then a picture of it may be old: the reply says so, coordinates
/// read off it stop, and a look for something in it that finds nothing fails at once rather than wait for what can't
/// come.
extension Handlers {
    /// What accessibility shows of a browser window's page: no web page in the window (`missing`), one with nothing
    /// in it (`empty`), one still loading, or one with something in it (`shown`).
    enum PageTree: Equatable { case missing, empty, loading, shown }

    /// What's in the way of a window being seen: nothing (some of it shows), other windows over all of it (or it's on
    /// no display), or it's minimized, on another Space, or its app is hidden.
    enum Cover: Equatable { case inView, covered, minimized, otherSpace, hidden }

    /// A window its app isn't drawing, as found: whether its page can't be read (a browser's page with no
    /// accessibility tree though its address bar names one), its title now when the picture shows an older one, what's
    /// in the way of it, whether it's its app's key window (nil: not known), whether its app is a Firefox that
    /// would draw it covered if started with `MOZ_WINDOW_OCCLUSION=0` (`firefox`: a Gecko app started without it), and
    /// why its app wasn't brought forward to draw it, when the agent should hear that (`notForward`: `forwardWhy`).
    struct Frozen: Equatable {
        var unread = false
        var title: String?
        var cover: Cover = .inView
        var key: Bool?
        var firefox = false
        var notForward: String?
        var declined = false  // user explicitly declined the focus prompt to bring it forward
    }

    /// How long a page's missing tree is given to come before it counts (s): a browser can attach a new page's tree a
    /// moment after the page.
    nonisolated static let frozenRecheck = 0.5

    // MARK: - the evidence

    /// Whether a new capture (`sig`) shows a window its app has stopped drawing: its title now (`title`) isn't the one
    /// it had when it was last drawn (`drawn`, kept with the agent's last picture), yet the capture is that picture
    /// pixel for pixel (`last`). A window that draws shows a new title too (in its title bar or its tab), so both can't
    /// hold. No title, or none kept, says nothing.
    nonisolated static func undrawn(title: String?, drawn: String?, sig: Signature, last: Signature?) -> Bool {
        guard let title, let drawn, let last, title != drawn else { return false }
        return sig == last
    }

    /// What a new picture of a window (`sig`, taken while its title is `title`) keeps of the last one (`old`): when
    /// it's that picture pixel for pixel, nothing has been drawn since, so it keeps that one's title (the one it
    /// shows) and what showed its app wasn't drawing it (`Meta.frozen`). Else the title now, and nothing showed yet.
    nonisolated static func kept(_ old: Meta?, sig: Signature, title: String?) -> (title: String?, frozen: Frozen?) {
        guard let old, old.sig == sig else { return (title, nil) }
        return (old.title ?? title, old.frozen)
    }

    /// Whether a browser window's page has no accessibility tree (`tree`: none, or an empty one that isn't loading;
    /// nil: not known) though its address bar names a page (`address`, `namesPage`).
    nonisolated static func treeMissing(_ tree: PageTree?, address: String?) -> Bool {
        guard tree == .missing || tree == .empty, let address else { return false }
        return namesPage(address)
    }

    /// Whether a window counts as not drawn: a capture showed it (`undrawn`), or its page has no tree (`treeMissing`),
    /// while none of it shows (`cover`). A window in view is drawn: there a tree is only late, and a title that changed
    /// with nothing else is one the app doesn't show.
    nonisolated static func notDrawn(undrawn: Bool, treeMissing: Bool, cover: Cover) -> Bool {
        (undrawn || treeMissing) && cover != .inView
    }

    /// Whether an address bar's text is an address rather than words being searched for: one word, with a scheme
    /// ("https://…", "about:config", "file:///…"), or a host first ("example.com/a", "localhost:3000", "127.0.0.1").
    nonisolated static func looksLikeAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return false }
        if t.range(of: "^[a-z][a-z0-9+.-]*://", options: .regularExpression) != nil { return true }
        if t.range(of: "^(about|data|blob|view-source):.", options: .regularExpression) != nil { return true }
        let host = t.prefix { !"/?#".contains($0) }.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        if host == "localhost" || host.hasPrefix("[") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
        else { return false }
        // A name ends in letters (its domain); one of only digits is an IPv4 address, four of them.
        return labels.last!.contains(where: \.isLetter) || (labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) })
    }

    /// Whether an address bar's text names a page: an address (`looksLikeAddress`) other than a blank page's (which
    /// has nothing in it to read).
    nonisolated static func namesPage(_ s: String) -> Bool {
        looksLikeAddress(s) && s.trimmingCharacters(in: .whitespaces).lowercased() != "about:blank"
    }

    // MARK: - what's in the way

    /// What's in the way of a window being seen (`Cover`): its app hidden, the window minimized, off screen otherwise
    /// (on another Space), or on screen with every part of it that's on a display under the windows over it
    /// (`under`). `frame` and `above` in global points, `displays` the displays' bounds. A window of an app that
    /// draws its covered windows on (`drawsCovered`) is in view when only covered: nothing's in the way of its drawing.
    nonisolated static func cover(onScreen: Bool, minimized: Bool, appHidden: Bool, frame: CGRect, above: [CGRect],
                                  displays: [CGRect], drawsCovered: Bool = false) -> Cover {
        if appHidden { return .hidden }
        if minimized { return .minimized }
        if !onScreen { return .otherSpace }
        return !drawsCovered && under(frame, above, displays: displays) ? .covered : .inView
    }

    /// Whether a Firefox's environment (its process's, `AgentBrowser.procArgs`) turns off its watch on covered
    /// windows: `MOZ_WINDOW_OCCLUSION` set to anything but "1" (the first such string, as the process reads it). It
    /// draws a window no part of which shows then, and keeps its page's accessibility tree; a minimized one it still
    /// stops drawing.
    nonisolated static func drawsCovered(env: [String]) -> Bool {
        let key = "MOZ_WINDOW_OCCLUSION="
        guard let e = env.first(where: { $0.hasPrefix(key) }) else { return false }
        return e.dropFirst(key.count) != "1"
    }

    /// Processes `drawsCovered` has read, with when each started (a pid used again later is another process).
    private static var coveredDrawn: [pid_t: (started: Date, drawn: Bool)] = [:]

    /// Whether process `pid` draws its covered windows on: a Firefox (any Gecko app) started with its watch on them
    /// off (`drawsCovered(env:)`), as the agent's own Firefox is. Read once per process.
    static func drawsCovered(_ pid: pid_t) -> Bool {
        guard pid > 0, Windows.isGecko(pid), let started = Run.startTime(pid) else { return false }
        if let r = coveredDrawn[pid], r.started == started { return r.drawn }
        guard let c = AgentBrowser.commandLine(pid) else { return false }
        let drawn = drawsCovered(env: c.env)
        if coveredDrawn.count >= 32 { coveredDrawn = [:] }
        coveredDrawn[pid] = (started, drawn)
        return drawn
    }

    /// Whether no part of a window (`frame`) shows: each part of it on a display lies under the windows over it
    /// (`above`) taken together (`VerifyEdit.covered`); one on no display doesn't show either. Its edges come in a
    /// point first, so frames a rounding apart still cover it.
    nonisolated static func under(_ frame: CGRect, _ above: [CGRect], displays: [CGRect]) -> Bool {
        let inner = frame.insetBy(dx: 1, dy: 1)
        guard !inner.isNull, !inner.isEmpty else { return true }
        for d in displays {
            let part = inner.intersection(d)
            guard !part.isNull, !part.isEmpty else { continue }
            let over = above.map { $0.intersection(part) }.filter { !$0.isNull && !$0.isEmpty }
            if !VerifyEdit.covered(part, by: over) { return false }
        }
        return true
    }

    /// Of the windows over window `wid` (`above`, front to back, from the window server), the frames that hide it
    /// where they lie: ordinary windows (layer 0) drawn at all (alpha above 0), not the window itself, nor puter-use's
    /// own (`own`, its pid: its pointer is an ordinary window too).
    nonisolated static func covering(_ above: [WinInfo], of wid: CGWindowID, own: pid_t) -> [CGRect] {
        above.filter { $0.layer == 0 && $0.alpha > 0 && $0.id != wid && $0.pid != own }.map(\.frame)
    }

    /// What's in the way of window `w` being seen (`cover`), from the window server (what's over it, the displays),
    /// its app (hidden; whether it draws its covered windows on, `drawsCovered`) and, for one off screen, its
    /// accessibility (minimized; asked without switching on a browser's tree, as `keyWindow` asks); and whether it's
    /// its app's key window.
    static func coverOf(_ w: WinInfo) -> (cover: Cover, key: Bool?) {
        let fresh = Windows.info(w.id) ?? w
        let hidden = NSRunningApplication(processIdentifier: w.pid)?.isHidden == true
        let drawn = fresh.onScreen && !hidden && drawsCovered(w.pid)
        let above = fresh.onScreen && !drawn ? covering(Windows.above(w.id), of: w.id, own: Windows.ownPID) : []
        let c = cover(onScreen: fresh.onScreen, minimized: !fresh.onScreen && !hidden && minimized(w), appHidden: hidden,
                      frame: fresh.frame, above: above, displays: displayBounds(), drawsCovered: drawn)
        return (c, keyWindow(w.pid).map { $0 == w.id })
    }

    /// The active displays' bounds (global points, top-left origin, as windows' frames are).
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Whether window `w` is minimized, as its app's accessibility says, without switching on a browser's tree.
    static func minimized(_ w: WinInfo) -> Bool {
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, caretTimeout)
        for el in AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(el, &id) == .success, id == w.id { return AX.value(el, kAXMinimizedAttribute) as? Bool == true }
        }
        return false
    }

    // MARK: - looking

    /// A browser window's page as accessibility shows it (`AX.pageTree`) and the address its address bar shows
    /// (`AX.addressBar`). Nil when its window can't be found.
    static func browserPage(_ w: WinInfo) -> (tree: PageTree?, address: String?)? {
        guard let win = AX.window(pid: w.pid, wid: w.id) else { return nil }
        return (AX.pageTree(in: win), AX.addressBar(in: win)?.address)
    }

    /// Whether window `w` isn't being drawn, from what's been read already: a capture showed it (`undrawn`), or its
    /// page (`page`, read with its address bar) has no tree, still so a moment later; while none of the window shows
    /// (`notDrawn`). `drawn`: the title the agent's last picture shows, for the title now when that's another. Nil with
    /// no evidence; what's over the window is only asked when there is some.
    static func frozenFound(_ w: WinInfo, undrawn: Bool, page: (tree: PageTree?, address: String?)?, drawn: String?) async throws -> Frozen? {
        let missing = page.map { treeMissing($0.tree, address: $0.address) } ?? false
        guard undrawn || missing else { return nil }
        let fresh = Windows.info(w.id) ?? w
        let (cover, key) = coverOf(fresh)
        guard notDrawn(undrawn: undrawn, treeMissing: missing, cover: cover) else { return nil }
        if missing, !undrawn {
            try await Run.pause(frozenRecheck)
            guard let again = browserPage(w), treeMissing(again.tree, address: again.address) else { return nil }
        }
        let title = drawn.flatMap { fresh.title != $0 && !fresh.title.isEmpty ? fresh.title : nil }
        return Frozen(unread: missing, title: title, cover: cover, key: key,
                      firefox: Windows.isGecko(w.pid) && !drawsCovered(w.pid))
    }

    /// Whether window `t` isn't being drawn now, asked when a look for something in it finds nothing, or before
    /// coordinates read off a picture of it: its title changed since the agent's last picture and a capture now is that
    /// picture pixel for pixel (`undrawn`; captured as that picture was), or, with `tree` (asking its accessibility
    /// switches on no tree that isn't on already, or the caller's look has), its page has no tree (`frozenFound`). Nil
    /// with no evidence.
    static func frozenNow(_ t: Target, tree: Bool) async throws -> Frozen? {
        guard case .window(let w) = t, let fresh = Windows.info(w.id) else { return nil }
        let m = meta[w.id]
        var undrawn = false
        if let m, let drawn = m.title, fresh.title != drawn, let sizing = m.sizing {
            var o = Opts([:])
            o.sizing = sizing
            if let shot = try? await plan(t, region: nil, o).run() {
                undrawn = Self.undrawn(title: fresh.title, drawn: drawn, sig: Signature(shot.image), last: m.sig)
            }
        }
        let page = tree && isBrowser(w.pid) ? browserPage(fresh) : nil
        return try await frozenFound(fresh, undrawn: undrawn, page: page, drawn: m?.title)
    }

    /// Whether match `m` is one of browser window `w`'s own controls (its tabs, its toolbar: not in a web page) rather
    /// than its page: in a window its app isn't drawing, the only kind there is, and the page's title is among them.
    static func chromeOnly(_ m: AX.Match, _ w: WinInfo) -> Bool {
        !m.inPage && isBrowser(w.pid) && AX.windowID(m.element) == w.id
    }

    /// Stops a look in window `t` that found nothing (or would read its picture next) when its app isn't drawing it
    /// (`frozenNow`, `tree` as there): what it would go by can't be trusted, and waiting won't change that. What's kept
    /// of the agent's picture is marked too (`Meta.frozen`). First its app is brought forward for a moment to draw it
    /// again, when that's allowed (`revive`): drawn again, the look starts over (`Redrawn`).
    static func checkDrawn(_ t: Target, tree: Bool = true) async throws {
        guard case .window(let w) = t, var f = try await frozenNow(t, tree: tree) else { return }
        if await revive(w, &f) { throw Redrawn() }
        meta[w.id]?.frozen = f
        throw NotDrawn(frozen: f, app: w.app, wid: w.id)
    }

    /// A reply about window `w` with what shows its app isn't drawing it, when something does: a note, the reply's
    /// picture marked `stale`, and what's kept of the agent's picture marked (`Meta.frozen`, so coordinates read off
    /// it stop). Looked at only on a sign: the reply's picture is the last one pixel for pixel though the title has
    /// changed, or was judged so then and is still the same (`Meta.frozen`, kept by `remember`: dropped once the
    /// window is in view); the end of an act found the window as that picture with another title (`undrawnEnd`); or
    /// its page's address couldn't be read, so the page and its address bar were (`page`). First its app is brought
    /// forward for a moment to draw it again, when that's allowed (`revive`): drawn again, the reply looks again
    /// (`recapture`: its picture, or what it read, taken anew) and says nothing of it not being drawn.
    static func staleReply(_ out: [String: Any], _ w: WinInfo, undrawnEnd: Bool = false,
                           page: (tree: PageTree?, address: String?)? = nil,
                           recapture: (() async throws -> [String: Any])? = nil) async throws -> [String: Any] {
        let picture = out["image"] != nil && out["verified"] as? Bool != true
        let m = meta[w.id]
        let carried = picture ? m?.frozen : nil
        var undrawn = undrawnEnd
        if picture, let drawn = m?.title, let now = Windows.info(w.id)?.title, now != drawn { undrawn = true }
        guard undrawn || carried != nil || page != nil else { return out }
        var f = try await frozenFound(w, undrawn: undrawn, page: page, drawn: m?.title)
        if f == nil, var c = carried {  // nothing new: as it was judged, with the title and what's in the way now
            (c.cover, c.key) = coverOf(w)
            // In view now, it's drawn: a picture that's still the last one pixel for pixel shows the window as it
            // is (a title it doesn't show changed), so the verdict goes.
            guard c.cover != .inView else {
                meta[w.id]?.frozen = nil
                return out
            }
            let now = Windows.info(w.id)?.title
            c.title = m?.title.flatMap { now != $0 && now?.isEmpty == false ? now : nil }
            f = c
        } else if page == nil, carried?.unread == true {
            f?.unread = true  // its page wasn't looked at again
        }
        guard var f else { return out }
        var out = out
        if await revive(w, &f) {
            guard let recapture, let again = try? await recapture() else { return out }
            out.merge(again) { _, new in new }
            for k in ["stale", "change_box", "change_fraction"] { out[k] = nil }
            if again["image"] != nil {
                out["changed"] = true
                meta[w.id]?.frozen = nil  // the agent's picture is a new one, of the window drawn
            }
            return out
        }
        meta[w.id]?.frozen = f
        if picture { out["stale"] = true }
        // A look that stopped for it (`NotDrawn`), or navigate's page wait, says so already: not again in a note.
        let notes = out["notes"] as? [String] ?? []
        if !saysNotDrawn((out["errors"] as? [String] ?? []) + notes, app: w.app, wid: w.id) {
            out["notes"] = notes + [frozenNote(f, app: w.app, wid: w.id, last: !picture)]
        }
        return out
    }

    /// Whether a reply's errors and notes (`said`) already say `app` isn't drawing window `wid` (`frozenError`), so the
    /// not-drawn note would only say it again.
    nonisolated static func saysNotDrawn(_ said: [String], app: String, wid: CGWindowID) -> Bool {
        let text = "\(app) isn't drawing #\(wid)"
        return said.contains { s in
            var from = s.startIndex
            while let r = s.range(of: text, range: from..<s.endIndex) {
                if r.upperBound == s.endIndex || !s[r.upperBound].isNumber { return true }  // not #120 for #12
                from = r.upperBound
            }
            return false
        }
    }

    // MARK: - words

    /// Why `app` may not be drawing the window (`f.cover`), in a few words; nil when nothing's in the way. Not whether
    /// it's the app's key window: that counts only as it gets covered, and making it key later doesn't bring it back.
    nonisolated static func frozenWhy(_ f: Frozen, app: String) -> String? {
        switch f.cover {
        case .inView: return nil
        case .covered: return "it's covered"
        case .minimized: return "it's minimized"
        case .otherSpace: return "it's on another Space"
        case .hidden: return "\(app) is hidden"
        }
    }

    /// Why `app` may not be drawing the window (`frozenWhy`) and why it wasn't brought forward to draw it
    /// (`f.notForward`), in a few words; nil with neither.
    nonisolated static func frozenReasons(_ f: Frozen, app: String) -> String? {
        let parts = [frozenWhy(f, app: app), f.notForward.map { "not brought forward: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// The title now, for a message, when the picture shows another (` (the title is now "…")`), or nothing.
    nonisolated static func titleNow(_ f: Frozen) -> String {
        f.title.map { " (the title is now \"\(AX.clip($0, 60))\")" } ?? ""
    }

    /// What to do about a window `app` isn't drawing (`f`). Only its showing again brings it back: making it the app's
    /// key window, or holding the app active, doesn't once it's been covered. For good, the user's Firefox can be
    /// started so it draws covered windows on (`occlusionTip`).
    nonisolated static func frozenRemedy(_ f: Frozen, app: String, wid: CGWindowID) -> String {
        if f.declined {
            return "don't retry right now; wait until the user leaves \(app) or brings #\(wid) into view"
                + occlusionTip(f, app: app)
        }
        return "ask the user to bring #\(wid) into view (even partly), or use activate (raises it to just below the user's front window, so it shows) if they agree"
            + occlusionTip(f, app: app)
    }

    /// How the user can keep a Firefox (`f.firefox`) drawing a window that's covered (`f.cover`), as a clause to end a
    /// message with; nothing for any other window, or one minimized (that stops it all the same).
    nonisolated static func occlusionTip(_ f: Frozen, app: String) -> String {
        guard f.firefox, f.cover == .covered else { return "" }
        return "; the user can stop this by starting \(app) with MOZ_WINDOW_OCCLUSION=0 (see puter-use's docs)"
    }

    /// What a look in a browser window `app` isn't drawing found only in its own controls says of that.
    nonisolated static func notInPage(app: String) -> String {
        "it shows only in \(app)'s tabs or toolbar, not in the page"
    }

    /// The note on a picture of window `wid` that `app` isn't drawing (`f`), or on the agent's last picture of it
    /// (`last`, when the reply has none): that it isn't, why, that the picture may be old (with the title now, when it
    /// shows another), that the page can't be read, when it can't, and how the user can stop it (`occlusionTip`).
    nonisolated static func frozenNote(_ f: Frozen, app: String, wid: CGWindowID, last: Bool) -> String {
        let why = frozenReasons(f, app: app).map { " (\($0))" } ?? ""
        return "\(app) isn't drawing #\(wid)\(why): \(last ? "your last picture of it" : "this picture") may be old\(titleNow(f))"
            + (f.unread ? ", and the page can't be read" : "") + occlusionTip(f, app: app)
    }

    /// The error for a look in window `wid` that `app` isn't drawing (`f`): that it isn't, why, what can't be trusted,
    /// and what to do.
    nonisolated static func frozenError(_ f: Frozen, app: String, wid: CGWindowID) -> String {
        let why = frozenReasons(f, app: app).map { " (\($0))" } ?? ""
        let what = f.unread ? "its page can't be read, and its picture may be old" : "its picture may be old"
        let next = frozenRemedy(f, app: app, wid: wid)
        return "\(app) isn't drawing #\(wid)\(why): \(what)\(titleNow(f)). " + next.prefix(1).uppercased() + next.dropFirst()
    }

    /// Why a coordinate action stops (`AimCheck.stop`) in window `wid` that `app` isn't drawing (`f`), and what to do
    /// instead: by element or target where its page can still be read, and a new picture once it's in view.
    nonisolated static func staleAim(_ f: Frozen, app: String, wid: CGWindowID) -> (why: String, next: String) {
        let why = frozenReasons(f, app: app).map { ": \($0)" } ?? ""
        let next = frozenRemedy(f, app: app, wid: wid), then = " Take a new screenshot once it's in view."
        return ("the last picture of #\(wid) may be old (\(app) isn't drawing it\(why)), so coordinates from it can't be trusted",
                (f.unread ? next.prefix(1).uppercased() + next.dropFirst() + "." : "Aim by element or target instead, or \(next).")
                    + then)
    }

    /// Why a coordinate action stops in window `wid`, which `app` wasn't drawing at the agent's last picture of it and
    /// which it has just been brought forward to draw again (`revive`), when it doesn't look as that picture does.
    nonisolated static func redrawnSince(app: String, wid: CGWindowID) -> String {
        "the last picture of #\(wid) may be old (\(app) wasn't drawing it then), and #\(wid) has been drawn again since, "
            + "so coordinates from it can't be trusted"
    }

    /// Why a coordinate action stops in window `wid`, which `app` wasn't drawing at the agent's last picture of it and
    /// which has come into view since, so it may show something else now.
    nonisolated static func unseenSinceInView(app: String, wid: CGWindowID) -> String {
        "the last picture of #\(wid) may be old (\(app) wasn't drawing it then), and #\(wid) has come into view since, so "
            + "coordinates from it can't be trusted"
    }

    // MARK: - coordinates

    /// What an action does about a picture that may be old: goes ahead, stops, or asks first whether the window is
    /// being drawn now (`frozenNow`).
    enum AimCheck: Equatable { case go, stop, look }

    /// Whether action `a` may go by the agent's last picture of its window: only one aimed by coordinates (read off that
    /// picture; not by element or target, which accessibility aims) is checked, with the guard on (`guarded`), not in
    /// foreground mode and not in a window the batch moved to (it stops for that already). It stops when the window
    /// wasn't being drawn at that picture (`frozenThen`), and asks whether it is now only on a sign: its title has
    /// changed since the picture (`titleChanged`), as it would over a window that isn't drawn.
    nonisolated static func aimCheck(_ a: [String: Any], guarded: Bool, foreground: Bool, moved: Bool, frozenThen: Bool,
                                     titleChanged: Bool) -> AimCheck {
        guard aimsByCoordinates(a), guarded, !foreground, !moved else { return .go }
        if frozenThen { return .stop }
        return titleChanged ? .look : .go
    }

    /// What a coordinate action `aimCheck` stops does once what's in the way of its window is asked again.
    enum Recheck: Equatable {
        case go  // in view, and as the agent's picture shows it: the picture holds after all
        case stop  // still out of view: its app isn't drawing it
        case retake  // in view, but not as the picture shows it: it may show something else by now
    }

    /// The recheck (`Recheck`) from what's in the way of the window now (`cover`) and, for one in view (asked only
    /// then), whether a capture now is the agent's last picture pixel for pixel (`holds`; nil: it couldn't be taken).
    nonisolated static func recheckAim(cover: Cover, holds: Bool?) -> Recheck {
        guard cover == .inView else { return .stop }
        return holds == true ? .go : .retake
    }

    /// Whether the agent's last picture of window `t` still shows it: a capture now, made as that picture was, is that
    /// picture pixel for pixel. Nil when that can't be told (no picture kept, or the capture failed).
    static func pictureHolds(_ t: Target) async -> Bool? {
        guard let m = meta[t.key], let sizing = m.sizing else { return nil }
        var o = Opts([:])
        o.sizing = sizing
        guard let shot = try? await plan(t, region: nil, o).run() else { return nil }
        return Signature(shot.image) == m.sig
    }

    // MARK: - window size

    /// Whether an image's reply gives its window's size in points (`window_pt`): when its scale (px/pt, as the reply
    /// gives it, to two places) isn't that of the last image of the window the agent was shown (`last`), so the same
    /// window doesn't seem to change size. Not for the first image, nor a zoom (its coordinates stay the window's).
    nonisolated static func tellsWindowSize(scale: Double, last: Double?, zoom: Bool) -> Bool {
        guard !zoom, let last else { return false }
        return (scale * 100).rounded() != (last * 100).rounded()
    }

    // MARK: - the address bar's address

    /// An address bar's address as a reply gives a page's (`shortURL`): one shown without its scheme (as browsers show
    /// most) is read as https for that, and given without it again.
    nonisolated static func shortAddress(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains("://") || t.range(of: "^[a-z][a-z0-9+.-]*:[^0-9]", options: [.regularExpression, .caseInsensitive]) != nil {
            return shortURL(t)
        }
        let u = shortURL("https://" + t)
        return u.hasPrefix("https://") ? String(u.dropFirst(8)) : u
    }
}

/// A look that can't be trusted: the window's app isn't drawing it (`Handlers.Frozen`), so its page can't be read or
/// its picture is old. Thrown where an action reads what the window shows (by accessibility or off its picture) and
/// finds nothing, so it fails at once rather than wait for what can't come.
struct NotDrawn: Error, CustomStringConvertible {
    let frozen: Handlers.Frozen
    let app: String
    let wid: CGWindowID
    var description: String { Handlers.frozenError(frozen, app: app, wid: wid) }

    /// The error for `what` (as `Spec` describes it) not found by accessibility in that window (`Miss`).
    func missing(_ what: String) -> Miss { Miss(description: "nothing shows \(what) by accessibility, and \(self)") }

    /// A target's miss in a window its app isn't drawing. It says only that: the labels like it that a miss lists
    /// otherwise (`nearHint`) would be the browser's own controls there (its tabs, its toolbar), never the page's.
    struct Miss: Error, CustomStringConvertible { let description: String }
}

extension AX {
    /// How a walk through a window's controls ended: what it looked for was found, every element was seen, or it ran
    /// out of visits first.
    enum ChromeWalk { case found, whole, cut }

    /// Breadth first through a browser window's own controls, never into a page, `visits` elements at most: `look`
    /// gets each element's `attrs`, and whether it's in one of the window's toolbars, until it returns true (found).
    /// `read` gives an element's `attrs`.
    static func walkChrome(_ win: AXUIElement, visits: Int, read: (AXUIElement) -> [AnyObject]?,
                           look: (AXUIElement, [AnyObject], Bool) -> Bool) -> ChromeWalk {
        var level: [(el: AXUIElement, toolbar: Bool)] = [(win, false)]
        var seen = 0
        while !level.isEmpty {
            var next: [(el: AXUIElement, toolbar: Bool)] = []
            for (el, toolbar) in level {
                seen += 1
                guard seen <= visits else { return .cut }
                guard let vals = read(el), vals.count > 5 else { continue }
                if look(el, vals, toolbar) { return .found }
                let role = vals[0] as? String
                if role == "AXWebArea" { continue }
                next += (vals[5] as? [AXUIElement] ?? []).map { ($0, toolbar || role == "AXToolbar") }
            }
            level = next
        }
        return .whole
    }

    /// A browser window's address bar and the address it shows: the first text input in one of the window's toolbars
    /// whose value looks like an address (`Handlers.looksLikeAddress`: a search box's words don't), found breadth first
    /// through the window's own controls (`walkChrome`). `read` gives an element's `attrs` (for tests).
    static func addressBar(in win: AXUIElement, visits: Int = 400,
                           read: (AXUIElement) -> [AnyObject]? = readAttrs) -> (field: AXUIElement, address: String)? {
        let inputs: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]
        var hit: (field: AXUIElement, address: String)?
        _ = walkChrome(win, visits: visits, read: read) { el, vals, toolbar in
            guard toolbar, let role = vals[0] as? String, inputs.contains(role), let v = vals[4] as? String,
                  Handlers.looksLikeAddress(v) else { return false }
            hit = (el, v.trimmingCharacters(in: .whitespaces))
            return true
        }
        return hit
    }

    /// What a browser window's address bar holds as it is, empty on a new tab: the first text input in one of the
    /// window's toolbars (`walkChrome`). Nil with none found. `read` gives an element's `attrs` (for tests).
    static func addressText(in win: AXUIElement, visits: Int = 400, read: (AXUIElement) -> [AnyObject]? = readAttrs) -> String? {
        let inputs: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]
        var hit: String?
        _ = walkChrome(win, visits: visits, read: read) { _, vals, toolbar in
            guard toolbar, let role = vals[0] as? String, inputs.contains(role) else { return false }
            hit = vals[4] as? String ?? ""
            return true
        }
        return hit
    }

    /// What a browser window's accessibility shows of its page (`Handlers.PageTree`): its first web area, found breadth
    /// first through the window's own controls (`walkChrome`), and whether that has anything in it or says it's still
    /// loading (`loading`). Nil when the walk ran out of visits before finding one: not known. `read` gives an
    /// element's `attrs` (for tests).
    static func pageTree(in win: AXUIElement, visits: Int = 600, read: (AXUIElement) -> [AnyObject]? = readAttrs,
                         loading: (AXUIElement) -> Bool = pageLoading) -> Handlers.PageTree? {
        var page: (el: AXUIElement, vals: [AnyObject])?
        let walk = walkChrome(win, visits: visits, read: read) { el, vals, _ in
            guard vals[0] as? String == "AXWebArea" else { return false }
            page = (el, vals)
            return true
        }
        guard let page else { return walk == .whole ? .missing : nil }
        if !(page.vals[5] as? [AXUIElement] ?? []).isEmpty { return .shown }
        return loading(page.el) ? .loading : .empty
    }

    /// Whether a web page says it's still loading (not loaded, or busy).
    static func pageLoading(_ page: AXUIElement) -> Bool {
        value(page, "AXLoaded") as? Bool == false || value(page, "AXBusy") as? Bool == true
    }
}
