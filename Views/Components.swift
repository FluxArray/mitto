import SwiftUI
import AppKit
import ImageIO

// MARK: - UI scale environment value

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

// MARK: - Image loading

nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, NSImage>()

    /// Instant lookup so a view that appears (e.g. during a cross-fade) can show the image on its first frame.
    func cached(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func image(at url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(url) }.value
        if let decoded { cache.setObject(decoded, forKey: url as NSURL) }
        return decoded
    }

    /// Fully decodes (and caps the size) off the main thread, so scrolling never pays for decoding.
    private static func decode(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return NSImage(contentsOf: url) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2560]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Loads a local artwork file off the main thread and cross-fades it in.
/// In `.fill` mode the image never influences layout – it only paints the frame it is given.
/// (Before, an oversized banner made its parent wider than the screen, which pushed the title off-screen.)
struct ArtworkImage<Fallback: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: NSImage?

    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.url = url
        self.contentMode = contentMode
        self.fallback = fallback
        _image = State(initialValue: ImageLoader.shared.cached(url))
    }

    var body: some View {
        ZStack {
            if let image {
                if contentMode == .fill {
                    Color.clear
                        .overlay { Image(nsImage: image).resizable().scaledToFill() }
                        .clipped()
                        .transition(.opacity)
                } else {
                    Image(nsImage: image).resizable().scaledToFit().transition(.opacity)
                }
            } else {
                fallback()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImageLoader.shared.cached(url) { image = hit; return }
            let loaded = await ImageLoader.shared.image(at: url)
            withAnimation(.easeOut(duration: 0.3)) { image = loaded }
        }
    }
}

// MARK: - Backgrounds

/// Shown when a game has no banner: tinted with the logo's colour when we know it.
struct GradientBackdrop: View {
    let seed: String
    var tint: Color?

    var body: some View {
        if let tint {
            LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.18), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            let hue = Double(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.70, brightness: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Full-screen blurred, darkened copy of the selected game's art that cross-fades between games.
struct BlurredBackdrop: View {
    let game: Game?
    let blur: Double

    @State private var tint: Color?

    var body: some View {
        ZStack {
            Color.black
            ZStack {
                ArtworkImage(url: game?.heroURL ?? game?.coverURL) {
                    GradientBackdrop(seed: game?.name ?? "Launcher", tint: tint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .id(game?.id ?? "none")
            .transition(.opacity)
            .scaleEffect(1.25)                       // hides blurred edges
            .blur(radius: blur, opaque: true)

            Color.black.opacity(0.55)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            // Ambient light in the game's own colour, pooling behind the carousel.
            if let tint {
                RadialGradient(colors: [tint.opacity(0.34), tint.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.5, y: 0.92), startRadius: 0, endRadius: 760)
                    .blendMode(.screen)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
        .animation(.easeInOut(duration: 0.7), value: game?.id)
        .ignoresSafeArea()
        .task(id: game?.artKey ?? "none") {
            if let game { tint = await ArtAnalyzer.load(for: game).glow } else { tint = nil }
        }
    }
}

// MARK: - Controller hint bar

// MARK: Liquid-glass glyphs

/// Frosted disc with a bright top-left rim, a soft specular sheen and an optional colour tint.
private struct GlassDisc: ViewModifier {
    let size: CGFloat
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    if let tint { Circle().fill(tint.opacity(0.32)) }
                    // Sheen: light pooling at the top of the glass.
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                 startPoint: .top, endPoint: .center))
                        .padding(1)
                }
            }
            .overlay(
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.70), .white.opacity(0.10), .white.opacity(0.35)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

/// Face-button label: a white letter on glass tinted with the button's colour.
struct ButtonGlyph: View {
    let text: String
    let color: Color
    @Environment(\.uiScale) private var s

    var body: some View {
        Text(text)
            .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 2)
            .modifier(GlassDisc(size: 28 * s, tint: color))
    }
}

/// Plain symbol (D-pad, menu) on untinted glass, matching `ButtonGlyph`.
struct GlassIcon: View {
    let systemName: String
    @Environment(\.uiScale) private var s

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13 * s, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 2)
            .modifier(GlassDisc(size: 28 * s))
    }
}

struct HintItem<Icon: View>: View {
    let label: String
    @ViewBuilder var icon: () -> Icon
    @Environment(\.uiScale) private var s

    var body: some View {
        HStack(spacing: 10 * s) {
            icon()
            Text(label)
                .foregroundStyle(.white.opacity(0.78))
        }
    }
}

/// Bottom bar: [controller hints, when a controller is connected] … position
/// The full control reference lives in Settings › Controller.
struct HintBar: View {
    @EnvironmentObject private var controller: ControllerManager
    @EnvironmentObject private var settings: AppSettings   // re-render when the layout toggle changes
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.uiScale) private var s

    var body: some View {
        let count = library.games.count
        HStack(spacing: 38 * s) {
            if controller.isConnected {
                HintItem(label: "Choose") { GlassIcon(systemName: "dpad") }
                HintItem(label: "Play") { glyph(controller.confirmPosition) }
                HintItem(label: "Options") { glyph(.top) }
                HintItem(label: "Settings") { GlassIcon(systemName: "line.3.horizontal") }
            }

            Spacer(minLength: 0)

            if count > 0 {
                Text("\(min(library.selectedIndex + 1, count)) / \(count)")
                    .font(.system(size: 16 * s, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: 15 * s, weight: .medium))
        .padding(.horizontal, 80 * s)
        .frame(height: 64 * s)
        .animation(.easeInOut(duration: 0.25), value: controller.isConnected)
    }

    private func glyph(_ position: ButtonPosition) -> some View {
        let g = controller.style.glyph(at: position)
        return ButtonGlyph(text: g.text, color: g.color)
    }
}
