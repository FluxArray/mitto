import SwiftUI
import AppKit

private enum GameOption: CaseIterable {
    case refreshArt, hide, reveal

    var title: String {
        switch self {
        case .refreshArt: "Refresh Artwork"
        case .hide: "Hide from Library"
        case .reveal: "Show in Finder"
        }
    }

    var symbol: String {
        switch self {
        case .refreshArt: "arrow.clockwise"
        case .hide: "eye.slash"
        case .reveal: "folder"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: ControllerManager
    @EnvironmentObject private var runner: GameRunner

    @State private var showSettings = false
    @State private var settingsTab: SettingsTab = .library
    @State private var topBarFocused = false
    @State private var showExitPrompt = false
    @State private var showOptions = false
    @State private var optionIndex = 0
    @FocusState private var hasFocus: Bool

    var body: some View {
        ZStack {
            BlurredBackdrop(game: library.selectedGame, blur: settings.backgroundBlur)

            GeometryReader { geo in
                VStack(spacing: 0) {
                    HeroBannerView(game: library.selectedGame)
                        .frame(height: geo.size.height * 0.56)
                    GameCarouselView()
                        .frame(maxHeight: .infinity)
                    HintBar()
                }
            }

            // Keeps the clock and Settings button readable over bright banner art.
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                TopBar(isFocused: topBarFocused) {
                    topBarFocused = false
                    showSettings = true
                }
                Spacer()
            }

            if showOptions, let game = library.selectedGame {
                OptionsMenu(title: game.name, selected: optionIndex,
                            onPick: { run($0); showOptions = false },
                            onClose: { showOptions = false })
                    .transition(.opacity)
            }

            if showExitPrompt {
                ExitPrompt(onQuit: { NSApp.terminate(nil) },
                           onCancel: { showExitPrompt = false })
                    .transition(.opacity)
            }
        }
        .environment(\.uiScale, CGFloat(settings.uiScale))
        .animation(.easeInOut(duration: 0.2), value: showExitPrompt)
        .animation(.easeInOut(duration: 0.2), value: showOptions)
        // Keyboard fallback so the launcher is usable without a controller.
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
        // Controller input.
        .onReceive(controller.actions) { handle($0) }
        .sheet(isPresented: $showSettings, onDismiss: {
            hasFocus = true
            Task { await library.reload() }     // pick up new paths / hidden games / API keys
        }) {
            SettingsView(tab: $settingsTab)
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(controller)
        }
        .task {
            hasFocus = true
            await library.reload()
        }
    }

    // MARK: Input routing

    private func handle(_ action: NavAction) {
        NSCursor.setHiddenUntilMouseMoves(true)

        if showSettings {
            let tabs = SettingsTab.allCases
            let i = tabs.firstIndex(of: settingsTab) ?? 0
            switch action {
            case .cancel, .menu: showSettings = false
            case .pageLeft:      settingsTab = tabs[max(0, i - 1)]
            case .pageRight:     settingsTab = tabs[min(tabs.count - 1, i + 1)]
            default: break
            }
            return
        }
        if showExitPrompt {
            if action == .confirm { NSApp.terminate(nil) }
            if action == .cancel { showExitPrompt = false }
            return
        }
        if showOptions {
            switch action {
            case .up:   optionIndex = max(0, optionIndex - 1)
            case .down: optionIndex = min(GameOption.allCases.count - 1, optionIndex + 1)
            case .confirm:
                run(GameOption.allCases[optionIndex])
                showOptions = false
            case .cancel, .options: showOptions = false
            default: break
            }
            return
        }
        if topBarFocused {
            switch action {
            case .confirm, .menu:
                topBarFocused = false
                showSettings = true
            case .down, .cancel:
                topBarFocused = false
            default: break
            }
            return
        }
        switch action {
        case .left:      library.move(-1)
        case .right:     library.move(1)
        case .pageLeft:  library.move(-5)
        case .pageRight: library.move(5)
        case .confirm:   library.launchSelected()
        case .cancel:    showExitPrompt = true
        case .menu:      showSettings = true
        case .options:
            if library.selectedGame != nil { optionIndex = 0; showOptions = true }
        case .up:        topBarFocused = true
        case .down:      break
        }
    }

    private func run(_ option: GameOption) {
        switch option {
        case .refreshArt: library.refreshSelectedMetadata()
        case .hide:       library.hideSelected()
        case .reveal:     library.revealSelectedInFinder()
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !showSettings else { return .ignored }
        let action: NavAction? = switch press.key {
        case .leftArrow:  .left
        case .rightArrow: .right
        case .upArrow:    .up
        case .downArrow:  .down
        case .return:     .confirm
        case .escape:     .cancel
        case KeyEquivalent("o"): .options
        case KeyEquivalent("s"): .menu
        default: nil
        }
        guard let action else { return .ignored }
        handle(action)
        return .handled
    }
}

private struct OptionsMenu: View {
    let title: String
    let selected: Int
    let onPick: (GameOption) -> Void
    let onClose: () -> Void

    @Environment(\.uiScale) private var s

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 8 * s) {
                Text(title)
                    .font(.system(size: 22 * s, weight: .bold))
                    .lineLimit(1)
                    .padding(.bottom, 8 * s)

                ForEach(Array(GameOption.allCases.enumerated()), id: \.offset) { index, option in
                    Button { onPick(option) } label: {
                        Label(option.title, systemImage: option.symbol)
                            .font(.system(size: 18 * s, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16 * s)
                            .padding(.vertical, 12 * s)
                            .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
                                .fill(.white.opacity(index == selected ? 0.22 : 0)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .frame(width: 340 * s)
            .padding(28 * s)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 26 * s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26 * s, style: .continuous).strokeBorder(.white.opacity(0.15)))
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct ExitPrompt: View {
    let onQuit: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var controller: ControllerManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.uiScale) private var s

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 26 * s) {
                Text("Quit Game Launcher?")
                    .font(.system(size: 28 * s, weight: .bold))
                HStack(spacing: 36 * s) {
                    Button(action: onQuit) {
                        HintItem(label: "Quit") { glyph(controller.confirmPosition) }
                    }
                    Button(action: onCancel) {
                        HintItem(label: "Stay") { glyph(controller.cancelPosition) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 17 * s, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(44 * s)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 28 * s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28 * s, style: .continuous).strokeBorder(.white.opacity(0.15)))
        }
    }

    private func glyph(_ position: ButtonPosition) -> some View {
        let g = controller.style.glyph(at: position)
        return ButtonGlyph(text: g.text, color: g.color)
    }
}

/// Console-style clock in the top-left corner.
private struct ClockLabel: View {
    @Environment(\.uiScale) private var s

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.system(size: 22 * s, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.5), radius: 6)
        }
    }
}

/// Navbar along the top edge. D-pad up (or ↑) focuses it; Play opens Settings.
private struct TopBar: View {
    let isFocused: Bool
    let onSettings: () -> Void

    @Environment(\.uiScale) private var s

    var body: some View {
        HStack {
            ClockLabel()
            Spacer()
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 16 * s, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18 * s)
                    .padding(.vertical, 10 * s)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(isFocused ? 1 : 0.18),
                                                    lineWidth: isFocused ? 3 : 1))
                    .shadow(color: .white.opacity(isFocused ? 0.5 : 0), radius: 14)
                    .scaleEffect(isFocused ? 1.06 : 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 80 * s)
        .padding(.top, 24 * s)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isFocused)
    }
}
