import SwiftUI
import AppKit

/// Carousel driven by the selected index instead of a ScrollView + scrollTo.
/// Every card sits at `(index - selected) * pitch` from the centre, so moving the selection is just
/// one spring animation of plain offsets – no lazy-layout estimation, no scroll jumps, and only the
/// cards near the centre are built at all.
struct GameCarouselView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.uiScale) private var s

    private let spring = Animation.spring(response: 0.45, dampingFraction: 0.85)

    var body: some View {
        GeometryReader { geo in
            let cardH = min(geo.size.height * 0.72 * s, geo.size.height * 0.84)
            let cardW = cardH / 1.5
            let pitch = cardW + 30 * s

            if library.games.isEmpty {
                emptyState
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let count = library.games.count
                let selected = min(max(library.selectedIndex, 0), count - 1)
                let reach = Int(geo.size.width / pitch / 2) + 3
                let window = Array(library.games.enumerated())[max(0, selected - reach)...min(count - 1, selected + reach)]

                ZStack {
                    ForEach(window, id: \.element.id) { index, game in
                        GameCoverCard(game: game, width: cardW, distance: abs(index - selected))
                            .offset(x: CGFloat(index - selected) * pitch)
                            .zIndex(index == selected ? 1 : 0)
                            .onTapGesture {
                                if index == selected { library.launchSelected() }
                                else { library.select(index) }
                            }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(spring, value: selected)
                // Soft fade at the screen edges (extra vertical room so glows aren't cut off).
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.07),
                                           .init(color: .black, location: 0.93),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .padding(.vertical, -300)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12 * s) {
            if library.isScanning {
                ProgressView().controlSize(.large)
                Text("Scanning for games…")
            } else {
                Image(systemName: "gamecontroller").font(.system(size: 44 * s))
                Text("No games found").font(.system(size: 24 * s, weight: .semibold))
                Text("Open Settings (≡ or S) to add folders or pick a game manually.")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// Box art when we have it; otherwise just the app's logo – no card, no title.
/// The selected game gets a ring light and glow in the art's own colour.
struct GameCoverCard: View {
    let game: Game
    let width: CGFloat
    let distance: Int                       // 0 = selected; grows with distance from the centre
    private var isSelected: Bool { distance == 0 }

    /// Colour analysis happens off the main thread; until it lands we show a neutral white ring.
    @State private var analyzed: ArtAnalyzer.Result?

    var body: some View {
        let art = analyzed ?? ArtAnalyzer.cached(for: game) ?? ArtAnalyzer.placeholder
        ZStack {
            if game.coverURL != nil { boxArt(art) } else { iconTile(art) }
        }
        .frame(width: width, height: width * 1.5)       // same slot size for every game
        .scaleEffect(isSelected ? 1.14 : max(0.88, 1 - 0.03 * CGFloat(distance)))
        .offset(y: isSelected ? -10 : 0)
        .opacity(isSelected ? 1 : max(0.28, 0.78 - 0.12 * Double(distance)))
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: isSelected)
        .task(id: game.artKey) { analyzed = await ArtAnalyzer.load(for: game) }
    }

    private func boxArt(_ art: ArtAnalyzer.Result) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.09, style: .continuous)
        return ArtworkImage(url: game.coverURL) { Color.white.opacity(0.08) }
            .frame(width: width, height: width * 1.5)
            .clipShape(shape)
            .overlay(shape.strokeBorder(art.ring, lineWidth: isSelected ? 5 : 0))
            .modifier(Glow(color: art.glow, active: isSelected))
    }

    private func iconTile(_ art: ArtAnalyzer.Result) -> some View {
        let aspect = min(max(art.aspect, 0.6), 1.6)
        let w = width * 0.86                      // leaves room for the ring inside the slot
        let h = w / aspect
        let radius = min(w, h) * 0.2237           // macOS icon corner curve
        let gap: CGFloat = 8
        let line: CGFloat = 4

        return Image(nsImage: art.icon ?? NSWorkspace.shared.icon(forFile: game.url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: w, height: h)
            .overlay {
                RoundedRectangle(cornerRadius: radius + gap + line, style: .continuous)
                    .strokeBorder(art.ring, lineWidth: isSelected ? line : 0)
                    .padding(-(gap + line))
            }
            .modifier(Glow(color: art.glow, active: isSelected))
    }
}

private struct Glow: ViewModifier {
    let color: Color
    let active: Bool

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(active ? 0.85 : 0), radius: active ? 18 : 0)
            .shadow(color: color.opacity(active ? 0.45 : 0), radius: active ? 48 : 0)
            .shadow(color: .black.opacity(active ? 0.45 : 0.3), radius: active ? 24 : 8, y: active ? 14 : 4)
    }
}
