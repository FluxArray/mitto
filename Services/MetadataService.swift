import Foundation
import CryptoKit

// MARK: - Configuration & paths

struct APIConfig: Sendable, Equatable {
    var steamGridDBKey = ""
    var igdbClientID = ""
    var igdbClientSecret = ""

    var hasArtworkProvider: Bool { !steamGridDBKey.isEmpty }
    var hasInfoProvider: Bool { !igdbClientID.isEmpty && !igdbClientSecret.isEmpty }

    /// Changes whenever a provider is added or removed.
    var signature: String { "\(hasArtworkProvider ? "s" : "-")\(hasInfoProvider ? "i" : "-")4" }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GameLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var metadataFile: URL { support.appendingPathComponent("metadata-v2.json") }
    static var artworkRoot: URL { support.appendingPathComponent("Artwork", isDirectory: true) }

    static func artworkDirectory(for gameID: String) -> URL {
        let hash = SHA256.hash(data: Data(gameID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = artworkRoot.appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Text helpers

enum TitleCleaner {
    /// Search terms to try, best first: "BombSquad" then "Bomb Squad".
    static func candidates(_ raw: String) -> [String] {
        let plain = clean(raw, splitCamelCase: false)
        let split = clean(raw, splitCamelCase: true)
        return plain == split ? [plain] : [plain, split]
    }

    /// "Stardew_Valley v1.5.6 (Wine).app" → "Stardew Valley"
    static func clean(_ raw: String, splitCamelCase: Bool = true) -> String {
        var s = raw
        if s.lowercased().hasSuffix(".app") { s.removeLast(4) }
        func apply(_ pattern: String, _ replacement: String) {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        apply(#"[\(\[\{][^\)\]\}]*[\)\]\}]"#, " ")          // (Wine) [GOG] {x64}
        apply(#"\b[vV]?\d+(\.\d+)+\b"#, " ")                // v1.2.3
        apply(#"_+"#, " ")
        if splitCamelCase { apply(#"(?<=[a-z])(?=[A-Z])"#, " ") }   // StardewValley → Stardew Valley
        apply(#"(?i)\b(crossover|wineskin|wine|gog|macos)\b"#, " ")
        apply(#"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}

enum TextTools {
    /// Strips HTML tags/entities that store APIs sometimes leave in descriptions.
    static func clean(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&quot;": "\"", "&amp;": "&", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&lt;": "<", "&gt;": ">"]
        for (entity, plain) in entities { s = s.replacingOccurrences(of: entity, with: plain) }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short banner blurb made of whole sentences (as many as fit in `limit` characters).
    static func shorten(_ raw: String, limit: Int = 230) -> String {
        let text = clean(raw)
        guard text.count > limit else { return text }

        let sentences = text
            .replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
        var out = ""
        for sentence in sentences {
            let candidate = out.isEmpty ? sentence : out + " " + sentence
            if candidate.count > limit { break }
            out = candidate
        }
        if !out.isEmpty { return out }

        // One sentence alone is longer than the limit: cut at a word boundary.
        let head = String(text.prefix(limit))
        let cut = head.range(of: " ", options: .backwards).map { String(head[..<$0.lowerBound]) } ?? head
        return cut.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)) + "…"
    }
}

// MARK: - Title matching

enum TitleMatch {
    /// Words that don't change which game a title refers to.
    private static let noise: Set<String> = ["the", "a", "an", "of", "and", "edition", "definitive", "remastered",
                                              "remaster", "deluxe", "complete", "enhanced", "goty", "hd",
                                              "ultimate", "standard", "game", "year"]

    /// "Grand Theft Auto: Vice City – The Definitive Edition" and "Grand Theft Auto Vice City" share one key,
    /// and so do "FIFA22" and "FIFA 22".
    static func key(_ title: String) -> String {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !noise.contains($0) }
        let joined = words.joined()
        return joined.isEmpty ? title.lowercased().filter { $0.isLetter || $0.isNumber } : joined
    }
}

// MARK: - Wikipedia (no API key – covers console, delisted and non-Steam games)

struct WikipediaClient: Sendable {
    struct Summary: Sendable { var text: String; var year: Int? }

    private struct Response: Decodable {
        struct Page: Decodable { let title: String; let index: Int?; let extract: String? }
        struct Query: Decodable { let pages: [String: Page]? }
        let query: Query?
    }

    /// `names` in order of trust: the official title first, then the names derived from the file name.
    func lookup(names: [String]) async throws -> Summary? {
        for name in names {
            if let summary = try await lookup(name: name) { return summary }
        }
        return nil
    }

    private func lookup(name: String) async throws -> Summary? {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "\(name) video game"),
            URLQueryItem(name: "gsrlimit", value: "6"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1")
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue("GameLauncher/1.0 (personal macOS game launcher)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let pages = (try? JSONDecoder().decode(Response.self, from: data))?.query?.pages else { return nil }

        // Only accept a page whose title is this game ("Portal (video game)" counts as "Portal").
        let wanted = TitleMatch.key(name)
        let ranked = pages.values.sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }
        let hit = ranked.first(where: { page in
            let title = page.title.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
            let extract = page.extract?.lowercased() ?? ""
            return TitleMatch.key(title) == wanted && extract.contains("game") && !extract.contains("may refer to")
        })
        guard let raw = hit?.extract, !raw.isEmpty else { return nil }

        // "… is a 2002 action-adventure game", "… the 2011 video game"
        var year: Int?
        if let r = raw.range(of: #"\b(?:a|an|the) (?:19[789]\d|20[0-3]\d) [\w\- ]{0,40}?game"#,
                             options: [.regularExpression, .caseInsensitive]),
           let y = raw[r].range(of: #"\d{4}"#, options: .regularExpression) {
            year = Int(raw[r][y])
        }
        let text = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        return Summary(text: TextTools.shorten(text), year: year)
    }
}

// MARK: - Steam Store (no API key needed – PC games only)

struct SteamStoreClient: Sendable {
    struct Match: Sendable {
        var name: String?
        var description: String?
        var year: Int?
        var cover: [URL]
        var hero: [URL]
        var logo: [URL]
    }

    private struct Search: Decodable {
        struct Item: Decodable { let id: Int; let name: String }
        let items: [Item]?
    }
    private struct DetailsEnvelope: Decodable {
        struct Details: Decodable {
            struct Release: Decodable { let date: String? }
            let shortDescription: String?
            let releaseDate: Release?
        }
        let success: Bool
        let data: Details?
    }

    func lookup(terms: [String]) async throws -> Match? {
        for term in terms {
            if let match = try await lookup(term: term) { return match }
        }
        return nil
    }

    private func lookup(term: String) async throws -> Match? {
        var comps = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        comps.queryItems = [URLQueryItem(name: "term", value: term),
                            URLQueryItem(name: "l", value: "english"),
                            URLQueryItem(name: "cc", value: "us")]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let items = (try? JSONDecoder().decode(Search.self, from: data))?.items ?? []

        // Same title only (ignoring "The", "Definitive Edition", …). A looser match once gave Tears of the Kingdom
        // the description of an unrelated game with "Kingdom" in its name.
        guard let hit = items.first(where: { TitleMatch.key($0.name) == TitleMatch.key(term) }) else { return nil }

        let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(hit.id)"
        var match = Match(name: hit.name, description: nil, year: nil,
                          cover: [URL(string: "\(base)/library_600x900.jpg")!],
                          hero: [URL(string: "\(base)/library_hero.jpg")!, URL(string: "\(base)/header.jpg")!],
                          logo: [URL(string: "\(base)/logo.png")!])

        if let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(hit.id)&l=english"),
           let (d, _) = try? await URLSession.shared.data(from: url) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let details = (try? decoder.decode([String: DetailsEnvelope].self, from: d))?["\(hit.id)"]?.data
            match.description = details?.shortDescription.map { TextTools.shorten($0) }
            match.year = details?.releaseDate?.date.flatMap { date in
                date.range(of: #"\d{4}"#, options: .regularExpression).flatMap { Int(date[$0]) }
            }
        }
        return match
    }
}

// MARK: - SteamGridDB (artwork for everything, incl. console games and ports)

struct SteamGridDBClient: Sendable {
    struct Artwork: Sendable { var cover: URL?; var hero: URL?; var logo: URL?; var name: String? }

    private struct Envelope<T: Decodable>: Decodable { let success: Bool; let data: T? }
    private struct Entry: Decodable { let id: Int; let name: String }
    private struct Asset: Decodable { let url: URL }

    let apiKey: String

    /// Quick check used by Settings › API › Test Key.
    func test() async -> String {
        guard let url = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/portal") else { return "" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return "✓ Key works. SteamGridDB is reachable."
            case 401, 403: return "✗ SteamGridDB rejected the key (HTTP \(code)). Copy it again from your SteamGridDB preferences."
            default: return "✗ Unexpected response from SteamGridDB (HTTP \(code))."
            }
        } catch {
            return "✗ Couldn't reach SteamGridDB: \(error.localizedDescription)"
        }
    }

    func fetchArtwork(for terms: [String]) async throws -> Artwork? {
        var fallback: Artwork?     // keeps the official title even when an entry has no images
        for term in terms {
            let encoded = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? term
            guard let entries = try await get([Entry].self, "search/autocomplete/\(encoded)"), !entries.isEmpty else { continue }

            // Best title match first; try a few candidates until one actually has artwork.
            for entry in Self.ranked(entries, for: terms).prefix(3) {
                let art = try await artwork(for: entry)
                if art.cover != nil || art.hero != nil { return art }
                if fallback == nil { fallback = art }
            }
        }
        return fallback
    }

    private func artwork(for match: Entry) async throws -> Artwork {
        let common = [URLQueryItem(name: "types", value: "static"),
                      URLQueryItem(name: "nsfw", value: "false"),
                      URLQueryItem(name: "humor", value: "false")]
        async let grids = get([Asset].self, "grids/game/\(match.id)",
                              common + [URLQueryItem(name: "dimensions", value: "600x900,342x482,660x930")])
        async let heroes = get([Asset].self, "heroes/game/\(match.id)", common)
        async let logos = get([Asset].self, "logos/game/\(match.id)", common)

        let (g, h, l) = try await (grids, heroes, logos)
        return Artwork(cover: g?.first?.url, hero: h?.first?.url, logo: l?.first?.url, name: match.name)
    }

    /// Exact title first, then titles that contain ours ("The Legend of Zelda: Tears of the Kingdom"),
    /// then whatever SteamGridDB listed first.
    private static func ranked(_ entries: [Entry], for terms: [String]) -> [Entry] {
        let wanted = terms.map(TitleMatch.key).filter { !$0.isEmpty }
        func score(_ e: Entry) -> Int {
            let k = TitleMatch.key(e.name)
            if wanted.contains(k) { return 0 }
            if wanted.contains(where: { k.contains($0) }) { return 1 }
            return 2
        }
        return entries.enumerated()
            .sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }
            .map(\.element)
    }

    /// 404 = nothing for this game. Rate limits and server errors are retried, then reported as errors
    /// (so an incomplete result is never saved as if it were final).
    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T? {
        guard var comps = URLComponents(string: "https://www.steamgriddb.com/api/v2/\(path)") else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 || code >= 500 {
                if attempt < 2 {
                    try await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))
                    continue
                }
                throw URLError(.cannotLoadFromNetwork)
            }
            guard code == 200 else { return nil }
            return try JSONDecoder().decode(Envelope<T>.self, from: data).data
        }
        return nil
    }
}

// MARK: - IGDB (description fallback, release year)

actor IGDBClient {
    struct Info: Sendable { var name: String?; var summary: String?; var year: Int? }

    private struct Row: Decodable { let name: String?; let summary: String?; let firstReleaseDate: Int?; let versionParent: Int? }
    private struct Token: Decodable { let accessToken: String; let expiresIn: Double }

    private let clientID: String
    private let clientSecret: String
    private var token: (value: String, expires: Date)?

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    func fetchInfo(for term: String) async throws -> Info? {
        let bearer = try await accessToken()
        var request = URLRequest(url: URL(string: "https://api.igdb.com/v4/games")!)
        request.httpMethod = "POST"
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let safe = term.replacingOccurrences(of: "\"", with: "")
        request.httpBody = Data("search \"\(safe)\"; fields name,summary,first_release_date,version_parent; limit 10;".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Skip "editions" (they carry a later date), then prefer the entry whose title is ours.
        let rows = try decoder.decode([Row].self, from: data).filter { $0.versionParent == nil }
        let wanted = TitleMatch.key(term)
        func score(_ r: Row) -> Int {
            let k = TitleMatch.key(r.name ?? "")
            return k == wanted ? 0 : (k.contains(wanted) ? 1 : 2)
        }
        guard let best = rows.enumerated().min(by: { (score($0.element), $0.offset) < (score($1.element), $1.offset) })?.element,
              score(best) <= 1 else { return nil }

        func year(_ r: Row) -> Int? {
            r.firstReleaseDate.map { Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0))) }
        }
        // Several exact entries (original, remaster, platform ports): the earliest date is the original release.
        let exact = rows.filter { score($0) == 0 }
        let years = (exact.isEmpty ? [best] : exact).compactMap(year)
        return Info(name: best.name, summary: best.summary.map { TextTools.shorten($0) }, year: years.min())
    }

    private func accessToken() async throws -> String {
        if let token, token.expires > .now { return token.value }
        var comps = URLComponents(string: "https://id.twitch.tv/oauth2/token")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials")
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let t = try decoder.decode(Token.self, from: data)
        token = (t.accessToken, Date().addingTimeInterval(t.expiresIn - 60))
        return t.accessToken
    }
}

// MARK: - Orchestrator

/// Resolves metadata for a game, downloads artwork to disk, and persists results.
///
/// Source order – artwork: SteamGridDB (if keyed) → Steam Store.
///                description: Steam Store (exact title only) → IGDB (if keyed) → Wikipedia.
actor MetadataService {
    private var cache: [String: GameMetadata] = [:]
    private var igdbClient: (id: String, secret: String, client: IGDBClient)?

    init() {
        if let data = try? Data(contentsOf: AppPaths.metadataFile),
           let decoded = try? JSONDecoder().decode([String: GameMetadata].self, from: data) {
            cache = decoded
        }
    }

    func allCached() -> [String: GameMetadata] { cache }

    func clearCache() {
        cache = [:]
        try? FileManager.default.removeItem(at: AppPaths.artworkRoot)
        save()
    }

    func fetch(for game: Game, config: APIConfig, force: Bool = false) async -> GameMetadata {
        if !force, let hit = cache[game.id], !hit.needsRefetch(for: config.signature) { return hit }

        let terms = TitleCleaner.candidates(game.name)
        var hadError = false
        var sgdbName: String?
        var igdbName: String?
        var covers: [URL] = [], heroes: [URL] = [], logos: [URL] = []

        if config.hasArtworkProvider {
            do {
                if let art = try await SteamGridDBClient(apiKey: config.steamGridDBKey).fetchArtwork(for: terms) {
                    covers += [art.cover].compactMap { $0 }
                    heroes += [art.hero].compactMap { $0 }
                    logos += [art.logo].compactMap { $0 }
                    sgdbName = art.name
                }
            } catch { hadError = true }
        }

        var steam: SteamStoreClient.Match?
        do { steam = try await SteamStoreClient().lookup(terms: terms) } catch { hadError = true }
        covers += steam?.cover ?? []
        heroes += steam?.hero ?? []
        logos += steam?.logo ?? []

        let dir = AppPaths.artworkDirectory(for: game.id)
        var meta = GameMetadata()
        meta.providers = config.signature
        meta.coverPath = await download(first: covers, to: dir, name: "cover")
        meta.heroPath = await download(first: heroes, to: dir, name: "hero")
        meta.logoPath = await download(first: logos, to: dir, name: "logo")
        meta.summary = steam?.description
        var years = [steam?.year].compactMap { $0 }     // Steam dates its own listing, which can be a later remaster

        if config.hasInfoProvider {
            do {
                let client = igdb(for: config)
                for term in terms {
                    if let info = try await client.fetchInfo(for: term) {
                        igdbName = info.name
                        if meta.summary == nil { meta.summary = info.summary }
                        if let y = info.year { years.append(y) }
                        break
                    }
                }
            } catch { hadError = true }
        }

        meta.officialName = sgdbName ?? steam?.name ?? igdbName

        // Wikipedia (no key): description fallback for anything the Steam Store doesn't list, and a second
        // opinion on the release year.
        let names = ([meta.officialName] + terms.map(Optional.some)).compactMap { $0 }
        do {
            if let wiki = try await WikipediaClient().lookup(names: names) {
                if meta.summary == nil { meta.summary = wiki.text }
                if let y = wiki.year { years.append(y) }
            }
        } catch { hadError = true }

        meta.releaseYear = years.min()      // the original release, not a remaster or port

        if hadError {
            // Something failed (rate limit, offline…). Show what we have, but don't save it,
            // so the next launch tries again instead of treating a partial result as final.
            if let old = cache[game.id], old.foundAnything, !meta.foundAnything { return old }
            return meta
        }
        // Never overwrite good data with an empty result.
        if !meta.foundAnything, let old = cache[game.id], old.foundAnything { return old }
        cache[game.id] = meta
        save()
        return meta
    }

    // MARK: Private

    private func igdb(for config: APIConfig) -> IGDBClient {
        if let e = igdbClient, e.id == config.igdbClientID, e.secret == config.igdbClientSecret { return e.client }
        let client = IGDBClient(clientID: config.igdbClientID, clientSecret: config.igdbClientSecret)
        igdbClient = (config.igdbClientID, config.igdbClientSecret, client)
        return client
    }

    /// Tries each candidate URL in order and keeps the first that downloads.
    private func download(first candidates: [URL], to dir: URL, name: String) async -> String? {
        for url in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let file = dir.appendingPathComponent("\(name).\(ext)")
            if (try? data.write(to: file, options: .atomic)) != nil { return file.path }
        }
        return nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: AppPaths.metadataFile, options: .atomic)
        }
    }
}
