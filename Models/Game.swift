import Foundation

/// Cached result of a metadata lookup. Artwork is stored as local file paths.
struct GameMetadata: Codable, Hashable, Sendable {
    var summary: String?          // short description shown under the title
    var officialName: String?     // title as the provider knows it, e.g. "The Legend of Zelda: Breath of the Wild"
    var releaseYear: Int?
    var coverPath: String?
    var heroPath: String?
    var logoPath: String?
    var fetchedAt: Date = .now
    /// Which providers were configured when this was fetched (see APIConfig.signature).
    var providers: String?

    var foundAnything: Bool { coverPath != nil || heroPath != nil || summary != nil }

    /// When to look this game up again:
    /// - the provider setup changed (e.g. a key was added) or the matching logic was updated;
    /// - nothing was found: retry after a week;
    /// - text was found but no artwork at all (e.g. a rate-limited lookup): retry after a day.
    func needsRefetch(for signature: String) -> Bool {
        if providers != signature { return true }
        let age = Date().timeIntervalSince(fetchedAt)
        if !foundAnything { return age > 7 * 24 * 3600 }
        if coverPath == nil && heroPath == nil { return age > 24 * 3600 }
        return false
    }
}

struct Game: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case macOS = "macOS"
        case crossOver = "CrossOver"
        case wineskin = "Wineskin"
        case port = "Port"
        case app = "App"

        var symbol: String {
            switch self {
            case .macOS: "apple.logo"
            case .crossOver, .wineskin, .port: "shippingbox"
            case .app: "app"
            }
        }
    }

    /// Absolute path of the .app bundle – stable and unique.
    let id: String
    var name: String
    var url: URL
    var bundleID: String?
    var version: String?
    var kind: Kind
    var isManual: Bool
    var metadata: GameMetadata?
    var aliased = false       // true when the name came from the alias table (e.g. Modrinth → Minecraft)

    var coverURL: URL? { metadata?.coverPath.map { URL(fileURLWithPath: $0) } }
    var heroURL: URL? { metadata?.heroPath.map { URL(fileURLWithPath: $0) } }
    var logoURL: URL? { metadata?.logoPath.map { URL(fileURLWithPath: $0) } }
    var summary: String? { metadata?.summary }

    /// Sort by the official title when we know it, so "Breath of the Wild" and "Tears of the Kingdom"
    /// sit together under "Legend of Zelda" instead of under B and T. Leading articles are ignored.
    var sortKey: String {
        var key = (metadata?.officialName ?? name).trimmingCharacters(in: .whitespaces)
        for article in ["the ", "a ", "an "] where key.lowercased().hasPrefix(article) {
            key = String(key.dropFirst(article.count))
            break
        }
        return key
    }
}
