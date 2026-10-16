# Nebula — product spec

Nebula is a native macOS screen recorder and editor for polished product demos. It records crisp, native-resolution video. A one-click **Polish** adds smart zooms, cinematic camera motion, a smooth high-resolution cursor and speed-ups for slow parts. An editor lets you fine-tune all of it. A built-in MCP server lets an AI assistant do the same edits, live.

- Platform: macOS 15 Sequoia and later, Apple silicon and Intel.
- Distribution: signed DMG on GitHub Releases. Open source, MIT.
- Interface: English, dark theme only (black surfaces, violet accent), Manrope typeface.

## 1. Recording

| Area | Behaviour |
| --- | --- |
| Sources | Full display, a single window, or a dragged area. The desktop wallpaper is captured with the recording, so it can be the background later. |
| Quality | Native pixel resolution (Retina), 60 fps, HEVC in a fragmented `.mov`. Cursor is **not** baked in; it is recorded separately and drawn in post. |
| Audio | Microphone (device picker) and system audio, captured as separate tracks. |
| Flow | Menu-bar icon or global hotkey (⌥⌘↵) opens the recording bar → choose source → 3-second countdown → floating control widget (timer, pause/resume, restart, discard, finish) → project opens in the editor, with a quick-export widget. |
| Extras | Pause/resume; crash-safe fragmented writing; hide desktop icons; speaker-notes window. Nebula's own windows are never captured. |
| Input track | Cursor position (120 Hz), cursor shape, clicks, scrolls, key events (shortcut labels and "typing" flags, never the typed characters), and the bounds of the focused text field while typing. Used for the cursor overlay and for Polish. |

## 2. Polish (one click, or via MCP)

Polish analyses the input track, the video (frame activity) and the audio (speech activity), then writes ordinary, editable timeline items:

1. **Smart zooms.**
   - Click bursts become zooms framed around everything clicked in the burst.
   - Typing becomes a zoom framed on the focused text field.
   - Nearby targets are joined, so the camera *pans* between them instead of zooming out and back in.
   - Zoom levels adapt to the size of the target. No zoom is shorter than 1.2 s, and zooms avoid cut sections.
2. **Dead-air cuts:** sections where the cursor is idle, no keys are pressed, the screen is static and nobody is speaking.
3. **Typing speed-ups:** long typing runs with no speech play faster.
4. **Cursor:** smoothing, hiding the cursor when idle, and click effects.
5. **Style:** applies the default style preset.

Everything Polish adds is undoable as one step, and every setting it uses is configurable.

## 3. Editor

- **Preview** rendered by the same compositor used for export, so what you see is what you export. While scrubbing, a low-resolution mode keeps it smooth.
- **Timeline tracks:**
  - Clips: cuts, trims and per-section speed.
  - Zoom: auto or manual target, level, Instant or Spring.
  - Masks: blur, pixelate or highlight.
  - Annotations: text, arrow.
  - Captions.
  - Audio: waveform, per-section volume.
  - Music.
- **Look:**
  - Background: by default the real desktop that was behind the recording. Window and area recordings sit at their true on-screen size on a frame shaped like the screen ("As on screen"); full-display recordings fill the frame with no background. Alternatives: any macOS wallpaper, a colour or gradient, or your own image, with optional blur.
  - Frame: As on screen (with a scale) or Fit with padding; corner radius, shadow.
  - Crop.
  - Aspect ratio: Auto, 16:9, 9:16, 1:1, 4:3, 4:5.
- **Camera:** spring presets (Slow / Mellow / Quick / Rapid / Custom tension and friction) and motion blur strength.
- **Cursor:** size, smoothing, hide when idle, click effect (none, circle, ripple), and high-resolution cursor artwork.
- **Keyboard shortcuts overlay:** keycaps for pressed shortcuts.
- **Captions:** on-device WhisperKit transcription, styled word-by-word or line captions, SRT export.
- **Audio:**
  - per-section volume
  - background music with automatic ducking under speech
  - mic noise reduction
- **Workflow:**
  - ⌘K command palette and single-key editing shortcuts (Space, Z, C, S, M, T, A, ←/→)
  - style presets
  - project library
  - import `.openscreen` projects

## 4. Export

- MP4 in H.264 or HEVC: 720p, 1080p, 1440p or 4K at 30 or 60 fps.
- Quality presets: Studio, Social and Web.
- GIF with size, fps and loop settings.
- Copy the finished video to the clipboard; copy the current frame as an image.

## 5. MCP

- Nebula runs a local MCP server (Streamable HTTP, `127.0.0.1:39351/mcp`, local connections only).
- Tools edit the open project live: every change is undoable with ⌘Z and shown in a toast.
- Tools can also run Polish with options, generate captions, render preview frames and export.
- Tools can start and stop recordings. Settings decide whether Nebula asks first, always allows or never allows this.
- The MCP server and the UI drive the **same actions**, described in [ARCHITECTURE.md](ARCHITECTURE.md).
