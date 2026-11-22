import AppKit
import CoreText

/// Set-of-marks: a numbered badge on each interactive element of a screenshot, the same numbers as the
/// outline's indexes, so an agent can act on "element 14" for what it sees without reading the outline.
enum Marks {
    struct Mark {
        let id: Int
        let rect: CGRect  // global points, top-left origin
        var role = ""  // its accessibility role; with none given it's always drawn
    }

    static let color = CGColor(srgbRed: 0.84, green: 0.0, blue: 0.44, alpha: 1)

    /// Table and list parts (marked so a row or cell itself can be acted on) whose badge is left off when
    /// a mark inside fills them (`shown`). A row outranks a cell: a row a cell fills defers to the cell,
    /// a cell a control fills defers to the control.
    static let containers = ["AXRow": 2, "AXOutlineRow": 2, "AXCell": 1]
    /// How much of a row or cell the mark inside must cover to stand in for it.
    static let fills: CGFloat = 0.75

    /// The marks that get a badge: all but a row or cell nearly covered by the mark of something in it (a
    /// cell, or a control). Their badges would pile up at the same corner for the same spot. The numbers
    /// left off still work for `element`; nothing is renumbered.
    static func shown(_ marks: [Mark]) -> [Mark] {
        func rank(_ m: Mark) -> Int { containers[m.role] ?? 0 }
        func area(_ r: CGRect) -> CGFloat { r.width * r.height }
        return marks.filter { box in
            let r = rank(box)
            guard r > 0 else { return true }
            let around = box.rect.insetBy(dx: -2, dy: -2)
            return !marks.contains { m in rank(m) < r && around.contains(m.rect) && area(m.rect) >= area(box.rect) * fills }
        }
    }

    /// A mark as `draw` puts it on the picture, in its pixels with the origin at the top left: the element's
    /// box, its numbered badge, and the badge's text.
    struct Placed {
        let mark: Mark
        let box: CGRect
        let badge: CGRect
        let line: CTLine
    }

    /// The badges' font for a picture of `scale` px per point.
    static func font(scale: CGFloat) -> CTFont {
        CTFontCreateWithName("Menlo-Bold" as CFString, max(8, min(12, 10 * scale / 0.75)), nil)
    }

    /// Where `draw` puts the marks that get a badge (`shown`, of those big enough to see and on the picture):
    /// each badge at its element's top-left corner, one that would overlap an earlier one shifted right. Also
    /// what a picture trimmed of its blank margins must keep (`Trim.plan`).
    static func layout(_ shot: Shot, _ marks: [Mark]) -> [Placed] {
        let W = CGFloat(shot.image.width), H = CGFloat(shot.image.height), s = shot.scale
        let font = Marks.font(scale: s)
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        func pixels(_ q: CGRect) -> CGRect {
            CGRect(x: (q.minX - shot.rect.minX) * s, y: (q.minY - shot.rect.minY) * s, width: q.width * s, height: q.height * s)
        }
        // Only marks that show can stand in for a row or cell: one too small or off the picture can't.
        let visible = marks.filter { m in
            let r = pixels(m.rect)
            return r.width >= 2 && r.height >= 2 && r.intersects(bounds)
        }
        var placed: [CGRect] = []
        return shown(visible).map { m -> Placed in
            let r = pixels(m.rect)
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
            return Placed(mark: m, box: r, badge: b, line: line)
        }
    }

    /// `shot`'s image with the marks drawn on (badges at each element's top-left corner, a thin box
    /// around it), but for rows and cells a mark inside stands in for (`shown`). Badges that would overlap
    /// an earlier one shift right (`layout`).
    static func draw(_ shot: Shot, _ marks: [Mark]) -> CGImage {
        let img = shot.image
        let W = CGFloat(img.width), H = CGFloat(img.height)
        guard !marks.isEmpty, let ctx = CGContext(
            data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        func flip(_ q: CGRect) -> CGRect { CGRect(x: q.minX, y: H - q.maxY, width: q.width, height: q.height) }
        for p in layout(shot, marks) {
            ctx.setStrokeColor(color.copy(alpha: 0.55)!)
            ctx.setLineWidth(1)
            ctx.stroke(flip(p.box.intersection(bounds)).insetBy(dx: 0.5, dy: 0.5))
            ctx.setFillColor(color)
            ctx.fill(flip(p.badge))
            ctx.textPosition = CGPoint(x: p.badge.minX + 2, y: H - p.badge.maxY + 3)
            CTLineDraw(p.line, ctx)
        }
        return ctx.makeImage() ?? img
    }
}
