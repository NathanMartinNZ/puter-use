import AppKit
import ApplicationServices

/// `read` on a web page: the whole page as Markdown, the parts scrolled out of view too, in one go instead of a
/// screen at a time. Headings as `#`…, paragraphs whole (never clipped), lists as `- `, tables as `| a | b |` rows,
/// an image by its alt text when that says something, links as `[label](#n)` and controls as `[button "Submit"](#n)`
/// or `[field "Email" ="ada@example.org"](#n)`, numbered as the window's outline numbers them, so a number works as
/// `element` straight away (one out of view is scrolled to first). Paged and searched as any text `read` reads
/// (`readReply`). A look: nothing is pressed or typed, and a password field's value is never read.
///
/// The walk (`walk`) reads the page into a tree of `Item`s, within a time and an element budget; writing that out
/// (`markdown`) needs no accessibility, so it can be tried on made-up pages.
enum WebRead {
    /// The most elements a read walks (it stops sooner at `AX.walkBudget`), and the most it gives new numbers to:
    /// past that, links and controls are written without one (each can still be named by what it says, as a target).
    static let nodeCap = 8000, numberCap = 1500
    /// The most columns a table row shows (the last of them says how many more there are).
    static let tableColumns = 10
    /// How deep a walk goes.
    static let maxDepth = 80

    /// An element of a page as the reader takes it: what the walk read, for `markdown` to write out.
    final class Item {
        let role: String
        var subrole: String?
        /// What it's called: its own title or description, else the text that titles it (a form's label), its
        /// placeholder or its help.
        var name: String?
        /// Its own title, description, placeholder or help (as `AX.label` reads them): how to tell it's still the
        /// same element when its number is used.
        var ownLabel: String?
        var value: String?  // what it holds: a text's words, a field's text, a heading's level; never a password's
        var numeric = false  // that was a number
        var focused = false, enabled = true, selected = false
        var rect: CGRect?
        var away = false  // out of view when it was read: it's scrolled to before it's acted on
        var element: AXUIElement?
        var parent: AXUIElement?
        var kids: [Item]

        init(_ role: String, _ name: String? = nil, value: String? = nil, subrole: String? = nil, rect: CGRect? = nil,
             kids: [Item] = []) {
            self.role = role
            self.name = name
            self.value = value
            self.subrole = subrole
            self.rect = rect
            self.kids = kids
            ownLabel = name
        }
    }

    /// What an element is to the reader.
    enum Kind { case text, link, control, image, heading, list, table, page, marker, container }

    /// Roles written as a control in a line: `[button "Submit"](#n)`.
    static let controls: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXPopUpButton", "AXMenuButton", "AXSlider", "AXIncrementor", "AXColorWell", "AXDateField", "AXTimeField",
        "AXSwitch", "AXToggle", "AXDisclosureTriangle", "AXTab", "AXMenuItem",
    ]

    /// Roles whose children the walk leaves alone: a text's runs, what a field shows of its value, a pop-up's menu.
    static let leaves: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXMenuButton",
        "AXSlider", "AXIncrementor", "AXColorWell", "AXDateField", "AXTimeField", "AXImage", "AXListMarker",
        "AXProgressIndicator", "AXLevelIndicator", "AXBusyIndicator",
    ]

    static func kind(_ it: Item) -> Kind {
        switch it.role {
        case "AXStaticText": return .text
        case "AXLink": return .link
        case "AXImage": return .image
        case "AXHeading": return .heading
        case "AXList": return .list
        case "AXTable": return .table
        case "AXWebArea": return .page
        case "AXListMarker": return .marker
        default: return controls.contains(it.role) ? .control : .container
        }
    }

    // MARK: - the walk

    /// Why a walk stopped before the end: out of time (`slow`, an app answering slowly) or out of elements, and how
    /// many it had read by then.
    struct Cut: Equatable {
        var slow: Bool
        var walked: Int
    }

    /// The page (or part of one) at `root` as a tree, every part of it, in view or not (`visible`, global points, is
    /// what's in view: what's outside is marked `away`). Table columns (their cells are the rows' again) and scroll
    /// bars are left out, and so is what has no size and nothing in it (a page's hidden bits; a wrapper of no size
    /// round what shows stays, as does a control). A password field's value isn't kept. It stops after `budget` s or
    /// `maxNodes` elements with what it has, saying so (`Cut`). `now` and `read` are there for tests.
    static func walk(_ root: AXUIElement, visible: CGRect, budget: TimeInterval = AX.walkBudget, maxNodes: Int = nodeCap,
                     now: () -> TimeInterval = AX.uptime,
                     read: (AXUIElement) -> [AnyObject]? = AX.readAttrs) -> (item: Item?, cut: Cut?) {
        let end = now() + budget
        var walked = 0, slow = false, full = false

        func visit(_ el: AXUIElement, parent: AXUIElement?, depth: Int) -> Item? {
            if slow || full || depth > maxDepth { return nil }
            if now() >= end { slow = true; return nil }
            if walked >= maxNodes { full = true; return nil }
            guard let vals = read(el), vals.count >= 14 else { return nil }
            walked += 1
            func str(_ i: Int) -> String? { (vals[i] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let role = str(0) ?? "AXUnknown"
            if role == "AXColumn" || role == "AXScrollBar" { return nil }
            let it = Item(role)
            it.subrole = str(1)
            it.element = el
            it.parent = parent
            it.rect = AX.rect(vals[6], vals[7])
            if let r = it.rect, r.width > 0, r.height > 0 { it.away = !r.intersects(visible) }
            let secure = it.subrole == "AXSecureTextField"
            if !secure {
                if let s = vals[4] as? String {
                    it.value = s
                } else if let n = vals[4] as? NSNumber, CFGetTypeID(vals[4]) != AXValueGetTypeID() {
                    it.value = AX.compact(n.doubleValue)
                    it.numeric = true
                }
            }
            it.focused = (vals[8] as? Bool) == true
            it.enabled = (vals[9] as? Bool) ?? true
            it.selected = (vals[11] as? Bool) == true
            it.ownLabel = str(2) ?? str(3) ?? str(10) ?? str(12)
            var name = str(2) ?? str(3)
            // A control with no name of its own is called what titles it (a form's "Email" beside its field).
            if name == nil, controls.contains(role), let te = AX.titleElement(vals), !CFEqual(te, el) {
                name = AX.titleText(te, read: read)
            }
            it.name = name ?? str(10) ?? str(12)
            if !secure, !leaves.contains(role) {
                for k in vals[5] as? [AXUIElement] ?? [] {
                    if let c = visit(k, parent: el, depth: depth + 1) { it.kids.append(c) }
                }
            }
            let k = kind(it)
            if it.kids.isEmpty, k != .control, k != .link, let r = it.rect, r.width == 0 || r.height == 0 { return nil }
            return it
        }

        let item = visit(root, parent: nil, depth: 0)
        return (item, slow || full ? Cut(slow: slow, walked: walked) : nil)
    }

    /// The web page in `root` (a browser window, the group round a page): its outermost web area, looked for breadth
    /// first (`maxNodes` elements at most, for `budget` s at most). One with a size first: a browser may keep other
    /// tabs' pages in its tree, with none. Nil if there's none.
    static func page(in root: AXUIElement, maxNodes: Int = 600, budget: TimeInterval = 0.5,
                     now: () -> TimeInterval = AX.uptime, read: (AXUIElement) -> [AnyObject]? = AX.readAttrs) -> AXUIElement? {
        let end = now() + budget
        var level = [root], seen = 0
        var unsized: AXUIElement?
        while !level.isEmpty, seen < maxNodes, now() < end {
            var next: [AXUIElement] = []
            for el in level where seen < maxNodes {
                seen += 1
                guard let vals = read(el), vals.count >= 8 else { continue }
                if vals[0] as? String == "AXWebArea" {
                    if let r = AX.rect(vals[6], vals[7]), r.width > 0, r.height > 0 { return el }
                    if unsized == nil { unsized = el }
                    continue  // (the pages in it are its frames)
                }
                next += vals[5] as? [AXUIElement] ?? []
            }
            level = next
        }
        return unsized
    }

    /// What a read of element `el` (one with no text of its own) reads as a page: `el` itself when it's part of a web
    /// page (a list, a table, a section of it), else the page in it (a browser window, the group round a page). Nil
    /// for anything else.
    static func root(for el: AXUIElement) -> AXUIElement? {
        AX.webArea(of: el) != nil ? el : page(in: el)
    }

    // MARK: - writing it out

    /// A piece of a paragraph as it's written, what it is, and for a control, what it's called (for the text beside
    /// it that says the same).
    struct Part {
        enum What { case text, link, control, image }
        var what: What
        var seg: AX.Segment
        var label: String? = nil
        var blank: Bool { seg.text.isEmpty }
    }

    /// What a container's children make: paragraphs (their lines, each of parts), headings, and lists or tables
    /// written out already.
    enum Block {
        case para([[Part]])
        case heading(Int, String)
        case lines([String])
    }

    /// A page written out: its Markdown, the links and controls given numbers (in the order they're written), and
    /// how many were left without one (`number` gave none).
    struct Page {
        var text: String
        var numbered: [(id: Int, item: Item)]
        var unnumbered: Int
    }

    /// `root` (a page, or part of one) as Markdown. `number` gives a link or control its number (with the label it's
    /// written with), or nil to write it without one. `cut`: the walk stopped early, said at the end with how far it
    /// got (the last heading it read).
    static func markdown(_ root: Item?, cut: Cut? = nil, number: @escaping (Item, String?) -> Int?) -> Page {
        let w = Writer(number: number)
        var lines = root.map { w.write(w.blocks([$0], in: nil), spaced: true) } ?? []
        func add(_ note: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append(note)
        }
        if lines.isEmpty, cut == nil { lines = [emptyNote] }
        if w.unnumbered > 0 { add(unnumberedNote(w.unnumbered)) }
        if let cut { add(cutNote(cut, last: w.lastHeading)) }
        return Page(text: lines.joined(separator: "\n"), numbered: w.numbered, unnumbered: w.unnumbered)
    }

    static let emptyNote = "(nothing here shows text to accessibility: if the page is still loading, wait and read again; "
        + "else look with a screenshot)"

    static func unnumberedNote(_ n: Int) -> String {
        "… (\(n) \(n == 1 ? "link or control has" : "links and controls have") no number: name one by what it says, as a target)"
    }

    /// The note a page cut short ends with: why, how far it got, and where the rest can be had.
    static func cutNote(_ cut: Cut, last heading: String?) -> String {
        var s = "… (page cut short "
            + (cut.slow ? "after \(AX.compact(AX.walkBudget)) s (the app answered slowly), at " : "at ") + "\(cut.walked) elements"
        if let h = heading { s += "; the last heading read is \"\(AX.clip(h, 60))\"" }
        return s + ". The rest of the page isn't here: find reaches it, or scroll there and look)"
    }

    /// Writes a page out, numbering as it goes.
    final class Writer {
        let number: (Item, String?) -> Int?
        var numbered: [(id: Int, item: Item)] = []
        var unnumbered = 0
        var lastHeading: String?
        private var given = Set<Int>()
        private var blocky: [ObjectIdentifier: Bool] = [:]

        init(number: @escaping (Item, String?) -> Int?) { self.number = number }

        /// `it`'s number (written as `shown`), or nil.
        func id(_ it: Item, _ shown: String?) -> Int? {
            guard let n = number(it, shown) else {
                unnumbered += 1
                return nil
            }
            if given.insert(n).inserted { numbered.append((n, it)) }
            return n
        }

        /// The blocks `items` (one container's children, in order) make; `box` is the container's frame. What runs
        /// in a line (texts, links, controls, images, and groups within a line of text) gathers into paragraphs, cut
        /// where the page leaves a gap (`follows`); headings, lists, tables and other containers are blocks of their own.
        func blocks(_ items: [Item], in box: CGRect?) -> [Block] {
            var out: [Block] = []
            var lines: [[Part]] = [[]]
            var last: CGRect?  // the frame of the paragraph's last part with words
            func flush() {
                let kept = lines.filter { $0.contains { !$0.blank } }
                if !kept.isEmpty { out.append(.para(kept)) }
                lines = [[]]
                last = nil
            }
            func add(_ p: Part) {
                if !p.blank {
                    switch WebRead.follows(last, p.seg.rect, in: box) {
                    case .gap: flush()
                    case .line: if lines[lines.count - 1].contains(where: { !$0.blank }) { lines.append([]) }
                    case .same, .wrap: break
                    }
                    if let r = p.seg.rect, r.width > 0, r.height > 0 { last = r }
                }
                lines[lines.count - 1].append(p)
            }
            for (i, it) in items.enumerated() where WebRead.kind(it) != .marker {
                if isInline(it, before: i > 0 ? items[i - 1] : nil, after: i + 1 < items.count ? items[i + 1] : nil) {
                    inline(it).forEach(add)
                } else {
                    flush()
                    out += block(it)
                }
            }
            flush()
            return WebRead.withoutTitles(out)
        }

        /// The blocks one element that isn't part of a line makes.
        func block(_ it: Item) -> [Block] {
            switch WebRead.kind(it) {
            case .heading:
                var text = WebRead.line(flat(it))
                if text.isEmpty { text = AX.neutral(WebRead.flatText(it.name ?? "")) }
                guard !text.isEmpty else { return [] }
                let level = Int(it.value ?? "").flatMap { (1...6).contains($0) ? $0 : nil } ?? 2
                lastHeading = text
                return [.heading(level, text)]
            case .list: return list(it)
            case .table: return table(it)
            default: return blocks(it.kids, in: it.rect)
            }
        }

        /// A list: a `- ` line for each entry (`1. ` for an ordered one's, as its marker says), with what's under it
        /// (a list in it, a second paragraph) indented below.
        func list(_ it: Item) -> [Block] {
            var lines: [String] = []
            for entry in it.kids where WebRead.kind(entry) != .marker {
                var inner = write(WebRead.kind(entry) == .container ? blocks(entry.kids, in: entry.rect)
                                                                    : blocks([entry], in: it.rect), spaced: false)
                // A bullet given as text, not as a marker.
                if let f = inner.first, let r = f.range(of: "^[•◦▪▫‣·]\\s*", options: .regularExpression) {
                    inner[0].removeSubrange(r)
                    if inner[0].isEmpty { inner.removeFirst() }
                }
                guard let first = inner.first else { continue }
                let mark = entry.kids.first { WebRead.kind($0) == .marker }.flatMap { WebRead.ordinal($0.value ?? $0.name) }
                lines.append((mark ?? "-") + " " + first)
                lines += inner.dropFirst().map { "  " + $0 }
            }
            return lines.isEmpty ? [] : [.lines(lines)]
        }

        /// A table: a `| a | b |` line per row (the first taken as its header), `tableColumns` columns at most. One
        /// that lays a page out (a single column, or headings, lists or tables in its cells) is read as what's in it.
        func table(_ it: Item) -> [Block] {
            var rows: [Item] = [], other: [Item] = []
            func gather(_ kids: [Item], _ depth: Int) {
                for k in kids {
                    if k.role == "AXRow" {
                        rows.append(k)
                    } else if depth < 3, WebRead.kind(k) == .container, WebRead.holds(k, ["AXRow"]) {
                        gather(k.kids, depth + 1)  // a group of rows (a table's body)
                    } else if !WebRead.holds(k, ["AXRow", "AXCell"]) {
                        other.append(k)  // a caption
                    }
                }
            }
            gather(it.kids, 0)
            let cells = rows.map { $0.kids.filter { WebRead.kind($0) != .marker } }.filter { !$0.isEmpty }
            if cells.isEmpty || cells.allSatisfy({ $0.count == 1 }) || cells.joined().contains(where: { hasBlock($0) }) {
                return blocks(it.kids, in: it.rect)
            }
            var lines: [String] = []
            for row in cells {
                var texts = row.map { WebRead.line(flat($0)).replacingOccurrences(of: "|", with: "\\|") }
                if texts.allSatisfy(\.isEmpty) { continue }
                if texts.count > WebRead.tableColumns {
                    let more = texts.count - (WebRead.tableColumns - 1)
                    texts = Array(texts.prefix(WebRead.tableColumns - 1)) + ["… \(more) more"]
                }
                lines.append("| " + texts.joined(separator: " | ") + " |")
                if lines.count == 1 { lines.append("|" + String(repeating: " --- |", count: texts.count)) }
            }
            return blocks(other, in: it.rect) + (lines.isEmpty ? [] : [Block.lines(lines)])
        }

        /// Whether `it` goes in a line of text: a text, link, control or image does; a heading, list, table or page
        /// doesn't; a group does only when nothing in it is one of those and it shares a line of the screen with the
        /// element before or after it (a `<strong>` or `<code>` in a sentence, not a paragraph under another).
        func isInline(_ it: Item, before: Item?, after: Item?) -> Bool {
            switch WebRead.kind(it) {
            case .text, .link, .control, .image, .marker: return true
            case .heading, .list, .table, .page: return false
            case .container:
                guard !hasBlock(it) else { return false }
                func beside(_ o: Item?) -> Bool {
                    guard let o, !hasBlock(o), let a = it.rect, let b = o.rect, a.width > 0, a.height > 0, b.width > 0,
                          b.height > 0 else { return false }
                    return AX.oneLine(a, b)
                }
                return beside(before) || beside(after)
            }
        }

        /// Whether `it` is or holds a heading, list, table or page.
        func hasBlock(_ it: Item) -> Bool {
            let key = ObjectIdentifier(it)
            if let b = blocky[key] { return b }
            let b: Bool
            switch WebRead.kind(it) {
            case .heading, .list, .table, .page: b = true
            case .container: b = it.kids.contains { hasBlock($0) }
            default: b = false
            }
            blocky[key] = b
            return b
        }

        /// What `it` puts in a line of text. Page text that would read as a number of the reader's own
        /// (`[label](#n)`) is broken up (`AX.neutral`).
        func inline(_ it: Item) -> [Part] {
            switch WebRead.kind(it) {
            case .text:
                guard let s = it.value ?? it.name, !s.isEmpty else { return [] }
                var seg = WebRead.segment(s, it.rect)
                seg.text = AX.neutral(seg.text)
                return [Part(what: .text, seg: seg)]
            case .link:
                let label = WebRead.flatText(it.name ?? plain(it.kids))
                guard !label.isEmpty else { return [] }
                guard let n = id(it, label) else { return [Part(what: .text, seg: (AX.neutral(label), false, false, it.rect))] }
                return [Part(what: .link, seg: ("[\(AX.neutral(label))](#\(n))", false, false, it.rect))]
            case .control:
                let label = controlLabel(it)
                let body = WebRead.controlBody(it, label: label)
                let text = id(it, label).map { "[\(body)](#\($0))" } ?? "[\(body)]"
                return [Part(what: .control, seg: (text, false, false, it.rect), label: label)]
            case .image:
                guard let alt = WebRead.alt(it) else { return [] }
                return [Part(what: .image, seg: ("![\(AX.neutral(alt))]", false, false, it.rect))]
            case .marker:
                return []
            case .container, .heading, .list, .table, .page:
                return it.kids.flatMap { inline($0) }
            }
        }

        /// Everything in `it` as one run of parts (a heading's words, a table cell's).
        func flat(_ it: Item) -> [Part] {
            switch WebRead.kind(it) {
            case .text, .link, .control, .image, .marker: return inline(it)
            case .container, .heading, .list, .table, .page: return it.kids.flatMap { flat($0) }
            }
        }

        /// The words of the texts in `items`, numbering nothing (a link's or button's label made of what's in it); with
        /// none, what its images say.
        func plain(_ items: [Item]) -> String {
            var texts: [AX.Segment] = [], alts: [String] = []
            func add(_ it: Item) {
                switch WebRead.kind(it) {
                case .text: if let s = it.value ?? it.name { texts.append(WebRead.segment(s, it.rect)) }
                case .image: if let a = WebRead.alt(it) { alts.append(a) }
                case .marker: break
                default: it.kids.forEach(add)
                }
            }
            items.forEach(add)
            let words = WebRead.flatText(AX.joinSegments(texts))
            return words.isEmpty ? alts.joined(separator: " ") : words
        }

        /// What a control is called: its name, else (a button, checkbox, radio button or tab) the words in it.
        func controlLabel(_ it: Item) -> String? {
            if let n = it.name.map(WebRead.flatText), !n.isEmpty { return n }
            guard AX.takesChildText.contains(it.role) else { return nil }
            let words = plain(it.kids)
            return words.isEmpty ? nil : words
        }

        /// Blocks as lines: a blank line between blocks (`spaced`), or none (inside a list's entry).
        func write(_ bs: [Block], spaced: Bool) -> [String] {
            var out: [String] = []
            for b in bs {
                let ls: [String]
                switch b {
                case .para(let lines): ls = lines.flatMap { WebRead.paraLines($0) }
                case .heading(let level, let text): ls = [String(repeating: "#", count: level) + " " + text]
                case .lines(let l): ls = l
                }
                guard !ls.isEmpty else { continue }
                if spaced, !out.isEmpty { out.append("") }
                out += ls
            }
            return out
        }
    }

    /// How a paragraph's next part (frame `b`) follows the one before it (`a`), in what holds them (`box`).
    enum Follow {
        case same  // on the same line of the screen
        case wrap  // on the next, as the text runs on
        case line  // on a line of its own (a line break)
        case gap  // after a gap: another paragraph
    }

    /// `Follow` from frames: on the same line; on the next as the text runs on, when the part before filled its line
    /// (it's several lines tall, or reaches across what holds it); else on a line of its own; or after a gap of more
    /// than about half a line, or back up the page (another column). Frames not known can't tell: the same line.
    static func follows(_ a: CGRect?, _ b: CGRect?, in box: CGRect?) -> Follow {
        guard let a, let b, a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return .same }
        if AX.oneLine(a, b) { return .same }
        if b.maxY <= a.minY { return .gap }
        let line = min(a.height, b.height, 24)
        if b.minY - a.maxY > max(4, line * 0.6) { return .gap }
        if a.height >= b.height * 1.5 { return .wrap }
        if let box, box.width > 0, a.maxX >= box.maxX - box.width * 0.15 { return .wrap }
        return .line
    }

    /// `blocks` without the texts that title the control beside them (a form's "Email" before its field, a
    /// checkbox's words after it): the control's label says them already. In a paragraph, the text right before or
    /// after the control; across paragraphs, one that's only such a text, just before the control's or after it.
    static func withoutTitles(_ blocks: [Block]) -> [Block] {
        let bs = blocks.map { b -> Block in
            if case .para(let lines) = b { return .para(dropTitles(lines)) }
            return b
        }
        func words(_ b: Block) -> [Part] {
            guard case .para(let lines) = b else { return [] }
            return lines.joined().filter { !$0.blank }
        }
        var keep = [Bool](repeating: true, count: bs.count)
        for i in bs.indices {
            let ps = words(bs[i])
            guard ps.count == 1 else { continue }
            if i + 1 < bs.count, let c = words(bs[i + 1]).first, c.what == .control, let l = c.label, titles(ps[0], l) {
                keep[i] = false
            } else if i > 0, let c = words(bs[i - 1]).last, c.what == .control, let l = c.label, titles(ps[0], l) {
                keep[i] = false
            }
        }
        return bs.indices.filter { keep[$0] }.map { bs[$0] }
    }

    /// A paragraph's lines without the texts right before or after a control that its label says already.
    static func dropTitles(_ lines: [[Part]]) -> [[Part]] {
        let at = lines.indices.flatMap { l in lines[l].indices.filter { !lines[l][$0].blank }.map { [l, $0] } }
        var gone = Set<[Int]>()
        for (k, pos) in at.enumerated() {
            let p = lines[pos[0]][pos[1]]
            guard p.what == .control, let label = p.label else { continue }
            for n in [k - 1, k + 1] where at.indices.contains(n) {
                if titles(lines[at[n][0]][at[n][1]], label) { gone.insert(at[n]) }
            }
        }
        guard !gone.isEmpty else { return lines }
        return lines.indices.map { l in lines[l].indices.filter { !gone.contains([l, $0]) }.map { lines[l][$0] } }
            .filter { $0.contains { !$0.blank } }
    }

    /// Whether `p` is a short text that says nothing control label `label` doesn't (`AX.repeats`).
    static func titles(_ p: Part, _ label: String) -> Bool {
        p.what == .text && p.seg.text.count <= 80 && AX.repeats(p.seg.text, in: label)
    }

    /// A text as a part of a paragraph: its words (`clean`), and whether it had a space before or after them.
    static func segment(_ s: String, _ rect: CGRect?) -> AX.Segment {
        (clean(s), s.first?.isWhitespace ?? false, s.last?.isWhitespace ?? false, rect)
    }

    /// Text as a paragraph keeps it: its line breaks (a page's text has them only where it shows them: a poem, an
    /// address, code), other spaces run together, none at either end.
    static func clean(_ s: String) -> String {
        s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text on one line, spaces run together.
    static func flatText(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Parts as one line (a heading, a table cell).
    static func line(_ parts: [Part]) -> String {
        flatText(AX.joinSegments(parts.map(\.seg)))
    }

    /// A line of a paragraph as the lines it's written as: one per line break in its texts. One that would read as
    /// the reader's own (a heading, a note) starts with a backslash (`AX.bareLine`).
    static func paraLines(_ parts: [Part]) -> [String] {
        AX.joinSegments(parts.map(\.seg)).split(whereSeparator: \.isNewline)
            .map { flatText(String($0)) }.filter { !$0.isEmpty }.map(AX.bareLine)
    }

    /// What a control's line says, as the outline says it: `field "Email" ="ada@example.org"`, `checkbox "Agree"
    /// checked`, `password "Password"` (never its value), with `focused`, `selected` or `disabled` when so.
    static func controlBody(_ it: Item, label: String?) -> String {
        var body = roleName(it)
        if let l = label { body += " \"\(AX.clipLabel(l, 100))\"" }
        var state = ""
        if it.subrole != "AXSecureTextField", let v = it.value, !v.isEmpty, v != label {
            if let s = AX.stateWord(role: it.role, subrole: it.subrole, value: v, numeric: it.numeric) {
                if !(s == " selected" && it.selected) { state = s }
            } else {
                body += " =\"\(AX.clipLabel(v, 80))\""
            }
        }
        body += state
        if it.focused { body += " focused" }
        if it.selected { body += " selected" }
        if !it.enabled { body += " disabled" }
        return AX.neutral(body)
    }

    /// What the outline calls an element of `it`'s role ("button", "field", "password", …).
    static func roleName(_ it: Item) -> String {
        switch it.subrole {
        case "AXSecureTextField": return "password"
        case "AXSearchField": return "search"
        case "AXTabButton": return "tab"
        default: return AX.roleNames[it.role] ?? String(it.role.dropFirst(2)).lowercased()
        }
    }

    /// Alt texts that say nothing about the picture.
    static let vagueAlts: Set<String> = [
        "image", "img", "photo", "picture", "icon", "logo", "graphic", "spacer", "banner", "thumbnail", "avatar", "placeholder",
    ]

    /// What an image says, when that's something: not blank, a word or a file name ("IMG_2041.jpg").
    static func alt(_ it: Item) -> String? {
        let a = flatText(it.name ?? "")
        guard a.count >= 2, a.contains(where: \.isLetter), !vagueAlts.contains(a.lowercased()) else { return nil }
        if a.range(of: "^[\\w\\-. ]+\\.(png|jpe?g|gif|svg|webp|avif|bmp|ico)$", options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return a
    }

    /// An ordered list's marker ("1.", "b)", "iv."), as its entry's mark; nil for a bullet.
    static func ordinal(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces),
              t.range(of: "^([0-9]{1,4}|[a-zA-Z]|[ivxlcdmIVXLCDM]{1,6})[.)]$", options: .regularExpression) != nil else { return nil }
        return t
    }

    /// Whether something in `it` (a few levels down) has one of `roles`.
    static func holds(_ it: Item, _ roles: Set<String>, depth: Int = 0) -> Bool {
        depth < 4 && it.kids.contains { roles.contains($0.role) || holds($0, roles, depth: depth + 1) }
    }

    /// How a read numbers what it writes: in the window's registry `reg`, as the outline does (an element numbered
    /// before, by an outline or find, keeps its number), with its role, own label, the label it's written with, its
    /// container and whether it was out of view. At most `cap` new numbers; past that, none.
    static func numberer(_ reg: AX.Registry, cap: Int = numberCap) -> (Item, String?) -> Int? {
        var fresh = 0
        return { it, shown in
            guard let el = it.element else { return nil }
            if reg.ids[el] == nil {
                guard fresh < cap else { return nil }
                fresh += 1
            }
            return reg.number(AX.Node(element: el, frame: it.rect, role: it.role, label: it.ownLabel,
                                      name: WebRead.roleName(it), parent: it.parent, away: it.away, shown: shown))
        }
    }

    /// The text of the last page each session read whole, so reading on from where a read stopped (an offset, a
    /// search) reads the very same text: a page that changes a little by itself (a clock, an ad), or a walk cut short
    /// at a different place, would shift what each offset means. Used for `keepFor` s, and only while the session
    /// has done nothing since (no act).
    struct Kept {
        let wid: CGWindowID
        let root: AXUIElement
        let acts: Int
        let at: TimeInterval
        let text: String
        let cut: Bool
    }

    nonisolated(unsafe) static var kept: [String: Kept] = [:]
    static let keepFor: TimeInterval = 60
}

extension Handlers {
    /// `read` of a web page, or of part of one (`root`, named `it` in the reply), in window `wid`: its Markdown
    /// (`WebRead`), a page at a time from `p`'s offset (below 0, from the end), or where `p`'s query is in it, as any
    /// text read is (`readReply`). Links and controls get the numbers the window's outline gives them. `again`:
    /// reading on (an offset, a query) may use the text the session's last read of the same page made, when nothing
    /// has been done since (`WebRead.Kept`). Cut short, the reply's notes say so.
    static func readPage(_ root: AXUIElement, it: String, _ p: [String: Any], wid: CGWindowID, again: Bool) -> [String: Any] {
        let session = Session.current
        let goesOn = int(p["offset"], 0) != 0 || !((p["query"] as? String) ?? "").isEmpty
        let text: String, cut: Bool
        if again, goesOn, let k = WebRead.kept[session.id], k.wid == wid, k.acts == session.acts, CFEqual(k.root, root),
           AX.uptime() - k.at < WebRead.keepFor {
            text = k.text
            cut = k.cut
        } else {
            // What's in view: what's outside it is scrolled to before it's acted on.
            let win = Windows.info(wid)?.frame ?? .infinite
            let shown = win.intersection(AX.webArea(of: root).flatMap(AX.frame) ?? .infinite)
            let walked = WebRead.walk(root, visible: shown.isNull ? win : shown)
            text = WebRead.markdown(walked.item, cut: walked.cut, number: WebRead.numberer(AX.registry(wid))).text
            cut = walked.cut != nil
            if WebRead.kept.count >= 16 { WebRead.kept.removeAll() }
            WebRead.kept[session.id] = WebRead.Kept(wid: wid, root: root, acts: session.acts, at: AX.uptime(), text: text, cut: cut)
        }
        var out = readReply(text, it, p)
        if cut { out["notes"] = ["the page was cut short: its text stops where reading stopped, and says why at its end"] }
        return out
    }

    /// Web area `page` of window `wid`, numbered there, to read.
    static func pageNode(_ page: AXUIElement, _ wid: CGWindowID) -> (Int, AX.Node) {
        let n = AX.Node(element: page, frame: AX.frame(page), role: "AXWebArea", label: AX.label(page), name: "web")
        return (AX.registry(wid).number(n), n)
    }

    /// The web page window `w` shows (a browser's, or an app's made of web pages), numbered; nil if it shows none.
    static func windowPage(_ w: WinInfo) -> (Int, AX.Node)? {
        guard let win = AX.window(pid: w.pid, wid: w.id), let page = WebRead.page(in: win) else { return nil }
        return pageNode(page, w.id)
    }
}
