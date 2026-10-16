import AppKit
import NebulaCore
import SwiftUI

/// One thing the user can do. Menus, keyboard shortcuts, buttons and the ⌘K palette all
/// run actions from here, so every entry point behaves identically.
@MainActor
public struct AppAction: Identifiable {
	public enum Group: String, CaseIterable {
		case record = "Record"
		case edit = "Edit"
		case timeline = "Timeline"
		case look = "Look"
		case playback = "Playback"
		case export = "Export"
		case app = "Nebula"
	}

	public let id: String
	public let title: String
	public let group: Group
	public let symbol: String
	public let shortcut: String?
	public let keywords: [String]
	public let isEnabled: Bool
	public let perform: () -> Void
}

/// Builds the actions available right now (depends on the frontmost project).
@MainActor
public enum ActionCenter {
	public static func actions(app: AppModel) -> [AppAction] {
		let store = app.activeStore
		let has = store != nil
		var actions: [AppAction] = [
			AppAction(id: "record", title: app.recorder.isRecording ? "Finish recording" : "New recording", group: .record, symbol: "record.circle", shortcut: "⌥⌘↩", keywords: ["capture", "screen"], isEnabled: true) {
				if app.recorder.isRecording { Task { await app.recorder.finish() } } else { app.recorder.showPicker() }
			},
			AppAction(id: "import", title: "Import video or OpenScreen project…", group: .record, symbol: "square.and.arrow.down", shortcut: "⌘I", keywords: ["open", "mp4", "mov"], isEnabled: true) {
				ImportPanel.run(app: app)
			},
			AppAction(id: "library", title: "Show library", group: .app, symbol: "square.grid.2x2", shortcut: "⇧⌘L", keywords: ["projects", "home"], isEnabled: true) {
				app.openLibraryWindow?()
			},
		]
		guard let store else { return actions }

		actions += [
			AppAction(id: "polish", title: "Polish recording", group: .edit, symbol: "sparkles", shortcut: "⌘P", keywords: ["auto", "zoom", "smart", "magic"], isEnabled: !store.isPolishing) {
				Task { try? await store.polish(options: app.settings.polishOptions) }
			},
			AppAction(id: "undo", title: store.undoLabel.map { "Undo \($0)" } ?? "Undo", group: .edit, symbol: "arrow.uturn.backward", shortcut: "⌘Z", keywords: [], isEnabled: store.canUndo) { store.undo() },
			AppAction(id: "redo", title: store.redoLabel.map { "Redo \($0)" } ?? "Redo", group: .edit, symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", keywords: [], isEnabled: store.canRedo) { store.redo() },
			AppAction(id: "delete", title: "Delete selection", group: .edit, symbol: "trash", shortcut: "⌫", keywords: ["remove"], isEnabled: !store.selection.isEmpty) { store.delete(store.selection) },
			AppAction(id: "zoom", title: "Add zoom at playhead", group: .timeline, symbol: "plus.magnifyingglass", shortcut: "Z", keywords: ["camera"], isEnabled: has) { store.addZoom() },
			AppAction(id: "cut", title: "Cut at playhead", group: .timeline, symbol: "scissors", shortcut: "C", keywords: ["trim", "remove", "split"], isEnabled: has) { store.cutAtPlayhead() },
			AppAction(id: "speed", title: "Speed up section", group: .timeline, symbol: "gauge.with.dots.needle.67percent", shortcut: "S", keywords: ["fast"], isEnabled: has) { store.addSpeed() },
			AppAction(id: "mask", title: "Blur an area", group: .timeline, symbol: "eye.slash", shortcut: "M", keywords: ["mask", "hide", "private", "pixelate"], isEnabled: has) { store.addMask() },
			AppAction(id: "text", title: "Add text", group: .timeline, symbol: "textformat", shortcut: "T", keywords: ["label", "annotation"], isEnabled: has) { store.addText() },
			AppAction(id: "arrow", title: "Add arrow", group: .timeline, symbol: "arrow.up.right", shortcut: "A", keywords: ["annotation", "point"], isEnabled: has) { store.addArrow() },
			AppAction(id: "remove-auto", title: "Remove Polish zooms", group: .timeline, symbol: "minus.magnifyingglass", shortcut: nil, keywords: ["auto"], isEnabled: store.project.zooms.contains { $0.source == .polish }) {
				store.delete(Set(store.project.zooms.filter { $0.source == .polish }.map(\.id)))
			},
			AppAction(id: "play", title: store.preview.isPlaying ? "Pause" : "Play", group: .playback, symbol: store.preview.isPlaying ? "pause.fill" : "play.fill", shortcut: "Space", keywords: [], isEnabled: true) { store.preview.togglePlay() },
			AppAction(id: "start", title: "Go to start", group: .playback, symbol: "backward.end.fill", shortcut: "↖", keywords: ["beginning"], isEnabled: true) { store.preview.seek(to: 0) },
			AppAction(id: "export", title: "Export…", group: .export, symbol: "square.and.arrow.up", shortcut: "⌘E", keywords: ["render", "mp4", "gif", "share"], isEnabled: !app.exports.isExporting) {
				app.showExportSheet = true
			},
			AppAction(id: "copy-video", title: "Copy video to clipboard", group: .export, symbol: "doc.on.doc", shortcut: "⇧⌘C", keywords: ["share", "paste"], isEnabled: !app.exports.isExporting) {
				Task { await app.exports.copyVideo(store) }
			},
			AppAction(id: "copy-frame", title: "Copy current frame", group: .export, symbol: "photo", shortcut: "⌥⌘C", keywords: ["screenshot", "image"], isEnabled: true) {
				Task { await app.exports.copyFrame(store) }
			},
			AppAction(id: "save-preset", title: "Save look as preset…", group: .look, symbol: "paintpalette", shortcut: nil, keywords: ["style", "template"], isEnabled: true) {
				app.presets.save(StylePreset(name: "\(store.project.name) look", from: store.project))
				app.toasts.show("Saved look as a preset")
			},
		]
		for preset in app.presets.all {
			actions.append(AppAction(id: "preset-\(preset.id)", title: "Apply look: \(preset.name)", group: .look, symbol: "paintbrush", shortcut: nil, keywords: ["style", "preset"], isEnabled: true) {
				store.applyPreset(preset)
			})
		}
		for aspect in AspectRatio.allCases {
			actions.append(AppAction(id: "aspect-\(aspect.rawValue)", title: "Aspect ratio: \(aspect.title)", group: .look, symbol: "aspectratio", shortcut: nil, keywords: ["size", "vertical", "square"], isEnabled: store.project.style.aspectRatio != aspect) {
				store.apply("Aspect ratio \(aspect.title)") { $0.style.aspectRatio = aspect }
			})
		}
		return actions
	}

	/// Case-insensitive fuzzy match on title and keywords; ranks prefix matches first.
	public static func search(_ query: String, in actions: [AppAction]) -> [AppAction] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !q.isEmpty else { return actions.filter(\.isEnabled) }
		func score(_ action: AppAction) -> Int? {
			let title = action.title.lowercased()
			if title.hasPrefix(q) { return 0 }
			if title.contains(q) { return 1 }
			if action.keywords.contains(where: { $0.hasPrefix(q) }) { return 2 }
			var index = title.startIndex
			for character in q {
				guard let found = title[index...].firstIndex(of: character) else { return nil }
				index = title.index(after: found)
			}
			return 3
		}
		return actions.compactMap { action in score(action).map { (action, $0) } }
			.sorted { $0.1 < $1.1 }
			.map(\.0)
	}
}

/// The Import open panel.
@MainActor
enum ImportPanel {
	static func run(app: AppModel) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .init(filenameExtension: "openscreen") ?? .json]
		panel.allowsMultipleSelection = false
		panel.message = "Choose a video or an OpenScreen project to import."
		guard panel.runModal() == .OK, let url = panel.url else { return }
		Task { await app.importFile(url) }
	}
}
