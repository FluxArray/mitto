import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case library = "Library"
    case api = "API"
    case controller = "Controller"
    case appearance = "Appearance"

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tab: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            // A plain segmented picker instead of TabView: TabView's toolbar-style tabs
            // collapse and overlap when shown inside a sheet on recent macOS versions.
            Picker("Section", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 4)

            Group {
                switch tab {
                case .library:    LibraryTab()
                case .api:        APITab()
                case .controller: ControllerTab()
                case .appearance: AppearanceTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button("Quit Launcher", role: .destructive) { NSApp.terminate(nil) }
                Spacer()
                Text("L1 / R1 switch tabs · Cancel button or esc closes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 660, height: 580)
    }
}

// MARK: - Library

private struct LibraryTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryViewModel

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    var body: some View {
        Form {
            if isSandboxed {
                Section {
                    Label("App Sandbox is on, so ~/Applications and most wrappers (CrossOver, etc.) can't be read. In Xcode: target › Signing & Capabilities › delete “App Sandbox”.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }

            Section("Scan locations") {
                ForEach(settings.libraryPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button { settings.libraryPaths.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…", action: pickFolders)
            }

            Section("Added manually") {
                if settings.manualGamePaths.isEmpty {
                    Text("Games you add by hand appear here.").foregroundStyle(.secondary)
                }
                ForEach(settings.manualGamePaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "app").foregroundStyle(.secondary)
                        Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button { library.removeManualGame(path) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Game…", action: pickGames)
            }

            if !settings.hiddenGamePaths.isEmpty {
                Section("Hidden games") {
                    ForEach(settings.hiddenGamePaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            Spacer()
                            Button("Unhide") { library.unhide(path) }
                        }
                    }
                }
            }

            Section {
                Toggle("Show every application, not just detected games", isOn: $settings.showAllApps)
                Button("Rescan Library Now") { Task { await library.reload() } }
            } footer: {
                Text("Detection covers the Games category, CrossOver launchers and Wineskin-style wrappers. Changes also apply when you close Settings.")
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.libraryPaths.contains(url.path) {
            settings.libraryPaths.append(url.path)
        }
    }

    private func pickGames() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Game"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(library.addManualGame)
    }
}

// MARK: - API configuration

private struct APITab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryViewModel

    @State private var testResult: String?
    @State private var testing = false

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $settings.steamGridDBKey)
                Link("Get a free SteamGridDB key", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                Button(testing ? "Testing…" : "Test Key") {
                    testing = true
                    Task {
                        testResult = await SteamGridDBClient(apiKey: settings.apiConfig.steamGridDBKey).test()
                        testing = false
                    }
                }
                .disabled(testing || settings.steamGridDBKey.isEmpty)
                if let testResult {
                    Text(testResult)
                        .foregroundStyle(testResult.hasPrefix("✓") ? Color.green : Color.red)
                    if testResult.hasPrefix("✗ Couldn't reach"), isSandboxed {
                        Text("App Sandbox is on and blocks network access. Delete “App Sandbox” in Xcode (Signing & Capabilities), or enable Outgoing Connections (Client).")
                            .foregroundStyle(.yellow)
                    }
                }
            } header: {
                Text("SteamGridDB – banners, box art, logos")
            } footer: {
                Text("Recommended. Covers console games, emulator wrappers, ports and everything else the Steam Store doesn't list.")
            }

            Section {
                TextField("Client ID", text: $settings.igdbClientID)
                SecureField("Client secret", text: $settings.igdbClientSecret)
                Link("Create IGDB credentials", destination: URL(string: "https://dev.twitch.tv/console/apps")!)
            } header: {
                Text("IGDB – descriptions and release years")
            } footer: {
                Text("Optional. Used when the Steam Store has no description. Keys are stored in your Keychain.")
            }

            Section {
                Text("With no keys at all, art and descriptions come from the Steam Store, which only knows PC games on Steam.")
                    .foregroundStyle(.secondary)
                Button("Clear Cached Artwork and Re-fetch", role: .destructive) {
                    Task {
                        await library.clearMetadataCache()
                        await library.reload()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controller

private struct ControllerTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: ControllerManager

    var body: some View {
        Form {
            Section {
                Toggle("Nintendo layout (swap Confirm and Cancel)", isOn: $settings.swapConfirmCancel)
            } footer: {
                Text("Xbox layout confirms with the bottom button. Nintendo layout confirms with the right button, which is labelled A on Switch controllers.")
            }

            Section("Connected controller") {
                if controller.isConnected {
                    LabeledContent("Name", value: controller.displayName)
                } else {
                    Text("No controller detected. Pair one in System Settings › Bluetooth, or connect it with USB.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                row("Choose a game", keys: "← →") { Image(systemName: "dpad.fill") }
                row("Jump 5 games", keys: "—") { Text("L1 / R1").font(.callout.weight(.semibold)) }
                row("Play", keys: "Return") { glyph(controller.confirmPosition) }
                row("Game options", keys: "O") { glyph(.top) }
                row("Top bar (Settings button)", keys: "↑") { Image(systemName: "dpad.fill") }
                row("Settings", keys: "S") { Image(systemName: "line.3.horizontal.circle.fill") }
                row("Back / quit prompt", keys: "Esc") { glyph(controller.cancelPosition) }
            } header: {
                HStack { Text("Controls"); Spacer(); Text("Keyboard") }
            } footer: {
                Text("Inside menus, up/down moves, Play selects and Back closes. The left stick works like the D-pad.")
            }
        }
        .formStyle(.grouped)
    }

    private func row<Pad: View>(_ title: String, keys: String, @ViewBuilder pad: () -> Pad) -> some View {
        LabeledContent(title) {
            HStack(spacing: 18) {
                pad()
                Text(keys).foregroundStyle(.secondary).frame(minWidth: 56, alignment: .trailing)
            }
        }
    }

    private func glyph(_ position: ButtonPosition) -> some View {
        let g = controller.style.glyph(at: position)
        return ButtonGlyph(text: g.text, color: g.color)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("UI scale") {
                    HStack {
                        Slider(value: $settings.uiScale, in: 0.8...1.3, step: 0.05)
                        Text("\(Int((settings.uiScale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Background blur") {
                    HStack {
                        Slider(value: $settings.backgroundBlur, in: 0...80, step: 5)
                        Text("\(Int(settings.backgroundBlur))")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section {
                Toggle("Show playtime", isOn: $settings.showPlaytime)
            }
        }
        .formStyle(.grouped)
    }
}
