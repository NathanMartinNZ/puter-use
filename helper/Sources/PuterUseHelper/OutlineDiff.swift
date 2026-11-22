import Foundation

/// What changed in a window's outline since the one its agent has: sent instead of the whole outline when it's
/// much shorter.
///
/// An element is told by its number: a new one is `+` and its line, one whose line changed is `~` and its line,
/// and those gone are `-` and their numbers, in ranges (`- #12–#19, #23`), or their lines when only a few went (a
/// closed toast still says what it was). A line with no number of its own (a text, a heading, a line of text with
/// links in it) is told by what it says: one that wasn't there is `+`, one that's gone `-`, and one that only
/// moved isn't news. The agent has what's gone already, so little of it is said again.
///
/// An outline cut at its caps (`AX.truncatedNote`) shows the window only down to where it stops: what the agent had
/// past that may be there still. That isn't called gone (the agent keeps it), and the changes end with the same
/// note. Outlines of the two kinds aren't compared, but for an interactive one against a full one, on what an
/// interactive outline shows: the elements that can be acted on, and the lines with no number that weren't there.
enum OutlineDiff {
    /// What tells a line from the others across looks: its element's number, or (a line with no number of its own)
    /// what it says, then " (2)", " (3)"… for the same line again (`AX.Registry.unnumbered`).
    enum Key: Hashable {
        case id(Int)
        case text(String)
    }

    /// A line of an outline, as the changes see it.
    struct Line {
        let key: Key
        let text: String  // as written, with no indent; an element's own line (`AX.Registry.lines`)
        /// An element in the line of text before it (`[label](#n)`): that line shows it.
        var inline = false
        /// An element an interactive outline shows too (a control, a sheet or dialog): what a full outline is
        /// compared on against an interactive one.
        var interactive = false

        init(_ key: Key, _ text: String, inline: Bool = false, interactive: Bool = false) {
            (self.key, self.text, self.inline, self.interactive) = (key, text, inline, interactive)
        }

        var id: Int? {
            if case .id(let n) = key { return n }
            return nil
        }
    }

    /// An outline as the changes need it, and as it's remembered once its agent has it (`Session.sentOutlines`).
    struct Outline {
        var lines: [Line]  // every line, numbered or not, in the order written
        var interactive: Bool  // only what can be acted on
        /// It was cut at its caps: the window has more past its last line, which is where it was cut.
        var truncated = false

        init(_ lines: [Line], interactive: Bool, truncated: Bool = false) {
            (self.lines, self.interactive, self.truncated) = (lines, interactive, truncated)
        }

        /// The outline `reg` wrote last (`interactive`: of what can be acted on, as it was asked for).
        init(_ reg: AX.Registry, interactive: Bool) {
            self.init(reg.keyed, interactive: interactive, truncated: reg.truncated)
        }

        var elements: Int { lines.filter { $0.id != nil }.count }
    }

    /// Changes to send: their text, whether nothing changed, and what the agent has once it has them
    /// (`baseline`: what the next changes are against).
    struct Changes {
        let text: String
        let unchanged: Bool
        let baseline: Outline
    }

    /// The most of the whole outline the changes may come to: past it, the whole outline reads better.
    static let share = 2.0 / 3.0
    /// Up to this many gone, each is said with its line; more, the elements as ranges and the rest as a count.
    static let listed = 3
    /// How much of a gone line is said again (the agent has it).
    static let goneClip = 80

    /// What changed from `old` (what the agent has) to `new`, or nil when the whole outline is better sent: the
    /// changes come to most of it (`share` of `full`, the whole outline as it would be sent), or `old` is an
    /// interactive outline and `new` a full one (most of it would be new to the agent).
    static func changes(_ old: Outline, _ new: Outline, full: String) -> Changes? {
        guard let c = compare(old, new) else { return nil }
        var out: [String]
        if c.unchanged {
            out = [c.across
                ? "outline: nothing changed in what an interactive outline shows since your last full outline (\(new.elements) elements)"
                : "outline: nothing changed since your last outline (\(new.elements) elements)"]
        } else {
            out = [(c.across ? "outline changes since your last full outline, in what this interactive one shows"
                             : "outline changes since your last outline")
                + " (+ new, ~ changed, - gone; \(c.same) elements unchanged):"]
            out += c.shown
            out += gone(c.goneElements, numbered: true)
            out += gone(c.goneTexts, numbered: false)
        }
        if new.truncated { out.append(AX.truncatedNote) }
        let text = out.joined(separator: "\n")
        if !c.unchanged, Double(text.count) > Double(full.count) * share { return nil }
        // What the agent had past where the new outline was cut stays the agent's, after the new outline's lines.
        let baseline = Outline(new.lines + c.kept, interactive: new.interactive,
                               truncated: c.kept.isEmpty ? new.truncated : old.truncated)
        return Changes(text: text, unchanged: c.unchanged, baseline: baseline)
    }

    /// Whether `new` says just what `old` did, its lines with no number included (in any order), as far as the two
    /// are compared (see `changes`). Never for outlines that aren't compared.
    static func unchanged(_ old: Outline, _ new: Outline) -> Bool {
        compare(old, new)?.unchanged ?? false
    }

    /// Element numbers as ranges, in order: [12, 13, 14, 19, 23, 24] is "#12–#14, #19, #23, #24".
    static func ranges(_ ids: [Int]) -> String {
        var parts: [String] = []
        var run: [Int] = []
        func close() {
            guard let a = run.first, let b = run.last else { return }
            parts += run.count >= 3 ? ["#\(a)–#\(b)"] : run.map { "#\($0)" }
            run = []
        }
        for id in Set(ids).sorted() {
            if let last = run.last, id != last + 1 { close() }
            run.append(id)
        }
        close()
        return parts.joined(separator: ", ")
    }

    /// The two outlines compared.
    private struct Comparison {
        let across: Bool  // an interactive outline against a full one
        var shown: [String] = []  // `+` and `~` lines, in the new outline's order
        var news = 0  // lines new or changed, said or shown in a line of text that's new
        var same = 0  // elements just as they were
        var goneElements: [Line] = []
        var goneTexts: [Line] = []
        var kept: [Line] = []  // what the agent had past where the new outline was cut: not compared, still its
        var unchanged: Bool { news == 0 && goneElements.isEmpty && goneTexts.isEmpty }
    }

    /// `old` and `new` compared, or nil when they aren't: an interactive outline the agent had, a full one now.
    private static func compare(_ old: Outline, _ new: Outline) -> Comparison? {
        if old.interactive && !new.interactive { return nil }
        let across = !old.interactive && new.interactive
        var c = Comparison(across: across)
        // What of the agent's the new outline would show, to be called gone when it doesn't: everything, or (an
        // interactive outline against a full one) the elements an interactive outline shows. Texts it never
        // shows, so a text gone from a full outline can't be told from one it leaves out.
        func compared(_ l: Line) -> Bool { !across || (l.id != nil && l.interactive) }
        var before: [Key: String] = [:]
        for l in old.lines where before[l.key] == nil { before[l.key] = l.text }
        let now = Set(new.lines.map(\.key))
        var lineNew = false  // the line of text just said as new: it shows its elements
        for l in new.lines {
            let was = before[l.key]
            let differs = was != l.text
            if !l.inline { lineNew = differs && l.id == nil }
            guard differs else {
                if l.id != nil { c.same += 1 }
                continue
            }
            c.news += 1
            if l.inline && lineNew { continue }
            c.shown.append((was == nil ? "+ " : "~ ") + l.text)
        }
        // Cut at its caps, the new outline shows the window down to where it stops: what the agent had past the
        // last of its lines still there may be past that too.
        let end = new.truncated ? (old.lines.lastIndex { now.contains($0.key) } ?? -1) : old.lines.count - 1
        for (i, l) in old.lines.enumerated() where !now.contains(l.key) && compared(l) {
            if i > end {
                c.kept.append(l)
            } else if l.id != nil {
                c.goneElements.append(l)
            } else {
                c.goneTexts.append(l)
            }
        }
        return c
    }

    /// The `-` lines for what's gone (`numbered`: elements; else lines with no number), in the order they were.
    private static func gone(_ lines: [Line], numbered: Bool) -> [String] {
        if lines.isEmpty { return [] }
        if lines.count <= listed { return lines.map { "- " + AX.clip($0.text, goneClip) } }
        if numbered { return ["- " + ranges(lines.compactMap(\.id))] }
        let first = AX.clip(lines[0].text, 40), last = AX.clip(lines[lines.count - 1].text, 40)
        return ["- \(lines.count) lines with no number, \"\(first)\" to \"\(last)\""]
    }
}
