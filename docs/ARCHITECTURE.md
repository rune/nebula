# Nebula — architecture

## Principles

1. **One source of truth.** A project is a single value type, `Project`. The editor holds one `ProjectStore`, and every change is a `ProjectEdit` applied to it. Undo, autosave, preview refresh and MCP notifications all hang off that one path.
2. **One action system.** Menus, keyboard shortcuts, the ⌘K palette, buttons and MCP tools all go through `ActionCenter`, so the app behaves the same whichever way an action is triggered.
3. **One renderer.** Preview, frame grabs, MCP previews and export all use the same `Compositor`, so the preview matches the export.
4. **Small modules, one-way dependencies.** Feature code depends on core code, never the other way. Modules talk through protocols; concrete types are created in the app target (the composition root) and passed in through initialisers.
5. **Value types and pure functions** for anything that can be tested without AVFoundation: timeline maths, camera physics, Polish planning, project coding.
6. **Swift 6 strict concurrency.** UI state is `@MainActor @Observable`, capture and rendering run on dedicated queues or actors, and data crosses between them as `Sendable` values.

## Modules (`Packages/NebulaKit`)

```
NebulaCore      models, timeline maths, time mapping, project coding, OpenScreen import   (no UI, no AV)
NebulaDesign    design tokens + reusable SwiftUI components                               (SwiftUI)
NebulaPolish    Polish planner, spring camera path, cursor smoothing, activity analysis  → Core
NebulaCapture   ScreenCaptureKit recorder, input monitor, permissions                    → Core
NebulaAudio     waveform, noise reduction, speech activity, music ducking               → Core
NebulaRender    Compositor (Core Image/Metal), AVComposition builder, export, GIF        → Core, Polish
NebulaCaptions  WhisperKit transcription, caption layout, SRT                           → Core
NebulaMCP       HTTP server, JSON-RPC 2.0, MCP protocol, tool registry                   → Core
NebulaApp       stores, ActionCenter, feature views (Library, Recorder, Editor)          → everything
```

The Xcode app target (`App/`) is only a thin shell: `@main`, the window scenes, the menu-bar extra, assets and entitlements. It constructs the live services and hands them to `NebulaApp`.

## Key types

| Type | Module | Role |
| --- | --- | --- |
| `Project` | Core | Codable value: media references, timeline items (`ZoomItem`, `ClipEdit`, `MaskItem`, `AnnotationItem`, `CaptionTrack`, `VolumeItem`, `MusicTrack`), `Style`, `CameraSettings`, `CursorSettings`. Times are in **source seconds**. |
| `InputTrack` | Core | Everything recorded besides pixels and audio: cursor samples, cursor images, clicks, keys, focus rects, capture geometry. |
| `TimeMap` | Core | Maps source time to output time and back, given cuts and speed sections. |
| `ProjectBundle` | Core | The `.nebula` package on disk: `project.json`, `recording.mov`, `input.json`, `thumbnail.jpg`. |
| `ProjectStore` | App | `@Observable` editor state: `project`, selection, playhead. `apply(_ edit:, label:)` records undo and triggers a render refresh. |
| `ActionCenter` | App | Registry of `AppAction` (id, title, shortcut, enablement, perform). Used by menus, the palette and MCP. |
| `RenderScene` | Render | Immutable snapshot built from a `Project` plus derived paths (camera, cursor) and handed to the compositor. |
| `Compositor` | Render | Draws one output frame: background → framed screen (camera transform, motion blur) → masks → cursor → keycaps → annotations → captions. |
| `EditorAutomation` | MCP | Protocol that the MCP tools call; implemented in App on top of `ProjectStore` and `ActionCenter`. |

## Data flow

```
Recorder ──▶ ProjectBundle (recording.mov + input.json) ──▶ Library
                                                   │
Editor UI / ⌘K / MCP ──▶ ActionCenter ──▶ ProjectStore.apply(edit) ──▶ autosave (debounced)
                                                   │
                                     RenderScene ──▶ Compositor ──▶ preview / export / frame grab
```

## Conventions

- File layout per module: `Models/`, `Services/`, `Views/` (UI modules only) and `Support/`. One primary type per file, named after the type.
- Public API is the minimum needed; everything else stays `internal`.
- Errors are typed enums conforming to `LocalizedError`, with user-facing messages.
- No force unwraps outside tests. No `print`: use `Logger` (`os`), one subsystem per module.
- Tests use Swift Testing (`@Test`). Pure logic gets unit tests; AV pipelines get integration tests on generated media.
- Formatting follows `swift-format` defaults with tabs.
