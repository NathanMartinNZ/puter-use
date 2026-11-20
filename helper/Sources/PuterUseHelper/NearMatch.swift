import ApplicationServices

/// What a target that matches nothing may have meant: labels in its window (and what's open over it) that are
/// the same but for spaces and punctuation ("Log in" for "Login"), contain it but for those, or share words with
/// it. A miss lists the nearest few, numbered; none is ever acted on.
extension AX {
    final class Near {
        /// How near a label is: lower is nearer.
        struct Rank: Comparable {
            let tier: Int  // 0: the same but for spaces and punctuation; 1: contains it but for those; 2: shares words
            let shared: Int  // words in common (more is nearer)
            let extra: Int  // what else the label says (less is nearer)
            static func < (a: Rank, b: Rank) -> Bool { (a.tier, -a.shared, a.extra) < (b.tier, -b.shared, b.extra) }
        }

        let squashed: String
        let words: Set<String>
        /// Elements seen near it, in reading order.
        private(set) var seen: [(rank: Rank, match: Match)] = []

        init(_ text: String) {
            let p = Near.parts(text)
            (squashed, words) = (p.squashed, Set(p.words))
        }

        /// Words that say nothing about which element is meant: little ones, and kinds of element.
        static let little: Set<String> = [
            "a", "an", "the", "to", "of", "in", "on", "at", "for", "and", "or", "with", "by", "from", "is", "it", "as",
            "my", "your", "this", "that", "button", "field", "link", "checkbox", "tab", "icon",
        ]

        /// `s` in lower case, letters and digits only ("Log in…" is "login"), and its words: split at spaces,
        /// punctuation and camel case ("OpenSheet" is open, sheet), without single letters and `little` ones.
        static func parts(_ s: String) -> (squashed: String, words: [String]) {
            var squashed = "", word = "", words: [String] = []
            var lastLower = false
            func end() {
                if word.count > 1 || word.first?.isNumber == true, !little.contains(word) { words.append(word) }
                word = ""
            }
            for c in s {
                guard c.isLetter || c.isNumber else { end(); lastLower = false; continue }
                if c.isUppercase, lastLower { end() }
                lastLower = c.isLowercase
                let l = c.lowercased()
                squashed += l
                word += l
            }
            end()
            return (squashed, words)
        }

        /// How near `label` is, or nil if it isn't. Long text (a paragraph, a document) never is.
        func rank(_ label: String) -> Rank? {
            guard !squashed.isEmpty, label.utf16.count <= 120 else { return nil }
            let (sq, ws) = Near.parts(label)
            guard !sq.isEmpty else { return nil }
            if sq == squashed { return Rank(tier: 0, shared: 0, extra: 0) }
            if squashed.count >= 3, sq.contains(squashed) { return Rank(tier: 1, shared: 0, extra: sq.count - squashed.count) }
            let mine = Set(ws)
            let shared = words.filter { w in mine.contains { Near.alike(w, $0) } }
            // A word in common, and it's a good part of both: "save button" is near "Save", "Submit order" isn't
            // near "Your order will ship in three to five days". Numbers name things: "Row 99" isn't near "Row 9".
            guard !shared.isEmpty, shared.count * 3 >= max(words.count, mine.count) else { return nil }
            if words.contains(where: Near.number), mine.contains(where: Near.number), !shared.contains(where: Near.number) { return nil }
            return Rank(tier: 2, shared: shared.count, extra: mine.filter { m in !words.contains { Near.alike($0, m) } }.count)
        }

        static func number(_ w: String) -> Bool { w.allSatisfy(\.isNumber) }

        /// The same word, or one with an ending added ("box", "boxes"; "save", "saved"). Numbers only when equal.
        static func alike(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            let (s, l) = a.count < b.count ? (a, b) : (b, a)
            guard s.count >= 3, l.hasPrefix(s), !number(s) else { return false }
            return ["s", "es", "d", "ed"].contains(String(l.dropFirst(s.count)))
        }

        /// An element of the walk that doesn't show the target's text: kept if one of its texts is near it.
        func consider(_ el: AXUIElement, role: String, texts: [String], frame: CGRect?, offScreen: Bool) {
            var best: (Rank, String)?
            for t in texts where !t.isEmpty {
                if let r = rank(t), best.map({ r < $0.0 }) ?? true { best = (r, t) }
            }
            guard let (r, label) = best else { return }
            seen.append((r, Match(element: el, role: role, label: label, frame: frame, exact: false, offScreen: offScreen)))
        }

        /// The nearest `n` that `ok` lets through (`ok` is asked only as far as needed), best first. When some are
        /// the same but for spaces and punctuation, only those. Controls before bare labels, then reading order;
        /// a bare label that repeats one already listed is left out.
        static func best(_ seen: [(rank: Rank, match: Match)], _ n: Int, ok: (Match) -> Bool = { _ in true }) -> [Match] {
            let order = seen.indices.sorted { i, j in
                let (a, b) = (seen[i], seen[j])
                if a.rank != b.rank { return a.rank < b.rank }
                let (ta, tb) = (a.match.role == "text", b.match.role == "text")
                return ta != tb ? tb : i < j
            }
            var out: [(Rank, Match)] = []
            for i in order where out.count < n {
                let (r, m) = seen[i]
                if let first = out.first, first.0.tier == 0, r.tier != 0 { break }
                if m.role == "text", out.contains(where: { parts($0.1.label).squashed == parts(m.label).squashed }) { continue }
                if ok(m) { out.append((r, m)) }
            }
            return out.map(\.1)
        }

        func best(_ n: Int, ok: (Match) -> Bool = { _ in true }) -> [Match] { Near.best(seen, n, ok: ok) }
    }
}

extension Handlers {
    /// The 3 nearest elements `near` saw, numbered in `w`'s registry, leaving out any behind a sheet or dialog.
    static func nearest(_ near: AX.Near, _ w: WinInfo) -> [(Int, AX.Match)] {
        let best = near.best(3) { AX.blockedBy($0.element) == nil }
        Trace.log(["k": "near", "seen": near.seen.count, "listed": best.count])
        return best.map { (number($0, w.id), $0) }
    }

    /// What a target's miss adds: "; similar (…): [12] button "Open Sheet"", or "" with nothing near.
    static func nearHint(_ near: AX.Near, _ w: WinInfo) -> String {
        let list = nearest(near, w).map { id, m in "[\(id)] \(m.role) \"\(AX.clip(m.label, 50))\"\(m.offScreen ? " (off screen)" : "")" }
        return list.isEmpty ? "" : "; similar (name one by its number if it's what you meant): \(list.joined(separator: "; "))"
    }
}
