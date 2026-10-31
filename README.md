# Game Launcher (macOS, SwiftUI)

Full-screen, controller-first game launcher for Apple Silicon Macs. Requires macOS 14+ and Xcode 15+.

## Project layout

```
GameLauncher/
├── GameLauncherApp.swift        @main, window setup, full screen
├── Models/
│   ├── Game.swift               Game + cached GameMetadata
│   └── AppSettings.swift        UserDefaults + Keychain-backed settings
├── Services/
│   ├── ControllerManager.swift  GameController input -> NavAction stream
│   ├── LibraryScanner.swift     Finds native games, CrossOver / Wineskin / port wrappers
│   ├── MetadataService.swift    SteamGridDB art + IGDB info + disk cache
│   └── GameRunner.swift         NSWorkspace launch, hide/restore, playtime
├── ViewModels/
│   └── LibraryViewModel.swift   Games, selection, metadata fetching
└── Views/
    ├── ContentView.swift        Root: backdrop, banner, carousel, hints, input routing
    ├── HeroBannerView.swift     Hero art, logo, title, tagline, pills
    ├── GameCarouselView.swift   Box-art carousel
    ├── ArtAnalyzer.swift        Logo colour + icon trimming for the ring light
    ├── Components.swift         ArtworkImage, backdrop, hint bar, UI-scale key
    └── SettingsView.swift       Library / API / Controller / Appearance tabs
```

## Xcode setup

1. File > New > Project > macOS > App. Interface: SwiftUI, Language: Swift. Name it `GameLauncher`.
2. Delete the generated `GameLauncherApp.swift` and `ContentView.swift`, then drag the files from this folder into the project (copy items, create groups).
3. Target > General > Minimum Deployments: macOS 14.0.
4. Target > Build Settings: set **Swift Language Version** to **5** (the code is written for Swift 5 mode; Swift 6 strict concurrency will flag GameController and AppKit types).
5. Target > Signing & Capabilities: **remove App Sandbox**. A launcher has to read `/Applications` and open arbitrary apps. Keep Hardened Runtime on for notarization.
6. Run. The window enters full screen automatically.

## Where banners and descriptions come from

- **SteamGridDB** (free key, Settings › API): banners, box art, logos for practically anything, including console games, emulator wrappers and ports. This is the one you want.
- **Steam Store** (no key): used automatically as a fallback for PC games that exist on Steam.
- **IGDB** (optional): description fallback and release year.

Without a SteamGridDB key, games that aren't on Steam (e.g. Nintendo titles) show their app icon on a tinted backdrop.

## Controls

| Action | Controller | Keyboard |
| --- | --- | --- |
| Move | D-pad / left stick | ← → |
| Jump 5 games | L1 / R1 | – |
| Play | Confirm | Return |
| Game options (refresh art, hide, show in Finder) | Y / top button | O |
| Settings | ≡ / Start / + (or D-pad up to the top bar, then Play) | S, or ↑ then Return |
| Back / quit prompt | Cancel | Esc |

Confirm/Cancel follow physical position. Xbox layout confirms with the bottom button; Nintendo layout (Settings › Controller) confirms with the right button.

## Known limitations

- **Settings by controller:** B closes the Settings sheet, but the forms inside it (text fields, sliders) need mouse or keyboard.
- **Wrapper launchers:** some CrossOver or Wineskin launchers start the real game in a child process and quit themselves. In that case the launcher comes back immediately and playtime is undercounted.
- **CrossOver:** only launchers (.app files made via Create Launcher or an installed Windows app) are detected, not bare programs inside a bottle. If App Sandbox is on, ~/Applications is unreadable; Settings › Library shows a warning.
- **Wrapper detection** is heuristic (`LibraryScanner.classify`). Anything it misses can be added with Add Game, or by enabling "Show every application".
- **Steam games** are not scanned by default. Add `~/Library/Application Support/Steam/steamapps/common` as a scan location if you want them.
- **Matching** relies on the app's file name. Rename a wrapper to the game's real title if the wrong art is fetched.
- Not compiled in the environment this was written in. Expect to fix a few compiler nits on first build.
