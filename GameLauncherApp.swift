import SwiftUI
import AppKit

@main
struct GameLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var runner: GameRunner
    @StateObject private var library: LibraryViewModel
    @StateObject private var controller: ControllerManager

    init() {
        let settings = AppSettings()
        let runner = GameRunner()
        _settings = StateObject(wrappedValue: settings)
        _runner = StateObject(wrappedValue: runner)
        _library = StateObject(wrappedValue: LibraryViewModel(settings: settings, runner: runner))
        _controller = StateObject(wrappedValue: ControllerManager(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(runner)
                .environmentObject(library)
                .environmentObject(controller)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 650)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // One launcher window only.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Makes the hosting window borderless-looking and enters native full screen on launch.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
