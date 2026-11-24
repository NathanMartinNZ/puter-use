import AppKit
import ApplicationServices

/// `screenshot(read: …)`: the whole text of a text area, text field or document, the parts scrolled
/// out of view too, a page at a time. A look like any other: nothing is pressed, typed or changed, and
/// the clipboard isn't used. A web page, or a part of one, is read whole as Markdown, paged the same way
/// (WebRead.swift). The `read` action does the same inside a batch, or reads a region's text, at its point
/// in the batch (click a tab, wait_for, read).
extension Handlers {
    /// Roles whose value is the text they show.
    nonisolated static let readable: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXStaticText"]

    /// Whether a request's `read` asks for a read (a number, text, a target spec or true; not false).
    nonisolated static func readRequested(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { return (v as? Bool) == true }
        return true
    }

    /// Characters `offset..<offset+limit` of `s`, where that part ends, and how many characters `s` has.
    /// Past the end, the part is empty and ends at `offset`.
    nonisolated static func page(_ s: String, offset: Int, limit: Int) -> (text: String, end: Int, total: Int) {
        let part = textPart(s, offset: offset, limit: limit)
        return (part.text, part.end, part.total)
    }

    /// As `page`, and where the part starts: a negative `offset` counts from the end (`startOffset`), so
    /// -2000 is the last 2,000 characters, and `start` says where that is in the whole.
    nonisolated static func textPart(_ s: String, offset: Int, limit: Int) -> (text: String, start: Int, end: Int, total: Int) {
        let total = s.count, start = startOffset(offset, total: total)
        guard start < total else { return ("", start, start, total) }
        let part = String(s.dropFirst(start).prefix(limit))
        return (part, start, start + part.count, total)
    }

    /// Where a read from `offset` starts in a text of `total` characters: below 0, that many from the end (from
    /// the start when the text is shorter); otherwise `offset` itself.
    nonisolated static func startOffset(_ offset: Int, total: Int) -> Int {
        offset < 0 ? max(0, total + offset) : offset
    }

    /// How many matches a search lists, how much of the text it shows each side of one (about 150 characters
    /// around it in all), and how many it counts at most.
    nonisolated static let queryShown = 10, queryContext = 75, queryCount = 10_000

    /// Where `query` is in `s` from character `start` on, case-insensitively and in whole characters: a line
    /// for each of the first `queryShown` matches, `@offset: …the text around it…` (line breaks shown as ⏎,
    /// one for one), then how many more there are and the offset to search on from. With none, one line
    /// saying so (`whose`: whose characters were searched, e.g. "the clipboard's "). At most `limit`
    /// characters in all. `count`: the matches from `start` on (counting stops at `queryCount`). Offsets count
    /// characters, as pages do, so a read from one starts at its match. Curly quotes, dashes and no-break spaces
    /// match their plain marks ("we've" finds "we’ve"), and the lines show the text as it is.
    nonisolated static func textMatches(_ s: String, query: String, from start: Int, limit: Int,
                                        in whose: String = "") -> (text: String, count: Int) {
        let start = max(0, start)
        var lines: [String] = [], count = 0, used = 0, full = false, next = start
        // Searched folded (`AX.fold1`), one for one: its characters, and so the offsets, are those of `s`.
        let f = AX.fold1(s), q = AX.fold1(query)
        if !query.isEmpty, var i = f.index(f.startIndex, offsetBy: start, limitedBy: f.endIndex) {
            var at = start  // the offset of `i`
            let room = limit - 50  // for the lines, leaving room to say how many more
            while count < queryCount, let r = f.range(of: q, options: .caseInsensitive, range: i..<f.endIndex) {
                guard let lo = String.Index(r.lowerBound, within: f), let hi = String.Index(r.upperBound, within: f),
                      lo < hi else {
                    let on = f.index(after: r.lowerBound)  // part of a character (an accent, a skin tone): search on past it
                    at += f.distance(from: i, to: on)
                    i = on
                    continue
                }
                at += f.distance(from: i, to: lo)
                let end = at + f.distance(from: lo, to: hi)
                count += 1
                if !full && lines.count < queryShown {
                    let shown = AX.unfolded(lo..<hi, of: f, in: s)  // the text as it is
                    let line = "@\(at): " + snippet(s, shown.lowerBound, shown.upperBound)
                    let adds = (lines.isEmpty ? 0 : 1) + line.count
                    if lines.isEmpty || used + adds <= room {
                        lines.append(line)
                        used += adds
                        next = end
                    } else {
                        full = true  // the rest are counted, and searched on for from the last one listed
                    }
                }
                at = end
                i = hi
            }
        }
        guard count > 0 else {
            let line = "no match for \"\(AX.clip(query, 60))\"" + (start > 0 ? " from offset \(start) of" : " in")
                + " \(whose)\(s.count) characters"
            return (String(line.prefix(limit)), 0)
        }
        if count > lines.count {
            lines.append("+\(count - lines.count) \(count >= queryCount ? "or more" : "more") (search on with offset \(next))")
        }
        return (String(lines.joined(separator: "\n").prefix(limit)), count)
    }

    /// The text around `lo..<hi` in `s`: up to `queryContext` characters each side, on one line (line breaks
    /// shown as ⏎, one for one), with … where it's cut off.
    nonisolated static func snippet(_ s: String, _ lo: String.Index, _ hi: String.Index) -> String {
        let a = s.index(lo, offsetBy: -queryContext, limitedBy: s.startIndex) ?? s.startIndex
        let b = s.index(hi, offsetBy: queryContext, limitedBy: s.endIndex) ?? s.endIndex
        let one = String(s[a..<b].map { $0.isNewline ? Character("⏎") : $0 })
        return (a > s.startIndex ? "…" : "") + one + (b < s.endIndex ? "…" : "")
    }

    /// How a read names what it read: `[12] textarea "Notes"`.
    nonisolated static func readName(_ id: Int, _ name: String, _ label: String?) -> String {
        "[\(id)] \(name == "web" ? "web area" : name)" + (label.map { " \"\(AX.clip($0, 40))\"" } ?? "")
    }

    /// `read`: the element's text from `offset` (`limit` characters, as `clipboard` pages; a negative offset
    /// counts from the end), with what it is and where that part is in the whole: `read_range` = [start, end,
    /// total]. With a `query`, where that is in the text instead (`readReply`).
    static func readText(_ t: Target, _ what: Any, _ p: [String: Any]) async throws -> [String: Any] {
        guard case .window(let w) = t else { throw HelperError("read needs a window, not the screen") }
        var out = try readPart(try await readTarget(what, w, t), p, in: w)
        out["window"] = describe(t)
        return out
    }

    /// The text of the element `found` (its number and node) from `p`'s `offset`, `limit` characters, or
    /// where `p`'s `query` is in it (`readReply`). Never a password field's, nor a search of one.
    /// A web page (`AXWebArea`), a part of one with no text of its own (a list, a table, a section), or a
    /// window or group holding a page, is read as the page's Markdown instead (`readPage`, in window `w`;
    /// `again`: reading on may use the text the last read of it made).
    /// `takes`: how the request names what to read, for the error when the element holds no text.
    static func readPart(_ found: (Int, AX.Node), _ p: [String: Any], in w: WinInfo? = nil,
                         takes: String = "(its number or what it shows), or true for the focused one",
                         again: Bool = true) throws -> [String: Any] {
        let (id, n) = found
        let role = AX.value(n.element, kAXRoleAttribute) as? String ?? n.role
        let label = role == "AXStaticText" ? AX.value(n.element, kAXValueAttribute) as? String : AX.label(n.element)
        let it = readName(id, n.name, label.flatMap { $0.isEmpty ? nil : $0 })
        let wid = w?.id ?? AX.windowID(n.element) ?? 0
        if role == "AXWebArea" { return readPage(n.element, it: it, p, wid: wid, again: again) }  // the whole page
        if Policy.isSecure(n.element) { throw HelperError("not allowed: \(it) is a password field") }
        guard readable.contains(role) else {
            if let root = WebRead.root(for: n.element) {
                var name = it
                if !CFEqual(root, n.element) {  // a page in a window or group is named as the page
                    let (pageID, page) = pageNode(root, wid)
                    name = readName(pageID, "web", page.label)
                }
                return readPage(root, it: name, p, wid: wid, again: again)
            }
            throw HelperError("\(it) has no text to read: read takes a text area, text field, document or web page \(takes)")
        }
        guard let s = AX.value(n.element, kAXValueAttribute) as? String else {
            throw HelperError("\(it) doesn't give its text to accessibility: read what's shown with region and image=false")
        }
        return readReply(s, it, p)
    }

    /// What a read of text `s` (named `it`) replies, from `p`'s `offset` (below 0, from the end), `limit` and
    /// `query`. A page: `read`, the text; `read_range` = [start, end, total], where it is in the whole (a
    /// negative offset given as where it came to), so a read from `end` goes on with nothing missed. A search
    /// (`query`, `textMatches`): `read`, the matches, each at its offset; `read_query`; `read_matches`, how many;
    /// `read_range` = [start, total, total], the part searched. `read_of`: `it`.
    nonisolated static func readReply(_ s: String, _ it: String, _ p: [String: Any]) -> [String: Any] {
        let offset = int(p["offset"], 0)
        let limit = min(max(1, int(p["limit"], Clipboard.readLimit)), Clipboard.maxRead)
        if let q = p["query"] as? String, !q.isEmpty {
            let total = s.count, start = startOffset(offset, total: total)
            let found = textMatches(s, query: q, from: start, limit: limit)
            return ["read": found.text, "read_of": it, "read_query": q, "read_matches": found.count,
                    "read_range": [start, max(start, total), total]]
        }
        let part = textPart(s, offset: offset, limit: limit)
        return ["read": part.text, "read_of": it, "read_range": [part.start, part.end, part.total]]
    }

    /// Part of the latest full screenshot, in its pixels: top-left (x0, y0) to bottom-right (x1, y1).
    struct Region: Equatable {
        var x0, y0, x1, y1: Double
    }

    /// A region as screenshot and read take it: [x0, y0, x1, y1], pixels of the latest full screenshot, either
    /// corner first. Nil for anything else.
    nonisolated static func regionPoints(_ v: Any?) -> Region? {
        guard let r = v as? [Any], r.count == 4, let x0 = num(r[0]), let y0 = num(r[1]), let x1 = num(r[2]),
              let y1 = num(r[3]) else { return nil }
        return Region(x0: min(x0, x1), y0: min(y0, y1), x1: max(x0, x1), y1: max(y0, y1))
    }

    /// That region in global points, through the latest full screenshot of `t` (`toGlobal`: none, and it fails).
    static func regionRect(_ t: Target, _ r: Region) throws -> CGRect {
        let a = try toGlobal(t, r.x0, r.y0), b = try toGlobal(t, r.x1, r.y1)
        return CGRect(x: a.x, y: a.y, width: max(1, b.x - a.x), height: max(1, b.y - a.y))
    }

    /// How a read names a region it read: `region (10,20)-(300,400)`.
    nonisolated static func regionName(_ r: Region) -> String {
        "region (\(Int(r.x0)),\(Int(r.y0)))-(\(Int(r.x1)),\(Int(r.y1)))"
    }

    /// The text shown in `region` (global points) of window `w`: what accessibility gives (at most `AX.textCap`
    /// characters, saying so), else read off the pixels. A text area there that doesn't say which of its lines
    /// it shows has its part read off the pixels too (`missedText`), so none of it goes missing without a word;
    /// so has a web page there with nothing in it yet (`pageText`), once it's been asked again a moment later (a
    /// web view builds its tree when first asked). A read that gave only the window's title over a `roomy` region
    /// is asked again a moment later too, and read off the pixels if it's no better (a web view's host may hold
    /// nothing yet, not even an empty page). Password fields are left out.
    static func regionText(_ t: Target, _ w: WinInfo, _ region: CGRect) async throws -> String {
        try await regionText(region, read: { AX.areaText(pid: w.pid, wid: w.id, within: region) },
                             pause: { try await Run.pause($0) },
                             look: { try await OCR.read(try await sharpShot(t, region: $0)) })
    }

    /// Whether a read of `region` (global points) gave all of the window's title but none of what the window
    /// shows there, though the region could hold a few lines (`AX.roomy`).
    nonisolated static func titleOnly(_ got: AX.AreaText, _ region: CGRect) -> Bool {
        got.titleOnly && region.width >= AX.roomy.width && region.height >= AX.roomy.height
    }

    /// `regionText` with what it asks for passed in: `read` reads the region's text through accessibility,
    /// `pause` waits, and `look` reads a part of the screen (global points) off its pixels.
    static func regionText(_ region: CGRect, read: () -> AX.AreaText?, pause: (Double) async throws -> Void,
                           look: (CGRect) async throws -> [OCR.Line]) async throws -> String {
        var got = read()
        if let g = got, !g.pages.isEmpty || titleOnly(g, region) {  // not built yet, maybe: ask again
            try await pause(0.15)
            got = read()
        }
        // Nothing exposed there, or just the title over nothing known: read the pixels.
        if got == nil || got?.text == "(no text in that area)" || got.map({ titleOnly($0, region) && $0.pages.isEmpty }) == true {
            let lines = try await look(region)
            if !lines.isEmpty { return "(read off the screen)\n" + OCR.text(lines) }
            return got.map { pageText(missedText($0.text, $0.missed, read: []), $0.pages, read: []) } ?? "(no text in that area)"
        }
        guard let got, !got.missed.isEmpty || !got.pages.isEmpty else { return got?.text ?? "(no text in that area)" }
        func readOff(_ parts: [CGRect]) async -> [String] {
            var read: [String] = []
            for part in parts.prefix(3) {
                let lines = (try? await look(part)) ?? []
                if !lines.isEmpty { read.append(OCR.text(lines)) }
            }
            return read
        }
        let read = await readOff(got.missed), pageRead = await readOff(got.pages)
        return pageText(missedText(got.text, got.missed, read: read), got.pages, read: pageRead)
    }

    /// `text` with what was read off the screen (`read`) of the parts of the area over web pages that had nothing
    /// in them yet (`pages`), after it; or, with none of that read, the note that their text is missing.
    nonisolated static func pageText(_ text: String, _ pages: [CGRect], read: [String]) -> String {
        guard !pages.isEmpty else { return text }
        let some = read.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !some.isEmpty else { return text + "\n" + AX.pageNote }
        return text + "\n(a web page's text here, read off the screen)\n" + some.joined(separator: "\n")
    }

    /// What accessibility read in an area (`text`), with what was read off the screen (`read`) of the parts of it
    /// over text areas that didn't say which of their lines they show there (`missed`); or, with none of that
    /// read, the note that their text is missing.
    nonisolated static func missedText(_ text: String, _ missed: [CGRect], read: [String]) -> String {
        guard !missed.isEmpty else { return text }
        let some = read.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !some.isEmpty else { return text + "\n" + AX.missedNote }
        return text + "\n(a text area's lines here, read off the screen)\n" + some.joined(separator: "\n")
    }

    /// What a `read` action reads: an element by number, one by what it shows (`target`), a region's text, or,
    /// with none of them, the focused text.
    enum ReadSource {
        case element(Int)
        case target(Any)
        case region(Region)
        case focused
    }

    /// The `read` action's source, from its keys. One at most; a region's text comes whole (no paging or search).
    nonisolated static func readSource(_ a: [String: Any]) throws -> ReadSource {
        func given(_ k: String) -> Bool { a[k] != nil && !(a[k] is NSNull) }
        let named = ["element", "target", "region"].filter(given)
        if named.count > 1 { throw HelperError("read takes one of element, target or region, not \(named.joined(separator: " and "))") }
        if given("region") {
            guard let r = regionPoints(a["region"]) else {
                throw HelperError("read's region is [x0, y0, x1, y1]: pixels in the latest full screenshot")
            }
            if given("offset") || given("limit") {
                throw HelperError("offset and limit page an element's text: a region's text comes whole (up to "
                    + "\(AX.textCap) characters). Read the element itself (element or target) to page through it")
            }
            if let q = a["query"] as? String, !q.isEmpty {
                throw HelperError("query searches an element's text: a region's text comes whole (up to \(AX.textCap) "
                    + "characters). Read the element itself (element or target) to search it")
            }
            return .region(r)
        }
        if given("element") {
            guard let n = num(a["element"]).map({ Int($0) }) ?? elementNumber(a["element"]) else {
                throw HelperError("read's element is a number from an outline, find or marks")
            }
            return .element(n)
        }
        if given("target") { return .target(a["target"]!) }
        return .focused
    }

    /// `read` in act: the text of an element (its whole text, a page at a time, as `screenshot(read: …)`), or of
    /// a region (as `screenshot(region: …, image: false)`), at its point in the batch, for the reply's `reads`.
    /// A look: the policy's check on looking applies, nothing is pressed, and password fields are never read.
    static func readStep(_ a: [String: Any], _ t: Target) async throws -> [String: Any] {
        guard case .window(let w) = t else { throw HelperError("read needs a window, not the screen") }
        try Policy.checkLook(w.pid)
        let takes = "(element or target), or with neither for the focused one"
        var out: [String: Any]
        switch try readSource(a) {
        case .region(let r):
            let text = try await regionText(t, w, try regionRect(t, r))
            return ["read_of": regionName(r), "read": text]
        case .focused:
            out = try readPart(try await readFocused(w, t, asked: "read with no element, target or region"), a, in: w, takes: takes,
                               again: false)
        case .element(let idx):
            out = try readPart((idx, try await numbered(w, idx, t)), a, in: w, takes: takes, again: false)
        case .target(let v):
            // A macro step: what it read, where it was when the macro was saved (`elementNode` knows macro steps).
            if a["units"] as? String == "pt", let n = try await elementNode(a, t) {
                out = try readPart((AX.registry(w.id).number(n), n), a, in: w, takes: takes, again: false)
            } else {
                let found = try await findOneOrRevive(v, t)
                out = try readPart(found, a, in: w, takes: takes, again: false)
            }
        }
        // What a read notes (a page cut short) goes with the act's notes: the reply's reads carry only text.
        if let more = out.removeValue(forKey: "notes") as? [String] { notes += more }
        return out
    }

    /// An element number as a read names one: a number, a number as text, or `#` and digits as outlines write
    /// numbers (`#12`), spaces around it aside. Nil for anything else, a label: `#12 open issues`, true.
    nonisolated static func elementNumber(_ v: Any?) -> Int? {
        guard let v, !(v is NSNull), CFGetTypeID(v as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let n = Int(s) { return n }
        guard s.hasPrefix("#"), s.count > 1, s.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s.dropFirst())
    }

    /// The element `what` names in `w`: a number (`12`, `"12"` or `"#12"`), what it shows (as `target`), or true
    /// for the focused text.
    static func readTarget(_ what: Any, _ w: WinInfo, _ t: Target) async throws -> (Int, AX.Node) {
        if CFGetTypeID(what as CFTypeRef) == CFBooleanGetTypeID() { return try await readFocused(w, t) }
        if let idx = elementNumber(what) { return (idx, try await numbered(w, idx, t)) }
        return try await findOneOrRevive(what, t)
    }

    /// The text that has the keyboard focus in `w` (or in what's open over it); else the window's only
    /// text area. Otherwise it fails, listing the text areas and fields to choose from (`asked`: how the
    /// request asked for the focused text, for that error).
    ///
    /// A window showing a web page reads the page instead: the page has the focus, or a link or button or
    /// field in it does, or the browser's own address bar does, or nothing does. Only a text area being
    /// written in on a page (a comment box, an editor) is read as itself.
    static func readFocused(_ w: WinInfo, _ t: Target, asked: String = "read: true", again: Bool = false) async throws -> (Int, AX.Node) {
        if let f = AX.value(AX.appElement(w.pid), kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            let role = AX.value(el, kAXRoleAttribute) as? String ?? ""
            let here = AX.windowID(el).map { $0 == w.id || openOver(w).contains($0) } == true
            if here, let page = AX.webAreas(of: el).last {  // the whole page, not a frame in it
                if role != "AXTextArea" { return pageNode(page, w.id) }
            } else if here, readable.contains(role), AX.isBrowserAddressBar(el, pid: w.pid), let page = windowPage(w) {
                return page
            }
            if here, readable.contains(role) {
                var name = AX.roleNames[role] ?? String(role.dropFirst(2)).lowercased()
                switch AX.value(el, kAXSubroleAttribute) as? String {
                case "AXSearchField": name = "search"
                case "AXSecureTextField": name = "password"
                default: break
                }
                let id = AX.registry(w.id).number(AX.Node(element: el, frame: AX.frame(el), role: role,
                                                          label: role == "AXStaticText" ? nil : AX.label(el), name: name))
                return (id, try AX.node(w.id, id))
            }
        }
        if let page = windowPage(w) { return page }
        if !again, isBrowser(w.pid) {
            do { try await checkDrawn(t) } catch is Redrawn {
                return try await readFocused(w, t, asked: asked, again: true)
            } catch let e as NotDrawn {
                throw e
            }
        }
        let areas = AX.search(pid: w.pid, windows: [w.id], query: "", role: "textarea", limit: 10)
        if areas.count == 1 {
            let id = number(areas[0], w.id)
            return (id, try AX.node(w.id, id))
        }
        let all = areas + AX.search(pid: w.pid, windows: [w.id], query: "", role: "field", limit: 10)
        let list = all.prefix(8).map { describe($0, id: number($0, w.id), t) }
        throw HelperError("\(asked) reads the focused text, and the keyboard focus isn't on text in this window. "
            + (list.isEmpty ? "The window shows no text areas or fields: name what to read by its number or what it shows"
                : "Name what to read by its number or what it shows: " + list.joined(separator: "; ")
                    + (all.count > 8 ? "; and \(all.count - 8) more" : "")))
    }
}
