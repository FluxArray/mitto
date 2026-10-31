import Combine
import SwiftUI
import AppKit

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var selectedIndex = 0
    @Published private(set) var isScanning = false
    @Published private(set) var fetchingIDs: Set<String> = []

    private let settings: AppSettings
    private let runner: GameRunner
    private let scanner = LibraryScanner()
    private let metadata = MetadataService()

    init(settings: AppSettings, runner: GameRunner) {
        self.settings = settings
        self.runner = runner
    }

    var selectedGame: Game? { games.indices.contains(selectedIndex) ? games[selectedIndex] : nil }

    // MARK: Navigation

    func move(_ delta: Int) {
        guard !games.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), games.count - 1)
        if next != selectedIndex { selectedIndex = next }
    }

    func select(_ index: Int) {
        guard games.indices.contains(index) else { return }
        selectedIndex = index
    }

    func launchSelected() {
        guard let game = selectedGame else { return }
        if runner.runningGameID == game.id { runner.bringToFront(); return }     // "Resume"
        guard !runner.isRunning else { return }
        Task { await runner.launch(game) }
    }

    // MARK: Library

    func reload() async {
        isScanning = true
        let previousID = selectedGame?.id

        var found = await scanner.scan(paths: settings.libraryPaths,
                                       manual: settings.manualGamePaths,
                                       includeAll: settings.showAllApps)
        let hidden = Set(settings.hiddenGamePaths)
        found.removeAll { hidden.contains($0.id) }

        let cached = await metadata.allCached()
        for i in found.indices { found[i].metadata = cached[found[i].id] }
        found.sort { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }

        games = found
        selectedIndex = previousID.flatMap { id in found.firstIndex { $0.id == id } } ?? 0
        isScanning = false

        await fetchMissingMetadata()
    }

    func addManualGame(_ url: URL) {
        guard !settings.manualGamePaths.contains(url.path) else { return }
        settings.manualGamePaths.append(url.path)
    }

    func removeManualGame(_ path: String) {
        settings.manualGamePaths.removeAll { $0 == path }
    }

    // MARK: Per-game options

    func hideSelected() {
        guard let game = selectedGame else { return }
        settings.hiddenGamePaths.append(game.id)
        games.removeAll { $0.id == game.id }
        selectedIndex = min(selectedIndex, max(games.count - 1, 0))
    }

    func unhide(_ path: String) {
        settings.hiddenGamePaths.removeAll { $0 == path }
    }

    func revealSelectedInFinder() {
        guard let game = selectedGame else { return }
        NSWorkspace.shared.activateFileViewerSelecting([game.url])
    }

    // MARK: Metadata

    /// Re-scrapes artwork and description for the highlighted game.
    func refreshSelectedMetadata() {
        guard let game = selectedGame else { return }
        Task {
            fetchingIDs.insert(game.id)
            let meta = await metadata.fetch(for: game, config: settings.apiConfig, force: true)
            fetchingIDs.remove(game.id)
            apply(meta, to: game.id)
            resort()
        }
    }

    func clearMetadataCache() async {
        await metadata.clearCache()
        for i in games.indices { games[i].metadata = nil }
    }

    private func fetchMissingMetadata() async {
        let config = settings.apiConfig
        let pending = games.filter { $0.metadata?.needsRefetch(for: config.signature) ?? true }
        guard !pending.isEmpty else { return }
        fetchingIDs.formUnion(pending.map(\.id))

        let service = metadata
        var iterator = pending.makeIterator()

        // At most 2 games looked up at once, to stay under SteamGridDB's rate limit.
        await withTaskGroup(of: (String, GameMetadata).self) { group in
            func addNext() {
                if let game = iterator.next() {
                    group.addTask { (game.id, await service.fetch(for: game, config: config)) }
                }
            }
            for _ in 0..<2 { addNext() }
            for await (id, meta) in group {
                fetchingIDs.remove(id)
                apply(meta, to: id)
                addNext()
            }
        }
        resort()   // once, after everything has settled, so the carousel doesn't shuffle while loading
    }

    /// Re-sorts by official title, keeping the same game selected.
    private func resort() {
        let selectedID = selectedGame?.id
        games.sort { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
        if let selectedID, let i = games.firstIndex(where: { $0.id == selectedID }) { selectedIndex = i }
    }

    private func apply(_ meta: GameMetadata, to id: String) {
        if let i = games.firstIndex(where: { $0.id == id }) { games[i].metadata = meta }
    }
}
