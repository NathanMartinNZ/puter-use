import AppKit
import CoreText

/// Set-of-marks: a numbered badge on each interactive element of a screenshot, the same numbers as the
/// outline's indexes, so an agent can act on "element 14" for what it sees without reading the outline.
enum Marks {
    struct Mark {
        let id: Int
        let rect: CGRect  // global points, top-left origin
    }

    static let color = CGColor(srgbRed: 0.84, green: 0.0, blue: 0.44, alpha: 1)

    /// `shot`'s image with the marks drawn on (badges at each element's top-left corner, a thin box
    /// around it). Badges that would overlap an earlier one shift right.
    static func draw(_ shot: Shot, _ marks: [Mark]) -> CGImage {
        let img = shot.image
        let W = CGFloat(img.width), H = CGFloat(img.height)
        guard !marks.isEmpty, let ctx = CGContext(
            data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let s = shot.scale
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(8, min(12, 10 * s / 0.75)), nil)
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        func flip(_ q: CGRect) -> CGRect { CGRect(x: q.minX, y: H - q.maxY, width: q.width, height: q.height) }
        var placed: [CGRect] = []
        for m in marks {
            let r = CGRect(x: (m.rect.minX - shot.rect.minX) * s, y: (m.rect.minY - shot.rect.minY) * s,
                           width: m.rect.width * s, height: m.rect.height * s)
            guard r.width >= 2, r.height >= 2, r.intersects(bounds) else { continue }
            let text = NSAttributedString(string: "\(m.id)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(text)
            let bw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 4, bh = CTFontGetSize(font) + 3
            var b = CGRect(x: min(max(0, r.minX), W - bw), y: min(max(0, r.minY), H - bh), width: bw, height: bh)
            var tries = 0
            while tries < 4, placed.contains(where: { $0.intersects(b) }) {
                b.origin.x = min(b.maxX + 1, W - bw)
                tries += 1
            }
            placed.append(b)
            ctx.setStrokeColor(color.copy(alpha: 0.55)!)
            ctx.setLineWidth(1)
            ctx.stroke(flip(r.intersection(bounds)).insetBy(dx: 0.5, dy: 0.5))
            ctx.setFillColor(color)
            ctx.fill(flip(b))
            ctx.textPosition = CGPoint(x: b.minX + 2, y: H - b.maxY + 3)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage() ?? img
    }
}
