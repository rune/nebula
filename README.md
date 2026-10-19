<p align="center"><img src="design/icon.png" width="128" alt="Nebula icon"></p>

<h1 align="center">Nebula</h1>

<p align="center">Screen recordings that edit themselves. Native macOS, written in Swift, scriptable from Claude.</p>

<p align="center"><img src="design/mockups/editor.png" alt="The Nebula editor" width="860"></p>

## What it does

- **Records** a display, a window or an area at native Retina resolution and 60 fps (HEVC), with microphone and system audio. Pause, restart or discard from a floating control. The cursor, clicks and shortcuts are recorded separately so they can be redrawn smoothly.
- **Polish** in one click:
  - zooms on clicks and typing, panning between nearby targets instead of zooming out and back in
  - cuts dead air and speeds up long typing
  - smooths the cursor and adds click effects
- **Looks right by default.** A window recording keeps its real on-screen size over the wallpaper that was behind it, on a frame shaped like your screen. Full-screen recordings fill the frame.
- **Edits** on a timeline: cuts, speed, zooms, blur/pixelate/spotlight masks, text and arrows, per-section volume, music that ducks under your voice, noise reduction, and on-device captions (WhisperKit).
- **Exports** MP4 (H.264 or HEVC, up to 4K60) or GIF. You can also copy the video or a single frame to the clipboard.
- **⌘K** opens every command, style presets save a look, and `.openscreen` projects can be imported.
- **MCP server** built in: Claude can read the timeline, run Polish, add zooms and cuts, change the look, record and export. Each edit appears live in the editor and can be undone with ⌘Z.

## Install

Download the DMG from [Releases](https://github.com/rune/nebula/releases), open it and drag Nebula to Applications. On first launch, macOS asks for Screen Recording permission. Microphone and Accessibility permissions are optional: Accessibility lets Polish see clicks and text fields.

## Connect Claude

Nebula's MCP server listens on `127.0.0.1:39351`. To add it to Claude Code:

```bash
claude mcp add --transport http --scope user nebula http://127.0.0.1:39351/mcp
```

Then ask, for example: *"Polish my latest recording, blur the email field around 0:12 and export a 1080p MP4."*

## Build from source

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
```

```bash
open Nebula.xcodeproj
```

The app target is a thin shell. Everything else lives in the `Packages/NebulaKit` Swift package, whose tests run with:

```bash
swift test --package-path Packages/NebulaKit
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the modules fit together and [docs/SPEC.md](docs/SPEC.md) for the product spec.

## Maintainer

Nebula is made by [Rune](https://github.com/rune) and maintained by Soham Samal ([@sazuyakun](https://github.com/sazuyakun)). Open an [issue](https://github.com/rune/nebula/issues) for bugs and ideas; pull requests are reviewed by the maintainer.

## License

MIT © Rune. The Manrope typeface is bundled under the SIL Open Font License.
