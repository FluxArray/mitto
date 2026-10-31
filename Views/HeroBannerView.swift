import SwiftUI

struct HeroBannerView: View {
    let game: Game?

    @State private var tint: Color?
    @EnvironmentObject private var runner: GameRunner
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.uiScale) private var s

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let game {
                ZStack(alignment: .bottomLeading) {
                    HeroArt(url: game.heroURL, seed: game.name, tint: tint)
                    info(game)
                }
                .id(game.id)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.45), value: game?.id)
        .task(id: game?.artKey ?? "none") {
            if let game { tint = await ArtAnalyzer.load(for: game).glow } else { tint = nil }
        }
    }

    // MARK: Text overlay

    private func info(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 18 * s) {
            // The logo *is* the title; only fall back to plain text when a game has no logo.
            if let logo = game.logoURL {
                ArtworkImage(url: logo, contentMode: .fit) { EmptyView() }
                    .frame(maxWidth: 480 * s, maxHeight: 150 * s, alignment: .leading)
                    .shadow(color: .black.opacity(0.55), radius: 14)
                    .modifier(Reveal(delay: 0.05))
            } else {
                Text(game.name)
                    .font(.system(size: 58 * s, weight: .heavy))   // resolves to SF Pro Display at this size
                    .tracking(-1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .modifier(Reveal(delay: 0.05))
            }

            if let summary = game.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 19 * s))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 680 * s, alignment: .leading)
                    .modifier(Reveal(delay: 0.15))
            }

            HStack(spacing: 12 * s) {
                playButton(for: game)
                HStack(spacing: 10 * s) {
                    if let version = game.version { Pill(text: "v\(version)") }
                    if let year = game.metadata?.releaseYear { Pill(text: String(year)) }
                    Pill(text: game.kind.rawValue, systemImage: game.kind.symbol)
                    if settings.showPlaytime {
                        Pill(text: runner.playtimeString(for: game.id), systemImage: "clock")
                    }
                    if library.fetchingIDs.contains(game.id) {
                        Pill(text: "Fetching art…", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .padding(.top, 4 * s)
            .modifier(Reveal(delay: 0.25))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 12, y: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 80 * s)
        .padding(.trailing, 80 * s)
        .padding(.bottom, 34 * s)
    }

    private func playButton(for game: Game) -> some View {
        let running = runner.runningGameID == game.id
        return Button { library.launchSelected() } label: {
            HStack(spacing: 9 * s) {
                Image(systemName: "play.fill")
                Text(running ? "Resume" : "Play")
            }
            .font(.system(size: 18 * s, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 28 * s)
            .padding(.vertical, 11 * s)
            .background(.white, in: Capsule())
            .shadow(color: .white.opacity(0.25), radius: 14)
        }
        .buttonStyle(.plain)
    }
}

/// Banner art with a slow zoom (Ken Burns) so the screen never feels static.
private struct HeroArt: View {
    let url: URL?
    let seed: String
    let tint: Color?

    @State private var zoomed = false

    var body: some View {
        ArtworkImage(url: url) { GradientBackdrop(seed: seed, tint: tint) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(zoomed ? 1.08 : 1.0)
            .clipped()
            // Fade the bottom edge into the blurred backdrop.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: 0.72),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            // Darken the leading edge so text stays legible on any art.
            .overlay(LinearGradient(colors: [.black.opacity(0.80), .black.opacity(0.30), .clear],
                                    startPoint: .leading, endPoint: .trailing))
            .onAppear { withAnimation(.easeOut(duration: 30)) { zoomed = true } }
    }
}

/// Staggered fade-and-rise when a new game is selected.
private struct Reveal: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear { withAnimation(.easeOut(duration: 0.5).delay(delay)) { shown = true } }
    }
}

struct Pill: View {
    let text: String
    var systemImage: String?
    @Environment(\.uiScale) private var s

    var body: some View {
        HStack(spacing: 7 * s) {
            if let systemImage { Image(systemName: systemImage) }
            Text(verbatim: text)
        }
        .font(.system(size: 14 * s, weight: .semibold))
        .padding(.horizontal, 13 * s)
        .padding(.vertical, 7 * s)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
    }
}
