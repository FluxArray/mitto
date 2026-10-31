import Combine
import SwiftUI
import Security

/// Minimal Keychain wrapper so API secrets never sit in UserDefaults.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "GameLauncher"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

nonisolated enum RealHome {
    /// The real home directory, even when sandboxed (NSHomeDirectory would return the app container).
    static var path: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? RealHome.path + String(path.dropFirst()) : path
    }
}

@MainActor
final class AppSettings: ObservableObject {
    // Library
    @Published var libraryPaths: [String] {
        didSet { UserDefaults.standard.set(libraryPaths, forKey: "libraryPaths") }
    }
    @Published var manualGamePaths: [String] {
        didSet { UserDefaults.standard.set(manualGamePaths, forKey: "manualGamePaths") }
    }
    @Published var hiddenGamePaths: [String] {
        didSet { UserDefaults.standard.set(hiddenGamePaths, forKey: "hiddenGamePaths") }
    }
    @Published var showAllApps: Bool {
        didSet { UserDefaults.standard.set(showAllApps, forKey: "showAllApps") }
    }

    // API configuration (Keychain)
    @Published var steamGridDBKey: String {
        didSet { Keychain.set(steamGridDBKey, for: "steamGridDBKey") }
    }
    @Published var igdbClientID: String {
        didSet { Keychain.set(igdbClientID, for: "igdbClientID") }
    }
    @Published var igdbClientSecret: String {
        didSet { Keychain.set(igdbClientSecret, for: "igdbClientSecret") }
    }

    // Controller
    /// false = Xbox layout (confirm = bottom button), true = Nintendo layout (confirm = right button).
    @Published var swapConfirmCancel: Bool {
        didSet { UserDefaults.standard.set(swapConfirmCancel, forKey: "swapConfirmCancel") }
    }

    // Appearance
    @Published var uiScale: Double {
        didSet { UserDefaults.standard.set(uiScale, forKey: "uiScale") }
    }
    @Published var backgroundBlur: Double {
        didSet { UserDefaults.standard.set(backgroundBlur, forKey: "backgroundBlur") }
    }
    @Published var showPlaytime: Bool {
        didSet { UserDefaults.standard.set(showPlaytime, forKey: "showPlaytime") }
    }

    init() {
        let d = UserDefaults.standard
        let stored = (d.stringArray(forKey: "libraryPaths") ?? []).filter { !$0.contains("/Library/Containers/") }
        libraryPaths = stored.isEmpty ? ["/Applications", RealHome.path + "/Applications"] : stored
        hiddenGamePaths = d.stringArray(forKey: "hiddenGamePaths") ?? []
        manualGamePaths = d.stringArray(forKey: "manualGamePaths") ?? []
        showAllApps = d.bool(forKey: "showAllApps")
        steamGridDBKey = Keychain.get("steamGridDBKey")
        igdbClientID = Keychain.get("igdbClientID")
        igdbClientSecret = Keychain.get("igdbClientSecret")
        swapConfirmCancel = d.bool(forKey: "swapConfirmCancel")
        uiScale = d.object(forKey: "uiScale") as? Double ?? 1.0
        backgroundBlur = d.object(forKey: "backgroundBlur") as? Double ?? 40
        showPlaytime = d.object(forKey: "showPlaytime") as? Bool ?? true
    }

    var apiConfig: APIConfig {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return APIConfig(steamGridDBKey: trim(steamGridDBKey),
                         igdbClientID: trim(igdbClientID),
                         igdbClientSecret: trim(igdbClientSecret))
    }
}
