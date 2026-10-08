import AppKit
import Vision

/// Reading text off the pixels, for what accessibility doesn't expose: canvas and game apps, images,
/// PDFs drawn as pictures, some Electron and Java apps. Slower than accessibility (0.1–0.6 s a window)
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
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [Hit] = []
        for (o, c) in try await recognize(shot, fast: fast) {
            let s = c.string
            guard let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let box = (try? c.boundingBox(for: r))?.boundingBox ?? o.boundingBox
            hits.append(Hit(line: s, rect: global(box, shot),
                            exact: s.lowercased().trimmingCharacters(in: .whitespaces) == q))
        }
        return hits.sorted { $0.rect.minY < $1.rect.minY }
    }

    /// The text as lines of reading order, like `AX.text` gives (words on one visual line joined).
    static func text(_ lines: [Line]) -> String {
        var rows: [[Line]] = []
        for l in lines {
            if let first = rows.last?.first, abs(first.rect.midY - l.rect.midY) < max(3, min(first.rect.height, l.rect.height) / 2) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: "  ") }.joined(separator: "\n")
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
