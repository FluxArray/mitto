import SwiftUI
import AppKit
import ImageIO

/// Works out a glow colour from a game's artwork or app icon, and trims the transparent
/// padding off app icons so a ring can hug the visible logo.
///
/// The pixel analysis is expensive, so it runs off the main thread (`load`) and results are cached.
/// Never call the analysis from a view body – that was what made the carousel stutter.
nonisolated enum ArtAnalyzer {
    struct Result {
        var icon: NSImage?      // trimmed icon (nil for box art)
        var aspect: CGFloat     // width / height of `icon`
        var glow: Color         // saturated colour for the light
        var ring: Color         // lighter tint of the same hue for the ring itself
    }

    static let placeholder = Result(icon: nil, aspect: 1, glow: .white, ring: .white)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Result] = [:]

    private static func key(for game: Game) -> String { game.coverURL?.path ?? game.url.path }
    private static func stored(_ key: String) -> Result? { lock.lock(); defer { lock.unlock() }; return cache[key] }
    private static func store(_ r: Result, _ key: String) { lock.lock(); cache[key] = r; lock.unlock() }

    /// Instant lookup for views; nil until `load` has finished once.
    static func cached(for game: Game) -> Result? { stored(key(for: game)) }

    static func load(for game: Game) async -> Result {
        let k = key(for: game)
        if let hit = stored(k) { return hit }
        let coverURL = game.coverURL
        let appPath = game.url.path
        let r = await Task.detached(priority: .utility) { () -> Result in
            if let coverURL, let cg = thumbnail(at: coverURL) { return analyze(cg, trim: false) }
            return iconResult(forAppAt: appPath)
        }.value
        store(r, k)
        return r
    }

    // MARK: Analysis (thread-safe, no shared state)

    private static func thumbnail(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    private static func iconResult(forAppAt path: String) -> Result {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        var r = placeholder
        if let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            r = analyze(cg, trim: true)
        }
        if r.icon == nil { r.icon = icon }
        return r
    }

    private static func analyze(_ cg: CGImage, trim: Bool) -> Result {
        let side = 512
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return placeholder }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let px = base.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var minX = side, minY = side, maxX = -1, maxY = -1
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0

        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let a = Double(px[i + 3]) / 255
                guard a > 0.5 else { continue }       // ignores the soft drop shadow baked into icons
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)

                let pr = min(1, Double(px[i]) / 255 / a)
                let pg = min(1, Double(px[i + 1]) / 255 / a)
                let pb = min(1, Double(px[i + 2]) / 255 / a)
                let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
                let sat = hi == 0 ? 0 : (hi - lo) / hi
                let w = a * (0.05 + sat * sat) * (0.3 + hi)   // favour vivid, bright pixels
                r += pr * w; g += pg * w; b += pb * w; total += w
            }
        }
        guard total > 0, maxX >= minX else { return placeholder }

        let average = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &v, alpha: nil)

        var result = Result(icon: nil, aspect: 1,
                            glow: Color(hue: h, saturation: min(1, s * 1.1), brightness: max(v, 0.85)),
                            ring: Color(hue: h, saturation: s * 0.35, brightness: 1.0))

        if trim, let full = ctx.makeImage() {
            let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            if let c = full.cropping(to: crop) {
                result.icon = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
                result.aspect = CGFloat(c.width) / CGFloat(c.height)
            }
        }
        return result
    }
}

extension ArtAnalyzer.Result: @unchecked Sendable {}

extension Game {
    /// Changes when the artwork changes, so `.task(id:)` re-runs the colour analysis.
    var artKey: String { id + "|" + (metadata?.coverPath ?? "") }
}
