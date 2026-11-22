import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A capture plus the mapping from its pixels back to global screen points.
struct Shot {
    let image: CGImage
    let rect: CGRect  // captured area in global points (top-left origin)
    var scale: CGFloat { CGFloat(image.width) / rect.width }  // output px per point
}

/// A prepared ScreenCaptureKit request that can be re-run cheaply while waiting for the UI to settle.
struct CapturePlan {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let rect: CGRect

    func run() async throws -> Shot {
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: img, rect: rect)
    }
}

/// What a window's capture plan was made for: the app's windows over it (a plan composites only the
/// windows there when it was made) and where it is (the plan's rect). When either changes, the plan is
/// out of date: a sheet, dialog or popover that opened since would be missing from its picture.
struct PlanBasis: Equatable {
    let over: WindowSet
    let frame: CGRect?

    /// nil for the screen, whose plan doesn't depend on any window.
    static func of(_ t: Target) -> PlanBasis? {
        guard case .window(let w) = t else { return nil }
        return PlanBasis(over: WindowSet.of(w), frame: Windows.info(w.id)?.frame)
    }
}

/// How big a screenshot to send. Vision models bill images by area in fixed tiles (Claude: 28px,
/// OpenAI: 32px), so size is set in output pixels per screen point, capped by a tile budget and
/// snapped to the tile grid. File format/bytes don't affect the model's token count; dimensions do.
struct Sizing {
    var scale = 0.75  // output px per point for normal captures (1 = a non-Retina screenshot)
    var zoomScale = 2.0  // px per point for small `region` zooms (2 = full Retina detail); bigger get less (`zoomFor`)
    var maxTokens = 1000  // cap on ceil(w/tile) * ceil(h/tile)
    var tile = 28
    var maxW = 8192, maxH = 8192

    /// Zooms up to this area (220x140 pt) get the full `zoomScale`; by `taperedZoomArea` (400x250 pt) the
    /// scale is down to twice the ordinary `scale` (1.5 px/pt by default).
    static let fullZoomArea = 220.0 * 140, taperedZoomArea = 400.0 * 250
    /// A bigger zoom is brought down to about this share of `maxTokens`, but to no less than `minZoomScale`.
    static let zoomShare = 0.6, minZoomScale = 1.4
    /// A side that ends this many pixels or fewer past a tile line is trimmed onto it (`trimStrays`)...
    static let maxStray = 6
    /// ...shrinking the picture by at most `maxTrim`, or `softTrim` where that leaves it under `softScale`
    /// px/pt (where 9-11 pt text starts to blur).
    static let maxTrim = 0.025, softTrim = 0.01, softScale = 0.6

    func tokens(_ w: Double, _ h: Double) -> Double {
        ceil(w / Double(tile)) * ceil(h / Double(tile))
    }

    /// Output pixels for `w` x `h` points at `s` px per point.
    func pixels(_ w: Double, _ h: Double, _ s: Double) -> (Int, Int) {
        (max(1, Int((w * s + 1e-6).rounded(.down))), max(1, Int((h * s + 1e-6).rounded(.down))))
    }

    func size(for rect: CGRect, native: CGFloat, zoom: Bool) -> (Int, Int) {
        let w = Double(rect.width), h = Double(rect.height), t = Double(tile)
        var s = min(zoom ? zoomFor(w, h) : scale, Double(native))
        s = min(s, Double(maxW) / w, Double(maxH) / h)
        if tokens(w * s, h * s) > Double(maxTokens) {
            s *= sqrt(Double(maxTokens) * t * t / (w * s * h * s))
            while tokens(w * s, h * s) > Double(maxTokens) && s > 0.05 { s *= 0.98 }
        }
        // Snap down to the tile grid so a few stray pixels don't buy a whole extra row/column of tiles.
        let W = w * s, H = h * s, set = s
        if W > t, H > t {
            let snap = min(floor(W / t) * t / W, floor(H / t) * t / H)
            if snap > 0.9 { s *= snap }
        }
        s = trimStrays(w, h, s)
        if zoom { s = zoomFloor(w, h, set: set, snapped: s) }
        return pixels(w, h, s)
    }

    /// A zoom's px per point once snapped onto the tile grid (`snapped`, from `set`): never below `minZoomScale`
    /// when it was set at that or more (the token cap didn't take it lower); there, up onto the grid when that
    /// costs no tile.
    func zoomFloor(_ w: Double, _ h: Double, set: Double, snapped: Double) -> Double {
        let low = Sizing.minZoomScale
        guard set >= low - 1e-9, snapped < low - 1e-9 else { return snapped }
        let (W, H) = pixels(w, h, low), t = tile
        // Each side up to its tile line: the nearer one's (the other stays within its tiles).
        let up = min(Double((W + t - 1) / t * t) / w, Double((H + t - 1) / t * t) / h)
        let (uw, uh) = pixels(w, h, up)
        let room = min(set, Double(maxW) / w, Double(maxH) / h)
        return up > low && up <= room && tokens(Double(uw), Double(uh)) <= tokens(Double(W), Double(H)) ? up : low
    }

    /// px per point for a `region` zoom of `w` x `h` points. A small region (up to about 220x140 pt, at
    /// most ~150 tokens) gets the full `zoomScale`. Bigger ones taper to twice the ordinary `scale` by
    /// 400x250 pt: 1.5 px/pt by default, which still draws 8 pt text 12 px tall. One that would cost
    /// over `zoomShare` of the token cap there is brought down toward that, to no less than 1.4 px/pt.
    /// Never more than `zoomScale`, and the token cap still applies on top. Tied to `scale` and the cap,
    /// a sharp capture for reading text off the screen (twice the scale, a far bigger cap) keeps its full
    /// zoom scale.
    func zoomFor(_ w: Double, _ h: Double) -> Double {
        let full = zoomScale
        let mid = min(full, max(1.5, 2 * scale)), low = min(mid, Sizing.minZoomScale)
        let side = sqrt(w * h), a = sqrt(Sizing.fullZoomArea), b = sqrt(Sizing.taperedZoomArea)
        var s = side <= a ? full : side >= b ? mid : full + (mid - full) * (side - a) / (b - a)
        let t = Double(tile), budget = Sizing.zoomShare * Double(maxTokens)
        if w * s * h * s > budget * t * t { s = max(low, t * sqrt(budget / (w * h))) }
        return s
    }

    /// `s` lowered so neither side of a `w` x `h` pt capture ends a few pixels (`maxStray`) past a tile
    /// line, which would buy a whole row or column of tiles for them. The snap above lands only one side
    /// on the grid (the other can end just past a line), and none at all when the short side is too far
    /// off its grid. One factor for both sides, as marks are drawn with a single scale (`Marks.draw`);
    /// taken only when it saves tiles, and by at most `maxTrim` (`softTrim` below `softScale`) in all.
    func trimStrays(_ w: Double, _ h: Double, _ s: Double) -> Double {
        var best = s
        while true {
            let (W, H) = pixels(w, h, best)
            var pick: (s: Double, tokens: Double)?
            for (n, side) in [(W, w), (H, h)] {
                let stray = n % tile
                guard n > tile, (1...Sizing.maxStray).contains(stray) else { continue }
                let c = Double(n - stray) / side  // this side exactly on the line below
                guard c >= s * (1 - Sizing.maxTrim), c >= Sizing.softScale || c >= s * (1 - Sizing.softTrim) else { continue }
                let (cw, ch) = pixels(w, h, c)
                let k = tokens(Double(cw), Double(ch))
                if pick.map({ k < $0.tokens || (k == $0.tokens && c > $0.s) }) ?? true { pick = (s: c, tokens: k) }
            }
            guard let p = pick, p.tokens < tokens(Double(W), Double(H)) else { return best }
            best = p.s
        }
    }
}

enum Capture {
    static func config(rect: CGRect, native: CGFloat, sizing: Sizing, zoom: Bool, source: CGRect?) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let (w, h) = sizing.size(for: rect, native: native, zoom: zoom)
        cfg.width = w
        cfg.height = h
        if let source { cfg.sourceRect = source }
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.captureResolution = .best
        cfg.colorSpaceName = CGColorSpace.sRGB
        return cfg
    }

    /// Plan a capture of one app window, composited with that app's menus/popovers/sheets,
    /// unaffected by other apps' windows covering it. `region` (global points) crops/zooms.
    static func planWindow(_ wid: CGWindowID, region: CGRect?, sizing: Sizing) async throws -> CapturePlan {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == wid }) else {
            throw HelperError("window \(wid) no longer exists")
        }
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        if win.isOnScreen, let pid = win.owningApplication?.processID,
           let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first
        {
            // ScreenCaptureKit doesn't give a window's alpha; the window server's list does.
            let alpha = Dictionary(Windows.all(onScreenOnly: true).filter { $0.pid == pid }.map { ($0.id, $0.alpha) }) { a, _ in a }
            func info(_ w: SCWindow) -> WinInfo {
                WinInfo(id: w.windowID, pid: w.owningApplication?.processID ?? -1, app: "", title: w.title ?? "",
                        frame: w.frame, layer: w.windowLayer, onScreen: w.isOnScreen, alpha: alpha[w.windowID] ?? 1)
            }
            let mine = content.windows.filter { $0.owningApplication?.processID == pid }
            let ids = Set(Capture.related(to: info(win), among: mine.map(info), display: display.frame).map(\.id))
            let taken = mine.filter { ids.contains($0.windowID) }
            var rect = win.frame
            for w in taken where w.windowLayer > win.windowLayer { rect = rect.union(w.frame) }
            rect = rect.intersection(display.frame)
            if let region { rect = rect.intersection(region) }
            guard !rect.isEmpty else { throw HelperError("region is outside the window") }
            let filter = SCContentFilter(display: display, including: taken)
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let cfg = config(rect: rect, native: CGFloat(filter.pointPixelScale), sizing: sizing, zoom: region != nil, source: local)
            return CapturePlan(filter: filter, config: cfg, rect: rect)
        }
        // Minimized or on another Space: capture the window's own backing store.
        var rect = win.frame
        if let region { rect = rect.intersection(region) }
        guard !rect.isEmpty else { throw HelperError("region is outside the window") }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let local = rect.offsetBy(dx: -win.frame.minX, dy: -win.frame.minY)
        let cfg = config(rect: rect, native: CGFloat(filter.pointPixelScale), sizing: sizing, zoom: region != nil,
                         source: region == nil ? nil : local)
        return CapturePlan(filter: filter, config: cfg, rect: rect)
    }

    /// Window layers a window's capture never takes in, though its app owns them: the Dock to the menu
    /// bar's status items (20-25), and tooltips, drag images and above (`overLayer` and up).
    static let barLayers = 20...25, overLayer = 200

    /// The windows composited into a capture of `win`: the window itself; its sheets and attached panels
    /// (the same layer, inside it); and the menus, popovers and panels over it (a higher layer) that
    /// overlap it or one already taken, so a cascade of submenus comes whole wherever it reaches. Only
    /// `win`'s app's, on screen on `display`, and big and opaque enough to see (as `WindowSet.of`
    /// counts them). The app's menu-bar items, its tooltips and its other windows that merely sit nearby
    /// are left out: each would widen the picture (and blur the window to fit the token cap) or change
    /// its size whenever it came or went.
    static func related(to win: WinInfo, among windows: [WinInfo], display: CGRect) -> [WinInfo] {
        let mine = windows.filter { $0.pid == win.pid && $0.onScreen && $0.frame.intersects(display) }
        func seen(_ w: WinInfo) -> Bool { w.alpha > 0.05 && w.frame.width >= 30 && w.frame.height >= 20 }
        var out = mine.filter { w in
            w.id == win.id || (w.layer == win.layer && seen(w) && win.frame.contains(w.frame))  // sheets / attached panels
        }
        var over = mine.filter { w in
            w.id != win.id && w.layer > win.layer && !barLayers.contains(w.layer) && w.layer < overLayer && seen(w)
        }
        var reached = [win.frame]  // what a window over it must overlap (or touch) to be taken
        while let i = over.firstIndex(where: { w in reached.contains { $0.insetBy(dx: -2, dy: -2).intersects(w.frame) } }) {
            reached.append(over[i].frame)
            out.append(over.remove(at: i))
        }
        return out
    }

    /// Plan a capture of the display containing `point` (default: main display), excluding our overlays.
    static func planScreen(region: CGRect?, sizing: Sizing) async throws -> CapturePlan {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw HelperError("no display")
        }
        // Not our overlays, nor apps the policy keeps agents out of.
        let own = content.applications.filter { $0.processID == Windows.ownPID || Policy.level($0.processID) == .deny }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        var rect = display.frame
        if let region { rect = rect.intersection(region) }
        guard !rect.isEmpty else { throw HelperError("region is outside the screen") }
        let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let cfg = config(rect: rect, native: CGFloat(filter.pointPixelScale), sizing: sizing, zoom: region != nil, source: local)
        return CapturePlan(filter: filter, config: cfg, rect: rect)
    }

    /// Encode; for JPEG, step quality down until the payload fits `maxBytes` (MCP clients cap result size).
    static func encode(_ img: CGImage, format: String, quality: Double, maxBytes: Int = 0) -> (Data, String) {
        if format == "png" { return (write(img, UTType.png, 1), "image/png") }
        let image = flatten(img) ?? img  // JPEG has no alpha: composite on white
        var q = quality
        var data = write(image, UTType.jpeg, q)
        while maxBytes > 0, data.count > maxBytes, q > 0.25 {
            q -= 0.1
            data = write(image, UTType.jpeg, q)
        }
        return (data, "image/jpeg")
    }

    static func write(_ img: CGImage, _ type: UTType, _ quality: Double) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func flatten(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(img, in: r)
        return ctx.makeImage()
    }
}

/// Small grayscale fingerprint used to detect whether the UI changed (and where).
struct Signature: Equatable {
    static let width = 240
    let w: Int
    let h: Int
    let px: [UInt8]

    init(_ img: CGImage) {
        w = min(Signature.width, img.width)
        h = max(1, Int((Double(img.height) * Double(w) / Double(img.width)).rounded()))
        var buf = [UInt8](repeating: 0, count: w * h)
        let width = w, height = h
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        px = buf
    }

    /// Bounding box of differing cells, in the coordinate space of an image `outW` x `outH`.
    func diff(_ other: Signature, outW: Int, outH: Int, tolerance: Int = 6) -> (box: CGRect, fraction: Double)? {
        guard other.w == w, other.h == h else {
            return (CGRect(x: 0, y: 0, width: outW, height: outH), 1)
        }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where abs(Int(px[row + x]) - Int(other.px[row + x])) > tolerance {
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        if count == 0 { return nil }
        let sx = Double(outW) / Double(w), sy = Double(outH) / Double(h)
        let box = CGRect(
            x: (Double(minX) * sx).rounded(.down), y: (Double(minY) * sy).rounded(.down),
            width: (Double(maxX - minX + 1) * sx).rounded(.up), height: (Double(maxY - minY + 1) * sy).rounded(.up))
        return (box, Double(count) / Double(w * h))
    }

    /// `r`, in window points, as a signature's cells: for a capture that starts at `offset` in the window
    /// (points), with `perPoint` cells per point.
    static func cells(_ r: CGRect, perPoint: CGSize, offset: CGPoint) -> CGRect {
        CGRect(x: (r.minX - offset.x) * perPoint.width, y: (r.minY - offset.y) * perPoint.height,
               width: r.width * perPoint.width, height: r.height * perPoint.height)
    }
}

/// The cells of a frame's signature that differ from an earlier one's (as `Signature.diff` counts them), and
/// which way each went, so what isn't news can be taken out before the frame counts as a change: what keeps
/// moving by itself (`Ambient`), a text cursor blinking (`CaretShape`).
struct CellDiff {
    let w: Int
    let h: Int
    /// The cells that differ (`y * w + x`, in order), and whether each got lighter.
    private(set) var cells: [Int]
    private(set) var lighter: [Bool]

    /// Nil when the two are of different sizes: a capture of another size, all of it changed.
    init?(_ now: Signature, from before: Signature, tolerance: Int = 6) {
        guard now.w == before.w, now.h == before.h else { return nil }
        (w, h) = (now.w, now.h)
        var changed: [Int] = [], up: [Bool] = []
        for i in 0..<(now.w * now.h) {
            let d = Int(now.px[i]) - Int(before.px[i])
            if abs(d) > tolerance {
                changed.append(i)
                up.append(d > 0)
            }
        }
        (cells, lighter) = (changed, up)
    }

    var isEmpty: Bool { cells.isEmpty }
    var count: Int { cells.count }

    /// The smallest rect (cells) around every cell that differs; nil when none does.
    var box: CGRect? {
        guard !cells.isEmpty else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for i in cells {
            let x = i % w, y = i / w
            (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The same without the cells whose middle lies in any of `rects` (cells).
    func clearing(_ rects: [CGRect]) -> CellDiff {
        guard !rects.isEmpty else { return self }
        var out = self
        var kept: [Int] = [], up: [Bool] = []
        for (n, i) in cells.enumerated() {
            let mid = CGPoint(x: Double(i % w) + 0.5, y: Double(i / w) + 0.5)
            if rects.contains(where: { $0.contains(mid) }) { continue }
            kept.append(i)
            up.append(lighter[n])
        }
        (out.cells, out.lighter) = (kept, up)
        return out
    }

    /// What differs as `Signature.diff` gives it: the box in an `outW` x `outH` image, and the share of all
    /// cells. Nil when nothing does.
    func change(outW: Int, outH: Int) -> (box: CGRect, fraction: Double)? {
        guard let b = box else { return nil }
        let sx = Double(outW) / Double(w), sy = Double(outH) / Double(h)
        let r = CGRect(x: (b.minX * sx).rounded(.down), y: (b.minY * sy).rounded(.down),
                       width: (b.width * sx).rounded(.up), height: (b.height * sy).rounded(.up))
        return (r, Double(cells.count) / Double(w * h))
    }
}

/// Where frames taken one after another, with nothing done in between, differ: what keeps moving by itself
/// (a spinner, a clock, a cursor blinking in a terminal), or what's still being drawn. Each pair of frames of
/// one plan is added (`add`); `Ambient` makes regions of it.
struct Motion {
    private(set) var w = 0
    private(set) var h = 0
    private(set) var moved: [Bool] = []
    /// Pairs added since it last started over.
    private(set) var pairs = 0

    /// Adds the cells that differ between two frames in a row. A pair of another size than the last (a new
    /// plan) starts it over; two frames of different sizes are no pair.
    mutating func add(_ a: Signature, _ b: Signature, tolerance: Int = 6) {
        guard a.w == b.w, a.h == b.h else { return }
        if a.w != w || a.h != h { (w, h, moved, pairs) = (a.w, a.h, [Bool](repeating: false, count: a.w * a.h), 0) }
        for i in 0..<(w * h) where abs(Int(a.px[i]) - Int(b.px[i])) > tolerance { moved[i] = true }
        pairs += 1
    }

    /// The places that moved (cells): each group of moved cells (a gap of a cell still joins them) as the rect
    /// around it, grown by a cell (what moves draws a little differently each time), but for groups bigger
    /// than `maxSide` (cells) either way.
    func regions(maxSide: CGSize) -> [CGRect] {
        var seen = [Bool](repeating: false, count: w * h)
        var out: [CGRect] = []
        for start in 0..<(w * h) where moved[start] && !seen[start] {
            seen[start] = true
            var stack = [start]
            var minX = start % w, maxX = minX, minY = start / w, maxY = minY
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
                for ny in max(0, y - 2)...min(h - 1, y + 2) {
                    for nx in max(0, x - 2)...min(w - 1, x + 2) where moved[ny * w + nx] && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true
                        stack.append(ny * w + nx)
                    }
                }
            }
            guard Double(maxX - minX + 1) <= maxSide.width, Double(maxY - minY + 1) <= maxSide.height else { continue }
            let x0 = max(0, minX - 1), y0 = max(0, minY - 1), x1 = min(w, maxX + 2), y1 = min(h, maxY + 2)
            out.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        return out
    }
}

/// Parts of a window that keep moving by themselves (a spinner, a clock, a cursor blinking in a terminal):
/// left alone, each would send a picture after every act, though nothing the agent did changed it. One is left
/// out of an act's change when it was moving already as the agent's last image was taken (`known`: from the
/// frames before that image) and still is in the act's own frames (`moving`). One that stopped (the page
/// loaded, the timer ran out) counts again, as does anything that moves for the first time, or beside them,
/// or that the act aimed at (`touched`). Only small ones (`maxSide`): a video, a log or a feed filling up
/// always counts.
enum Ambient {
    /// The most a part that keeps moving may measure either way to be left out (points).
    static let maxSide = CGSize(width: 200, height: 120)
    /// How far around a point the act clicked or moved to counts as aimed at (points).
    static let reach = 8.0

    /// `maxSide` in cells, at `perPoint` cells per point.
    static func maxCells(perPoint: CGSize) -> CGSize {
        CGSize(width: maxSide.width * perPoint.width, height: maxSide.height * perPoint.height)
    }

    /// The parts of `motion` that may be left out of a later change (cells), at `perPoint` cells per point.
    static func regions(_ motion: Motion, perPoint: CGSize) -> [CGRect] {
        motion.regions(maxSide: maxCells(perPoint: perPoint))
    }

    /// What to leave out of an act's change (cells): each `known` region still `moving`, grown to take in
    /// what moves over it now, unless that's bigger than `maxSide` (cells, plus the cell each region grew by),
    /// or the act aimed at it (`touched`). After keys sent where the focus can't be told, pass the whole frame
    /// as touched: what they typed may be by a cursor that blinks.
    static func mask(known: [CGRect], moving: [CGRect], touched: [CGRect], maxSide: CGSize) -> [CGRect] {
        known.compactMap { k -> CGRect? in
            let now = moving.filter { $0.intersects(k) }
            guard !now.isEmpty else { return nil }
            let r = now.reduce(k) { $0.union($1) }
            guard r.width <= maxSide.width + 2, r.height <= maxSide.height + 2,
                  !touched.contains(where: { $0.intersects(r) }) else { return nil }
            return r
        }
    }

    /// How long an act watches on for a part that was moving as the agent's last image was taken but didn't move
    /// between the act's own frames (s): a clock that ticks once a second seldom does in their 0.15 s.
    static let slowest = 1.1

    /// What kept moving by itself before an act's picture, to keep with it (`Meta.ambient`): what moved between its
    /// frames (`moving`), and when nothing was done to the window since the agent's last image but waiting (`idle`:
    /// nothing typed or clicked in between either), what changed since that image (`before`; `now`, the act's frame)
    /// too: nothing else could have changed it. A clock ticking once a second seldom ticks between two frames 0.15 s
    /// apart, but has since the last image. Cells, at `perPoint` cells per point.
    static func record(_ moving: [CGRect], now: Signature, before: Signature?, idle: Bool, perPoint: CGSize) -> [CGRect] {
        guard idle, let before, before.w == now.w, before.h == now.h else { return moving }
        var since = Motion()
        since.add(before, now)
        return moving + regions(since, perPoint: perPoint)
    }

    /// What to leave out of an act's change (`mask`), watching on a moment if need be. When what's left of the change
    /// with nothing more left out isn't nothing to show (`quiet`), but would be with all of what was moving as the
    /// agent's last image was taken (`known`) left out, a part of that may only move now and then: frames (`frame`;
    /// nil once there's none of the same size) are taken on after the act's own (`motion`, the last of them `last`),
    /// one after each `pause`, until what moved leaves nothing to show or `slowest` s are up. So a part that stopped
    /// (a spinner gone, a timer run out) still counts. `motion` takes what moved in the new frames. `touched` and
    /// `perPoint` as for `mask` and `regions`.
    @MainActor
    static func watch(known: [CGRect], touched: [CGRect], perPoint: CGSize, motion: inout Motion, last: Signature,
                      quiet: ([CGRect]) -> Bool, frame: () async throws -> Signature?, pause: () async throws -> Void,
                      clock: () -> Double) async throws -> [CGRect] {
        let side = maxCells(perPoint: perPoint)
        func moving() -> [CGRect] { motion.w == last.w && motion.h == last.h ? regions(motion, perPoint: perPoint) : [] }
        var left = mask(known: known, moving: moving(), touched: touched, maxSide: side)
        guard !known.isEmpty, !quiet(left), quiet(mask(known: known, moving: known + moving(), touched: touched, maxSide: side))
        else { return left }
        let start = clock()
        var prev = last
        while clock() - start < slowest {
            try await pause()
            guard let next = try await frame(), next.w == prev.w, next.h == prev.h else { break }
            motion.add(prev, next)
            prev = next
            left = mask(known: known, moving: moving(), touched: touched, maxSide: side)
            if quiet(left) { break }
        }
        return left
    }

    /// Where an act aimed, as cells: `reach` around each point it clicked, scrolled or moved to, and each
    /// frame it acted on (an element, the field it typed into), all in window points. `perPoint` and `offset`
    /// as for `Signature.cells`.
    static func touched(points: [CGPoint], frames: [CGRect], perPoint: CGSize, offset: CGPoint) -> [CGRect] {
        let around = points.map { CGRect(x: $0.x - reach, y: $0.y - reach, width: 2 * reach, height: 2 * reach) }
        return (around + frames).map { Signature.cells($0, perPoint: perPoint, offset: offset) }
    }
}

/// A text cursor blinking, told by its shape alone where accessibility doesn't say where the cursor is
/// (Firefox's web pages, an app slow to answer): what differs is one sliver no wider than a cursor
/// (`Handlers.caretWidth`, plus a cell it may straddle), a text line high, unbroken top to bottom, all of it
/// lighter or all of it darker (a cursor drawn or gone, not a character changed), and inside where the cursor
/// can be when that's known (`near`). Never once keys, typing or a click have gone to the window since the
/// agent's last image (`typed`): a sliver like that may be a character ("i", "l") typed.
enum CaretShape {
    /// How tall a text cursor is drawn (points).
    static let heights = 7.0...32.0

    /// Whether the cells that differ (`d`, with anything left out already taken out) are only a text cursor
    /// blinking. `near`: the field the cursor is in, or the line it's on (cells); nil where it can't be told,
    /// and then the sliver must be three cells tall at least. `perPoint`: cells per point.
    static func blinked(_ d: CellDiff, near place: CGRect?, perPoint: CGSize, typed: Bool) -> Bool {
        guard !typed, let box = d.box, perPoint.width > 0, perPoint.height > 0 else { return false }
        let widest = (Handlers.caretWidth * perPoint.width).rounded(.up) + 1
        guard box.width <= widest, box.height > box.width, box.height >= (place == nil ? 3 : 2) else { return false }
        let tall = box.height / perPoint.height, rounding = 2 / perPoint.height  // a part-cell at either end
        guard tall >= heights.lowerBound, tall <= heights.upperBound + rounding else { return false }
        if let place, !place.insetBy(dx: -1, dy: -1).contains(box) { return false }
        guard Set(d.lighter).count == 1 else { return false }  // drawn or gone, all of it
        return Set(d.cells.map { $0 / d.w }).count == Int(box.height)  // no gap: one line, not a dot and a stem
    }

    /// Whether an action leaves text and its cursor alone: waiting, scrolling, moving the pointer, looking,
    /// reading, the clipboard. After any other (keys, typing, a click, a menu command, a macro) a change
    /// shaped like a cursor may be a character.
    static func leavesTextAlone(_ a: [String: Any]) -> Bool {
        ["wait", "sleep", "wait_for", "waitfor", "scroll", "move", "mouse_move", "hover", "screenshot", "read", "clipboard"]
            .contains(Handlers.kind(a))
    }
}

/// A picture's pixels, to look at closely (`Trim.plan`): 8-bit RGBA, premultiplied, sRGB, rows from the top.
struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "4 bytes a pixel")
        (self.width, self.height, self.rgba) = (width, height, rgba)
    }

    init?(_ img: CGImage) {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, rgba: buf)
    }

    /// Whether the pixels at byte offsets `i` and `j` are the same colour, within `tolerance` a channel.
    func same(_ i: Int, _ j: Int, tolerance: Int) -> Bool {
        for k in 0..<4 where abs(Int(rgba[i + k]) - Int(rgba[j + k])) > tolerance { return false }
        return true
    }

    /// A see-through pixel in one of the window's rounded corners (`corner` pixels square): it matches any
    /// colour.
    func seeThrough(_ x: Int, _ y: Int, corner: Int) -> Bool {
        rgba[(y * width + x) * 4 + 3] < 255 && (x < corner || x >= width - corner) && (y < corner || y >= height - corner)
    }

    /// The first row from which column `x` is all one colour down to the bottom (`height` when its bottom
    /// pixel alone is, 0 when all of it is).
    func blankFrom(column x: Int, corner: Int, tolerance: Int = Trim.tolerance) -> Int {
        var first: Int?  // the pixel the rest must match
        var y = height - 1
        while y >= 0 {
            if !seeThrough(x, y, corner: corner) {
                let i = (y * width + x) * 4
                if let f = first {
                    if !same(i, f, tolerance: tolerance) { break }
                } else {
                    first = i
                }
            }
            y -= 1
        }
        return y + 1
    }

    /// How many rows at the bottom are blank: in each run of `columns`, all one colour (each run its own, so
    /// a scroll bar's track beside the page doesn't count as content).
    func blankRows(columns: [Range<Int>], corner: Int, tolerance: Int = Trim.tolerance) -> Int {
        var n = 0
        rows: for y in stride(from: height - 1, through: 0, by: -1) {
            for run in columns {
                var first: Int?
                for x in run where !seeThrough(x, y, corner: corner) {
                    let i = (y * width + x) * 4
                    if let f = first {
                        if !same(i, f, tolerance: tolerance) { break rows }
                    } else {
                        first = i
                    }
                }
            }
            n += 1
        }
        return n
    }
}

/// Blank margins left out of a window's picture: wide columns of one colour at its sides (a page's margins
/// either side of a centred column of text) and rows of it at the bottom (a short page or document). A scroll
/// bar at the right edge stays, beside the content: the picture is then two runs of columns side by side
/// (`columns`). Only what's blank is cut, and two tiles of it stay next to the content; what's above the
/// blank (a title bar, a toolbar, a browser's tabs) goes with the columns cut. The picture's pixels map back
/// to the capture's through `toCapture`; past its bottom the window carries on as it was, so a click there
/// still lands. The capture's signature is of all of it, not the picture.
struct Trim: Equatable {
    /// The capture's columns kept, left to right: one run, or the content and the scroll bar.
    let columns: [Range<Int>]
    /// The capture's rows kept, from the top.
    let height: Int
    /// The capture's own size (pixels).
    let fullWidth: Int
    let fullHeight: Int

    /// Levels a channel a pixel may be off a blank line's colour.
    static let tolerance = 8
    /// The least share of the width a side's blank must have to be cut, and of the height the bottom's.
    static let minSide = 0.12, minBottom = 0.2
    /// The least share of its tokens a trim must save: less isn't worth a picture laid out unlike the window.
    static let minSaving = 0.1
    /// How far down content over a blank side may reach (points) and go with it: a title bar, a toolbar, a
    /// browser's tabs and address bar. A column with content lower than that isn't blank.
    static let maxTop = 96.0
    /// The widest a scroll bar at the right edge is (points): it stays, beside the content.
    static let maxStrip = 18.0
    /// The narrowest (points): anything thinner at the edge (a border line, a corner's edge) is no scroll bar.
    static let minStrip = 4.0
    /// A window's rounded corners (points, each way from the corner): part-covered pixels there match any colour.
    /// macOS 26's corners fade out along the edges up to about 24 points from the corner.
    static let corner = 32.0
    /// How far a cut stays from something that must stay in the picture (pixels).
    static let clearance = 4

    var width: Int { columns.reduce(0) { $0 + $1.count } }
    /// Columns cut at the left, at the right (left of the scroll bar, if one stays) and rows at the bottom.
    var left: Int { columns.first?.lowerBound ?? 0 }
    var right: Int { fullWidth - left - width }
    var bottom: Int { fullHeight - height }
    /// A scroll bar at the right edge stays, beside the content.
    var split: Bool { columns.count > 1 }

    /// A point in the picture (pixels) as a point in the full capture: nil off its sides. Past its bottom it
    /// carries on as the window does.
    func toCapture(_ p: CGPoint) -> CGPoint? {
        guard p.x >= 0, p.x <= Double(width), let last = columns.last else { return nil }
        var start = 0.0
        for c in columns {
            if p.x < start + Double(c.count) { return CGPoint(x: Double(c.lowerBound) + p.x - start, y: p.y) }
            start += Double(c.count)
        }
        return CGPoint(x: Double(last.upperBound), y: p.y)  // its right edge
    }

    /// A point of the full capture as the picture shows it: nil where it's cut, or below the picture.
    func toImage(_ p: CGPoint) -> CGPoint? {
        guard p.y >= 0, p.y <= Double(height), let last = columns.last else { return nil }
        var start = 0.0
        for c in columns {
            if p.x >= Double(c.lowerBound), p.x < Double(c.upperBound) { return CGPoint(x: start + p.x - Double(c.lowerBound), y: p.y) }
            start += Double(c.count)
        }
        return p.x == Double(last.upperBound) ? CGPoint(x: Double(width), y: p.y) : nil
    }

    /// A box in the full capture (pixels) as the picture shows it: its parts in the columns kept, side by side,
    /// within the rows kept. Nil if none of it is in the picture.
    func box(_ r: CGRect) -> CGRect? {
        var out: CGRect?
        var start = 0.0
        for c in columns {
            let lo = max(r.minX, Double(c.lowerBound)), hi = min(r.maxX, Double(c.upperBound))
            if hi > lo {
                let part = CGRect(x: start + lo - Double(c.lowerBound), y: r.minY, width: hi - lo, height: r.height)
                out = out.map { $0.union(part) } ?? part
            }
            start += Double(c.count)
        }
        guard let b = out?.intersection(CGRect(x: 0, y: 0, width: width, height: height)), !b.isNull, !b.isEmpty else { return nil }
        return b
    }

    /// The picture: `img` (the full capture) with the margins left out. Nil if it isn't that capture's size.
    func crop(_ img: CGImage) -> CGImage? {
        guard img.width == fullWidth, img.height == fullHeight, let first = columns.first else { return nil }
        if columns.count == 1 { return img.cropping(to: CGRect(x: first.lowerBound, y: 0, width: first.count, height: height)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var x = 0
        for c in columns {
            guard let part = img.cropping(to: CGRect(x: c.lowerBound, y: 0, width: c.count, height: height)) else { return nil }
            ctx.draw(part, in: CGRect(x: x, y: 0, width: c.count, height: height))  // (each run fills the height: no flip)
            x += c.count
        }
        return ctx.makeImage()
    }

    /// The margins to leave out of a capture (`px`, at `perPoint` pixels per point), or nil when it has none
    /// worth it. A side is cut when it's blank at least `minSide` of the width, below what's over it (no
    /// lower than `maxTop`); the bottom when it's blank at least `minBottom` of the height; never through
    /// `protect` (pixels: marks' badges, the focused element); two tiles of blank stay next to the content,
    /// and more so each side of the picture ends on a tile (no cost); and only when it saves `minSaving` of
    /// the tokens.
    static func plan(_ px: Pixels, perPoint: Double, protect: [CGRect] = [], tile: Int = 28) -> Trim? {
        let W = px.width, H = px.height, t = max(1, tile)
        guard W >= 6 * t, H >= 6 * t, perPoint > 0 else { return nil }
        let corner = Int((Trim.corner * perPoint).rounded(.up))
        let keep = protect.filter { $0.intersects(CGRect(x: 0, y: 0, width: W, height: H)) }
        let sided = sides((0..<W).map { px.blankFrom(column: $0, corner: corner) }, perPoint: perPoint, pad: 2 * t, tile: t)
        var cutLeft = sided?.left ?? 0, cutRight = sided?.right ?? 0
        let strip = sided?.strip ?? 0
        for p in keep {
            if cutLeft > 0, p.minX < Double(cutLeft) { cutLeft = max(0, Int(p.minX.rounded(.down)) - clearance) }
            if cutRight > 0, p.maxX > Double(W - strip - cutRight), p.minX < Double(W - strip) {
                cutRight = max(0, W - strip - Int(p.maxX.rounded(.up)) - clearance)
            }
        }
        if cutLeft < t { cutLeft = 0 }
        if cutRight < t { cutRight = 0 }
        func runs() -> [Range<Int>] {
            strip > 0 && cutRight > 0 ? [cutLeft..<(W - strip - cutRight), (W - strip)..<W] : [cutLeft..<(W - cutRight)]
        }
        var cutBottom = 0
        let blank = px.blankRows(columns: runs(), corner: corner)
        if Double(blank) >= minBottom * Double(H) { cutBottom = blank - 2 * t }
        for p in keep where cutBottom > 0 && p.maxY > Double(H - cutBottom) {
            cutBottom = max(0, H - Int(p.maxY.rounded(.up)) - clearance)
        }
        if cutBottom < t { cutBottom = 0 }
        // Each side of the picture on a tile: what that leaves of the cut goes back to the picture (half each
        // side when both were cut), as it costs nothing.
        var give = min(W, (W - cutLeft - cutRight + t - 1) / t * t) - (W - cutLeft - cutRight)
        let back = min(cutLeft, cutRight > 0 ? (give + 1) / 2 : give)
        cutLeft -= back
        give -= back
        let more = min(cutRight, give)
        cutRight -= more
        cutLeft -= min(cutLeft, give - more)
        cutBottom -= min(H, (H - cutBottom + t - 1) / t * t) - (H - cutBottom)
        guard cutLeft + cutRight + cutBottom > 0 else { return nil }
        let trim = Trim(columns: runs(), height: H - cutBottom, fullWidth: W, fullHeight: H)
        func tokens(_ w: Int, _ h: Int) -> Double { ceil(Double(w) / Double(t)) * ceil(Double(h) / Double(t)) }
        guard tokens(trim.width, trim.height) <= (1 - minSaving) * tokens(W, H) else { return nil }
        return trim
    }

    /// The columns to cut at the left and right of a capture, and the scroll bar's width at its right edge
    /// (0: none stays), from where each column turns blank down to the bottom (`from`); nil when no side is
    /// blank enough. What's over the blank sides ends where it ends for most columns that are blank that high
    /// up (the title bar's or toolbar's bottom edge, across the window): a column whose content goes lower
    /// (a logo in a page's header) ends the blank side there. `pad` columns of blank stay by the content.
    static func sides(_ from: [Int], perPoint: Double, pad: Int, tile: Int) -> (left: Int, right: Int, strip: Int)? {
        let W = from.count, highest = Int((maxTop * perPoint).rounded())
        var counts: [Int: Int] = [:]
        for f in from where f <= highest { counts[f, default: 0] += 1 }
        guard let top = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key else { return nil }
        let slack = max(2, Int((2 * perPoint).rounded()))
        func blank(_ x: Int) -> Bool { from[x] <= top + slack }
        var l = 0
        while l < W, blank(l) { l += 1 }
        // A scroll bar at the right edge: its knob makes a column there not blank (its track's edges may be
        // one colour), and it stays from the first such column to the edge, the blank left of it cut. Content
        // there leaves no blank left of it: that side stays as it is.
        let widest = Int((maxStrip * perPoint).rounded(.up))
        let s = (max(l, W - widest)..<W).first { !blank($0) }.map { W - $0 } ?? 0
        // Thinner than a scroll bar (a border line, what's left of a corner's edge): it goes with a blank side cut.
        let thin = s > 0 && s < max(2, Int((minStrip * perPoint).rounded(.up))) ? s : 0
        var r = 0
        while W - 1 - s - r >= l, blank(W - 1 - s - r) { r += 1 }
        let least = Int((minSide * Double(W)).rounded(.up))
        guard W - l - r - s >= 2 * tile else { return nil }  // all blank: no content to trim around
        let left = l >= least ? max(0, l - pad) : 0, right = r >= least ? max(0, r - pad) : 0
        guard left > 0 || right > 0 else { return nil }
        if thin > 0 { return (left, right > 0 ? right + thin : 0, 0) }
        return (left, right, right > 0 ? s : 0)
    }
}

/// An act's picture of only what changed (`crop_changes`): the part of its capture round the change, with room
/// round it, in place of the whole window, when the change is a small part of it. Its pixels map back to the
/// capture's through its origin (`Meta.crop`), so what the agent reads off it lands where it shows. The agent gets
/// the whole window again every few pictures, and whenever the batch calls for it (`keyframe`).
enum ChangeCrop {
    /// The most of the picture the change may cover (its box's area) to be cropped to.
    static let maxShare = 0.25
    /// The least share of the whole picture's tokens a crop must save: less isn't worth a part for the whole.
    static let minSaving = 0.5
    /// The least room kept round the change (points; a tile at least): a field's label, the button beside it.
    static let margin = 24.0
    /// The fewest tiles a crop is wide and high, where the picture has that many: some of what's round the change.
    static let minTiles = 4
    /// One picture of a window in this many is whole, however little changed.
    static let keyframeEvery = 5
    /// How long the outline of what can be acted on in a crop may be (characters).
    static let outlineChars = 1500
    /// About how many characters of text a token is: what a crop's outline costs beside its picture.
    static let charsPerToken = 3.5

    /// Whether an act's picture is the whole window whatever changed: the agent hasn't seen this window whole
    /// (`seen`: its last picture was one sent, of this window); `crops` pictures of it in a row have been crops
    /// already; the batch moved to another window (`newWindow`); the window moved, changed size, or something
    /// opened or closed over it since that picture (`reshaped`); an action failed; the batch stopped (before
    /// coordinates, a macro's positions or for the user's OK); a press the user agreed to ran (`irreversible`);
    /// it's the outline's fallback to a picture (`outlined`); or every act asks for a picture (`always`).
    static func keyframe(seen: Bool, crops: Int, newWindow: Bool, reshaped: Bool, failed: Bool, stopped: Bool,
                         irreversible: Bool, outlined: Bool, always: Bool) -> Bool {
        !seen || crops >= keyframeEvery - 1 || newWindow || reshaped || failed || stopped || irreversible || outlined || always
    }

    /// The part of a `picture`-sized capture (pixels, at `perPoint` pixels a point) to send for a change in
    /// `box` (pixels; `fraction`: the share of the signature's cells that changed, 1 for a capture of another
    /// size), or nil to send the whole: when the change covers more than `maxShare` of it (changes far apart make
    /// one wide box), or the crop wouldn't save `minSaving` of its tokens, the outline sent with it counted
    /// (`outline`: its characters, `charsPerToken` a token; on a small window it can cost more than the crop saves).
    /// `margin` round the box (a tile at least), then each side grown to whole tiles (`tile` pixels, `minTiles` at
    /// least), which costs nothing, and kept in the picture.
    static func decide(changeBox box: CGRect, fraction: Double, picture: CGSize, perPoint: Double, tile: Int,
                       outline: Int = 0) -> CGRect? {
        let W = Double(picture.width).rounded(.down), H = Double(picture.height).rounded(.down), t = Double(max(1, tile))
        guard fraction < 1, W > 0, H > 0, perPoint > 0 else { return nil }
        let b = box.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !b.isNull, !b.isEmpty, b.width * b.height <= maxShare * W * H else { return nil }
        let room = max(margin * perPoint, t)
        func span(_ from: Double, _ to: Double, _ total: Double) -> (Double, Double) {
            let lo = max(0, (from - room).rounded(.down)), hi = min(total, (to + room).rounded(.up))
            let want = min(total, max(ceil((hi - lo) / t), Double(minTiles)) * t)
            let start = min(max(0, (lo - (want - (hi - lo)) / 2).rounded(.down)), total - want)
            return (start, start + want)
        }
        let (x0, x1) = span(b.minX, b.maxX, W), (y0, y1) = span(b.minY, b.maxY, H)
        func tokens(_ w: Double, _ h: Double) -> Double { ceil(w / t) * ceil(h / t) }
        let text = Double(max(0, outline)) / charsPerToken
        guard tokens(x1 - x0, y1 - y0) + text <= (1 - minSaving) * tokens(W, H) else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// What `crop` (pixels of `shot`'s capture) shows, in global points.
    static func points(_ crop: CGRect, of shot: Shot) -> CGRect {
        let sx = Double(shot.image.width) / max(shot.rect.width, 1), sy = Double(shot.image.height) / max(shot.rect.height, 1)
        return CGRect(x: shot.rect.minX + crop.minX / sx, y: shot.rect.minY + crop.minY / sy,
                      width: crop.width / sx, height: crop.height / sy)
    }
}

/// A picture at `detail: "low"`: fewer pixels a point than usual, for a look that only needs the gist (scanning a
/// page, checking a dialog went), but never so few that the window's text stops being readable: a line of it
/// stays `minTextPixels` high, by its text's height as accessibility gives it (`textHeight`).
enum DetailLow {
    /// The fewest pixels a line of text may be drawn in (its height): below that, words blur.
    static let minTextPixels = 10.0
    /// The sparsest picture (px per point), however big the window's text.
    static let lowest = 0.5
    /// With no text height known (no accessibility, a canvas, a browser whose tree isn't on): a scale that still
    /// keeps ordinary 11-13 pt text readable.
    static let unknown = 0.65
    /// Heights (points) that can be one line of text: less is a hairline; more, a block of lines or a display.
    static let lineHeights = 6.0...40.0
    /// The fewest texts measured for a height to go by.
    static let minSamples = 3

    /// How high a window's lines of text are (points): the median of the heights measured (the lower of the
    /// middle two), leaving out what can't be one line; nil with fewer than `minSamples` left.
    static func textHeight(_ heights: [Double]) -> Double? {
        let s = heights.filter { lineHeights.contains($0) }.sorted()
        guard s.count >= minSamples else { return nil }
        return s[(s.count - 1) / 2]
    }

    /// The same from all the window's texts and those of a web page in it: the smaller of the two, as the page's
    /// is what's read, and smaller text must stay readable too.
    static func textHeight(window: [Double], page: [Double]) -> Double? {
        [textHeight(window), textHeight(page)].compactMap { $0 }.min()
    }

    /// px per point for a low-detail picture: as few as keep a line of text `textHeight` points high
    /// `minTextPixels` tall, no fewer than `lowest`, and never more than an ordinary picture's (`normal`).
    /// `unknown` with no height measured. (The token cap may still bring a big window lower, as it always does.)
    static func scale(textHeight h: Double?, normal: Double) -> Double {
        guard let h, h > 0 else { return min(normal, unknown) }
        return min(normal, max(lowest, minTextPixels / h))
    }
}
