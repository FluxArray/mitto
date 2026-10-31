import Combine
import AppKit

/// Launches games through NSWorkspace and tracks them until they quit.
///
/// - No KVO on NSRunningApplication (observing `isTerminated` crashed the launcher when the app object
///   was released); termination is detected through NSWorkspace notifications instead.
/// - Apps that start within a few seconds of pressing Play (wine processes behind a CrossOver launcher,
///   helper apps) count as part of the game, so a launcher stub that quits straight away doesn't end the session.
/// - The launcher never leaves full screen. While it is full screen it stays where it is and the game
///   opens in its own Space; otherwise it hides itself once the game has taken focus.
@MainActor
final class GameRunner: ObservableObject {
    @Published private(set) var runningGameID: String?
    @Published private(set) var playtime: [String: TimeInterval]

    private var launchedGame: Game?
    private var startedAt: Date?
    private var isRetry = false
    private var tracked: [pid_t: NSRunningApplication] = [:]
    private var sessionEndTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let defaultsKey = "playtime"

    /// Apps that launch within this many seconds of pressing Play belong to the game.
    private let adoptWindow: TimeInterval = 30
    /// A native game that exits this soon after starting is treated as a failed start and opened once more.
    private let earlyExitWindow: TimeInterval = 10

    init() {
        playtime = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: TimeInterval] ?? [:]

        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.appLaunched($0) }
            .store(in: &cancellables)
        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.appTerminated($0) }
            .store(in: &cancellables)
    }

    var isRunning: Bool { runningGameID != nil }

    func playtimeString(for id: String) -> String {
        let t = playtime[id] ?? 0
        guard t >= 60 else { return t == 0 ? "Not played yet" : "< 1 min played" }
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m played" : "\(m)m played"
    }

    // MARK: Launching

    func launch(_ game: Game) async {
        guard runningGameID == nil else { return }
        runningGameID = game.id
        await start(game, isRetry: false)
    }

    /// Switches back to a game that is already running ("Resume").
    func bringToFront() {
        tracked.values.first(where: { !$0.isTerminated })?.activate()
    }

    private func start(_ game: Game, isRetry: Bool) async {
            launchedGame = game
            self.isRetry = isRetry
            startedAt = Date()
            tracked.removeAll()
            sessionEndTask?.cancel()

            let configuration = NSWorkspace.OpenConfiguration()
            // Launch in the background. The game boots safely on the stable Desktop Space
            // without an active animation, preventing the MetalFX 0x0 bounds crash.
            configuration.activates = false

            do {
                let app = try await NSWorkspace.shared.openApplication(at: game.url, configuration: configuration)
                tracked[app.processIdentifier] = app
                if app.isTerminated {                       // gone before we could even track it
                    tracked.removeValue(forKey: app.processIdentifier)
                    scheduleSessionEnd()
                    return
                }
                
                // Give the community port half a second to initialize its graphics context
                try? await Task.sleep(for: .milliseconds(500))
                
                // Now pull the fully initialized game window to the front
                app.activate()
                
                await hideLauncherIfNeeded(for: app)
            } catch {
                NSSound.beep()
                reset()
            }
        }

    private func hideLauncherIfNeeded(for app: NSRunningApplication) async {
            // Full screen: the launcher sits in its own Space and the game opens elsewhere.
            // Nothing to hide, and no Space change for the game's start-up to race with.
            if NSApp.windows.contains(where: { $0.styleMask.contains(.fullScreen) }) { return }

            for _ in 0..<16 {                               // wait up to ~4 s for the game to take focus
                if app.isTerminated { return }
                if app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            NSApp.hide(nil)
        }

    // MARK: Session tracking

    private func appLaunched(_ note: Notification) {
        guard runningGameID != nil,
              let started = startedAt, Date().timeIntervalSince(started) < adoptWindow,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        tracked[app.processIdentifier] = app
        sessionEndTask?.cancel()                        // the game handed off to another process
    }

    private func appTerminated(_ note: Notification) {
        guard runningGameID != nil,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              tracked.removeValue(forKey: app.processIdentifier) != nil else { return }
        if tracked.isEmpty { scheduleSessionEnd() }
    }

    /// Ends the session a moment after the last tracked app quits. Launcher stubs quit within seconds and
    /// hand off to another process, so never end before that process has had time to appear.
    private func scheduleSessionEnd() {
        sessionEndTask?.cancel()
        sessionEndTask = Task { [weak self] in
            guard let self, let started = self.startedAt else { return }
            let wait = max(3, started.addingTimeInterval(12).timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, self.tracked.isEmpty else { return }
            self.finishSession()
        }
    }

    private func finishSession() {
            guard let game = launchedGame, let started = startedAt else {
                reset()
                return
            }
            let elapsed = Date().timeIntervalSince(started)

            // A native game or port that dies within seconds failed to start. Open it once more.
            // We exclude CrossOver and Wineskin because their launcher stubs intentionally quit early.
            if elapsed < earlyExitWindow, game.kind != .crossOver, game.kind != .wineskin, !isRetry {
                Task { await start(game, isRetry: true) }
                return
            }

            playtime[game.id, default: 0] += elapsed
            UserDefaults.standard.set(playtime, forKey: defaultsKey)
            reset()

            NSApp.unhide(nil)
            NSApp.activate()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

    private func reset() {
        runningGameID = nil
        launchedGame = nil
        startedAt = nil
        isRetry = false
        tracked.removeAll()
        sessionEndTask?.cancel()
        sessionEndTask = nil
    }
}
