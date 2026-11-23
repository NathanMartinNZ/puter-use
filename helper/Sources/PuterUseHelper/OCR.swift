import AppKit
import Vision

/// Reading text off the pixels, for what accessibility doesn't expose: canvas and game apps, images,
/// PDFs drawn as pictures, some Electron and Java apps. Slower than accessibility (0.1-0.6 s a window)
/// and approximate, so it's only the fallback.
enum OCR {
    struct Line {
        let text: String
        let rect: CGRect  // global points, top-left origin
        let confidence: Float
    }

    struct Hit {
        let line: String  // the whole line the text was found in
        let rect: CGRect  // just the matched words, global points
        let exact: Bool  // the whole line is the query
    }

    /// Lines of text in `shot`, top to bottom.
    static func read(_ shot: Shot, fast: Bool = false) async throws -> [Line] {
        try await recognize(shot, fast: fast).map { o, c in Line(text: c.string, rect: global(o.boundingBox, shot), confidence: c.confidence) }
            .sorted { abs($0.rect.midY - $1.rect.midY) < min($0.rect.height, $1.rect.height) / 2 ? $0.rect.minX < $1.rect.minX : $0.rect.midY < $1.rect.midY }
    }

    /// Where `query` appears in `shot` (case-insensitive), each with the box of just the matched words.
    static func find(_ query: String, in shot: Shot, fast: Bool = false) async throws -> [Hit] {
        let q = AX.fold1(query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        var hits: [Hit] = []
        for (o, c) in try await recognize(shot, fast: fast) {
            let s = c.string
            guard let r = range(of: q, in: s) else { continue }
            let box = (try? c.boundingBox(for: r))?.boundingBox ?? o.boundingBox
            hits.append(Hit(line: s, rect: global(box, shot),
                            exact: AX.fold1(s.lowercased()).trimmingCharacters(in: .whitespaces) == q))
        }
        return hits.sorted { $0.rect.minY < $1.rect.minY }
    }

    /// Where `q` (folded, `AX.fold1`) is in line `s`, case, accents and typographic marks aside ("we've" finds
    /// "We’ve"), as a range of `s` itself: Vision boxes the matched words by it.
    static func range(of q: String, in s: String) -> Range<String.Index>? {
        let folded = AX.fold1(s)
        guard let r = folded.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        return AX.unfolded(r, of: folded, in: s)
    }

    /// The text as lines of reading order, like `AX.text` gives (words on one visual line joined), at most
    /// `maxChars` characters. Doubtful marks are left out (`kept`), unless that would leave nothing.
    static func text(_ lines: [Line], maxChars: Int = AX.textCap) -> String {
        let sure = lines.filter(kept)
        var rows: [[Line]] = []
        for l in sure.isEmpty ? lines : sure {
            if let first = rows.last?.first, abs(first.rect.midY - l.rect.midY) < max(3, min(first.rect.height, l.rect.height) / 2) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        let all = rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: "  ") }.joined(separator: "\n")
        return AX.capped(all, maxChars, note: capNote)
    }

    /// Text read off the screen has no element to `read` whole: a smaller area is the way to the rest.
    static let capNote = "… (truncated; use a smaller region for the rest)"

    /// Below this, Vision doubts a line. Its accurate reading (the one used for an area's text) scores
    /// lines 1 or 0.5, and the doubtful ones 0.3; the fast one anywhere between.
    static let doubtful: Float = 0.35

    /// Whether a line is worth giving: any Vision is sure of, and a doubtful one with words in it (at least
    /// two letters or digits, making up at least half of it). What goes is a doubtful short mark, mostly
    /// punctuation: an icon, a divider or a bullet misread as "| O ." or "—". Never words on confidence
    /// alone: small or low-contrast text can score low and still be right.
    static func kept(_ l: Line) -> Bool {
        if l.confidence >= doubtful { return true }
        let marks = l.text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let words = marks.filter { CharacterSet.alphanumerics.contains($0) }.count
        return words >= 2 && words * 2 >= marks.count
    }

    private static func recognize(_ shot: Shot, fast: Bool) async throws -> [(VNRecognizedTextObservation, VNRecognizedText)] {
        let image = shot.image
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = fast ? .fast : .accurate
                req.usesLanguageCorrection = false  // UI text: names, numbers, codes
                req.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
                    let out = (req.results ?? []).compactMap { o in o.topCandidates(1).first.map { (o, $0) } }
                    cont.resume(returning: out)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Vision's normalized, bottom-left-origin box → global points.
    private static func global(_ b: CGRect, _ shot: Shot) -> CGRect {
        CGRect(x: shot.rect.minX + b.minX * shot.rect.width, y: shot.rect.minY + (1 - b.maxY) * shot.rect.height,
               width: b.width * shot.rect.width, height: b.height * shot.rect.height)
    }
}
