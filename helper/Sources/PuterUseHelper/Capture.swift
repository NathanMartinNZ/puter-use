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

/// How big a screenshot to send. Vision models bill images by area in fixed tiles (Claude: 28px,
/// OpenAI: 32px), so size is set in output pixels per screen point, capped by a tile budget and
/// snapped to the tile grid. File format/bytes don't affect the model's token count; dimensions do.
struct Sizing {
    var scale = 0.75  // output px per point for normal captures (1 = a non-Retina screenshot)
    var zoomScale = 2.0  // px per point for `region` zooms (2 = full Retina detail)
    var maxTokens = 1000  // cap on ceil(w/tile) * ceil(h/tile)
    var tile = 28
    var maxW = 8192, maxH = 8192

    func tokens(_ w: Double, _ h: Double) -> Double {
        ceil(w / Double(tile)) * ceil(h / Double(tile))
    }

    func size(for rect: CGRect, native: CGFloat, zoom: Bool) -> (Int, Int) {
        let w = Double(rect.width), h = Double(rect.height), t = Double(tile)
        var s = min(zoom ? zoomScale : scale, Double(native))
        s = min(s, Double(maxW) / w, Double(maxH) / h)
        if tokens(w * s, h * s) > Double(maxTokens) {
            s *= sqrt(Double(maxTokens) * t * t / (w * s * h * s))
            while tokens(w * s, h * s) > Double(maxTokens) && s > 0.05 { s *= 0.98 }
        }
        // Snap down to the tile grid so a few stray pixels don't buy a whole extra row/column of tiles.
        let W = w * s, H = h * s
        if W > t, H > t {
            let snap = min(floor(W / t) * t / W, floor(H / t) * t / H)
            if snap > 0.9 { s *= snap }
        }
        return (max(1, Int((w * s + 1e-6).rounded(.down))), max(1, Int((h * s + 1e-6).rounded(.down))))
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
            var rect = win.frame
            let related = content.windows.filter { w in
                guard w.owningApplication?.processID == pid, w.isOnScreen, w.frame.intersects(display.frame) else { return false }
                if w.windowID == wid { return true }
                if w.windowLayer > win.windowLayer { return w.frame.intersects(win.frame.insetBy(dx: -400, dy: -400)) }
                return w.windowLayer == win.windowLayer && win.frame.contains(w.frame)  // sheets / attached panels
            }
            for w in related where w.windowLayer > win.windowLayer { rect = rect.union(w.frame) }
            rect = rect.intersection(display.frame)
            if let region { rect = rect.intersection(region) }
            guard !rect.isEmpty else { throw HelperError("region is outside the window") }
            let filter = SCContentFilter(display: display, including: related)
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
}
