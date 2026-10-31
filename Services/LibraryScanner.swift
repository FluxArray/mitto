import AppKit

/// Finds launchable games: official macOS games (App Store "Games" category)
/// and unofficial ports/wrappers (CrossOver launchers, Wineskin wrappers, etc.).
///
/// Wrapper detection is heuristic – extend `classify` as new wrapper formats appear.
nonisolated struct LibraryScanner: Sendable {
    func scan(paths: [String], manual: [String], includeAll: Bool) async -> [Game] {
        await Task.detached(priority: .userInitiated) {
            Self.scanSync(paths: paths, manual: manual, includeAll: includeAll)
        }.value
    }

    // NSDirectoryEnumerator can't be iterated from async contexts, so this stays synchronous.
    private static func scanSync(paths: [String], manual: [String], includeAll: Bool) -> [Game] {
        var found: [String: Game] = [:]
        var seenRealPaths = Set<String>()
        var seenNativeBundles = Set<String>()
        let fm = FileManager.default

        for path in paths {
            let root = URL(fileURLWithPath: RealHome.expand(path))
            guard let walker = fm.enumerator(at: root,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if walker.level > 5 { walker.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                guard seenRealPaths.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                if let game = makeGame(at: url, isManual: false, includeAll: includeAll) {
                    if game.kind == .macOS, let b = game.bundleID, !seenNativeBundles.insert(b).inserted { continue }
                    found[game.id] = game
                }
            }
        }

        // Manually added games always show, whatever their category.
        for path in manual {
            if let game = makeGame(at: URL(fileURLWithPath: path), isManual: true, includeAll: true) {
                found[game.id] = game
            }
        }
        return Array(found.values)
    }

    /// Apps that should never appear in the library (unless added by hand): the Steam client and the
    /// CrossOver app itself. Games launched *through* CrossOver are unaffected.
    private static let excludedNames: Set<String> = ["steam", "crossover"]
    /// Steam's own helper apps ("Steam Support Center", "Steam Helper", …).
    private static let excludedNamePrefixes = ["steam support", "steam helper", "steam client", "steamwebhelper", "steam link"]
    private static let excludedBundleIDs: Set<String> = ["com.valvesoftware.steam", "com.codeweavers.crossover"]

    /// Launchers that should be shown (and get artwork) as the game they are for.
    /// Add a row to extend: (text found in file name or bundle ID, title to use).
    private static let aliases: [(match: String, title: String)] = [
        ("modrinth", "Minecraft"),
        ("prism launcher", "Minecraft"),
        ("prismlauncher", "Minecraft"),
    ]

    private static func makeGame(at url: URL, isManual: Bool, includeAll: Bool) -> Game? {
        guard !url.path.hasPrefix("/System"),
              let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let bundleID = bundle.bundleIdentifier
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        let detected = classify(url: url, bundleID: bundleID, info: info)
        guard isManual || includeAll || detected != nil else { return nil }
        let kind = detected ?? .app

        let fileName = url.deletingPathExtension().lastPathComponent
        if !isManual,
           excludedNames.contains(fileName.lowercased())
            || excludedNamePrefixes.contains(where: { fileName.lowercased().hasPrefix($0) })
            || excludedBundleIDs.contains((bundleID ?? "").lowercased()) {
            return nil
        }
        var name = kind == .macOS
            ? (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
            : fileName   // wrapper bundles are named after the game; their Info.plist often isn't

        var aliased = false
        let haystack = (fileName + " " + (bundleID ?? "")).lowercased()
        if let alias = aliases.first(where: { haystack.contains($0.match) }) {
            name = alias.title
            aliased = true
        }

        return Game(id: url.path,
                    name: name,
                    url: url,
                    bundleID: bundleID,
                    version: info["CFBundleShortVersionString"] as? String,
                    kind: kind,
                    isManual: isManual,
                    metadata: nil,
                    aliased: aliased)
    }

    private static func classify(url: URL, bundleID: String?, info: [String: Any]) -> Game.Kind? {
        let id = (bundleID ?? "").lowercased()
        let path = url.path.lowercased()
        let contents = url.appendingPathComponent("Contents")
        let fm = FileManager.default

        // CrossOver launchers live in ~/Applications/CrossOver/<Bottle>/ and use CodeWeavers bundle IDs.
        if (id.hasPrefix("com.codeweavers.") && id != "com.codeweavers.crossover")
            || path.contains("/crossover/") {
            return .crossOver
        }

        // Wineskin / Kegworks-style wrappers embed their own wine runtime.
        if fm.fileExists(atPath: contents.appendingPathComponent("Wineskin.app").path)
            || fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/wswine.bundle").path) {
            return .wineskin
        }

        // Generic community ports / translation layers.
        let portHints = ["gptk", "kegworks", "sikarugir", "whisky", "macnative"]
        if portHints.contains(where: { id.contains($0) || path.contains($0) }) {
            return .port
        }

        // Official macOS games: Mac App Store "Games" and its sub-categories.
        let category = (info["LSApplicationCategoryType"] as? String) ?? ""
        if category.hasPrefix("public.app-category."), category.hasSuffix("games") {
            return .macOS
        }
        return nil
    }
}
