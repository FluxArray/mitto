# mitto

A full-screen, controller-first game launcher for macOS, in the style of Apple TV and PS5.
Native Mac games, CrossOver and Wineskin wrappers and ports, all in one place, with artwork fetched for you.
[Download the latest release](https://github.com/FluxArray/mitto/releases/latest)
## Features

- **Console-style interface:** a blurred backdrop from the selected game's art, a banner with logo, description and Play button, and a carousel with spring animations.
- **Finds your games:** scans `/Applications` and `~/Applications` for native macOS games, CrossOver launchers and Wineskin-style wrappers. You can also add folders or single apps by hand, and hide anything you don't want.
- **Automatic artwork and info:** banners, box art and logos from SteamGridDB. Descriptions from the Steam Store, IGDB (optional) and Wikipedia. Everything is cached on disk.
- **Controller first:** D-pad and left stick, L1/R1 to jump five games, and on-screen button glyphs that match your Xbox, PlayStation or Switch controller. Nintendo layout is one toggle away. The keyboard and mouse work too.
- **Easy to navigate:** big glowing arrows at both ends of the bottom bar show when you can move left or right, plus a position counter and a clock.
- **Launch and return:** opens the game, tracks playtime, and brings the launcher back when the game quits.
- **Colour-matched lighting:** the selected game gets a ring light and an ambient glow taken from its own artwork.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon Mac (Intel is untested)
- A controller is optional

## Install

1. Download `mitto-1.0.0.dmg` (or the newest version) from the [Releases page](https://github.com/FluxArray/mitto/releases/latest).
2. Open the DMG and drag **mitto** into **Applications**.
3. The first time, macOS may say the app can't be verified, because the build isn't notarized. Right-click **mitto** in Applications, choose **Open**, then **Open** again. If that doesn't work, run this in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/mitto.app
   ```

4. mitto opens in full screen. Press `Esc` (or the Cancel button) and confirm to quit.

## First-time setup

Open **Settings** with the button at the top right, the `S` key, or the ≡ / Start / + button on a controller.

1. **API tab:** paste a free [SteamGridDB API key](https://www.steamgriddb.com/profile/preferences/api) and press **Test Key** until it shows a green ✓. This is what gives you banners, box art and logos. IGDB credentials are optional and only used for descriptions.
2. **Library tab:** check the scan locations. `/Applications` and `~/Applications` are added by default, and CrossOver launchers live in `~/Applications/CrossOver`. Use **Add Game…** for anything that isn't detected.
3. Press **Done**. mitto rescans and fetches artwork in the background.

Without any API keys, mitto still works. It falls back to the Steam Store and Wikipedia, and shows app icons for games it can't find art for.

## Controls

| Action | Controller | Keyboard / mouse |
| --- | --- | --- |
| Move | D-pad / left stick | ← → or the arrows in the bottom bar |
| Jump 5 games | L1 / R1 | – |
| Play | Confirm | Return, or click the Play button |
| Game options (refresh art, hide, show in Finder) | Y / top button | O |
| Settings | ≡ / Start / + | S, or ↑ then Return |
| Back / quit prompt | Cancel | Esc |

Confirm and Cancel follow the physical button position. Xbox layout confirms with the bottom button. Nintendo layout (Settings › Controller) confirms with the right button.

## Build from source

Requires Xcode 15 or newer.

```bash
git clone https://github.com/FluxArray/mitto.git
```

1. In Xcode: **File › New › Project › macOS › App** (Interface: SwiftUI, Language: Swift), named `mitto`.
2. Delete the generated `ContentView.swift` and app file, then drag this repo's source folders and `GameLauncherApp.swift` into the project (copy items, create groups).
3. **Target › General › Minimum Deployments:** macOS 14.0.
4. **Target › Build Settings:** set **Swift Language Version** to **5**. If your Xcode has a *Default Actor Isolation* setting, set it to *nonisolated*.
5. **Target › Signing & Capabilities:** remove **App Sandbox**. A launcher has to read `/Applications` and open arbitrary apps. Keep Hardened Runtime on.
6. Run with ⌘R.

## Project layout

```
mitto/
├── GameLauncherApp.swift        @main, window setup, full screen
├── Models/
│   ├── Game.swift               Game + cached metadata
│   └── AppSettings.swift        UserDefaults + Keychain-backed settings
├── Services/
│   ├── ControllerManager.swift  GameController input -> navigation actions
│   ├── LibraryScanner.swift     Finds native games, CrossOver / Wineskin / port wrappers
│   ├── MetadataService.swift    SteamGridDB, Steam Store, IGDB, Wikipedia + disk cache
│   └── GameRunner.swift         Launch, focus, playtime
├── ViewModels/
│   └── LibraryViewModel.swift   Games, selection, metadata fetching
└── Views/
    ├── ContentView.swift        Root: backdrop, banner, carousel, bottom bar, input routing
    ├── HeroBannerView.swift     Banner art, logo, description, Play button, pills
    ├── GameCarouselView.swift   Carousel and selection ring
    ├── ArtAnalyzer.swift        Colour extraction and icon trimming (runs off the main thread)
    ├── Components.swift         Image loading, backdrop, bottom bar, arrows
    └── SettingsView.swift       Library / API / Controller / Appearance tabs
```

## Customising

- **Hide an app you don't want:** select it, press Y (or `O`), and choose *Hide from Library*.
- **Exclude apps for good:** edit `excludedNames` and `excludedNamePrefixes` in `LibraryScanner.swift`.
- **Show a launcher as another game:** add a row to `aliases` in `LibraryScanner.swift`. For example, `("modrinth", "Minecraft")` shows the Modrinth app with Minecraft's artwork.
- **Wrong artwork:** rename the `.app` to the game's real title, then choose *Refresh Artwork*.

## Known limitations

- The forms inside Settings (text fields, sliders) need a mouse or keyboard.
- Some CrossOver and Wineskin launchers start the real game in another process and quit, so playtime can be undercounted. For launcher-style apps like Modrinth, playtime counts the whole time the launcher stays open.
- Only `.app` launchers are detected, not bare programs inside a CrossOver bottle.
- Wrapper detection is heuristic (`LibraryScanner.classify`). Anything it misses can be added with *Add Game*, or by turning on *Show every application*.
- Steam games aren't scanned by default. Add `~/Library/Application Support/Steam/steamapps/common` as a scan location if you want them.
- Games that no database knows about may never get a banner.

## Contributing

Issues and pull requests are welcome.

## Credits

- Artwork: [SteamGridDB](https://www.steamgriddb.com). Game info: [Steam Store](https://store.steampowered.com), [IGDB](https://www.igdb.com) and [Wikipedia](https://www.wikipedia.org).
- Built with SwiftUI and Apple's GameController framework, with help from [Claude](https://www.anthropic.com/claude).
- Game names, logos and artwork belong to their respective owners. mitto does not include or distribute any games.

## License

[MIT](LICENSE)
