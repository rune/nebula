import AppKit
import Carbon.HIToolbox
import NebulaDesign
import SwiftUI

/// All of Nebula's windows and menus. The app target's `@main` just returns this.
public struct NebulaScenes: Scene {
	@Bindable private var app = AppModel.shared

	public init() {}

	public var body: some Scene {
		Window("Nebula", id: "library") {
			LibraryView()
				.environment(app)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1180, height: 760)
		.commands { NebulaCommands(app: app) }

		WindowGroup("Editor", id: "editor", for: URL.self) { $url in
			if let url {
				EditorWindow(url: url)
					.environment(app)
			}
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1440, height: 900)

		Settings {
			SettingsView()
				.environment(app)
		}

		MenuBarExtra {
			MenuBarContent().environment(app)
		} label: {
			Image(systemName: app.recorder.isRecording ? "record.circle.fill" : "circle.hexagongrid.fill")
		}
	}
}

/// Launch-time setup: font, MCP server, recorder panels, global shortcut.
@MainActor
public final class NebulaAppDelegate: NSObject, NSApplicationDelegate {
	private var panels: RecorderPanels?
	private var hotKey: GlobalHotKey?

	override public init() {
		super.init()
	}

	public func applicationWillFinishLaunching(_ notification: Notification) {
		NebulaFont.register()
		NSApp.appearance = NSAppearance(named: .darkAqua)
	}

	public func applicationDidFinishLaunching(_ notification: Notification) {
		let app = AppModel.shared
		app.launch()
		panels = RecorderPanels(app: app)
		#if DEBUG
		DebugSnapshots.install()
		DebugCommands.install()
		#endif
		hotKey = GlobalHotKey(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | optionKey)) {
			if app.recorder.isRecording {
				Task { await app.recorder.finish() }
			} else if app.recorder.phase == .choosing {
				app.recorder.start()
			} else {
				app.recorder.showPicker()
			}
		}
	}

	public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag { AppModel.shared.openLibraryWindow?() }
		return true
	}

	public func application(_ application: NSApplication, open urls: [URL]) {
		let app = AppModel.shared
		for url in urls {
			if url.pathExtension == "nebula" {
				app.open(url)
			} else {
				Task { await app.importFile(url) }
			}
		}
	}

	public func applicationWillTerminate(_ notification: Notification) {
		for store in AppModel.shared.stores.values { store.saveNow() }
		AppModel.shared.mcp.stop()
	}
}

// MARK: - Menus

struct NebulaCommands: Commands {
	let app: AppModel

	var body: some Commands {
		CommandGroup(replacing: .newItem) {
			// ⌥⌘↩ is a global shortcut (GlobalHotKey), so it isn't repeated here.
			Button(app.recorder.isRecording ? "Finish Recording  ⌥⌘↩" : "New Recording…  ⌥⌘↩") {
				if app.recorder.isRecording { Task { await app.recorder.finish() } } else { app.recorder.showPicker() }
			}
			Button("Import…") { ImportPanel.run(app: app) }
				.keyboardShortcut("i")
			Divider()
			Button("Export…") { app.showExportSheet = true }
				.keyboardShortcut("e")
				.disabled(app.activeStore == nil || app.exports.isExporting)
			Button("Copy Video") { if let store = app.activeStore { Task { await app.exports.copyVideo(store) } } }
				.keyboardShortcut("c", modifiers: [.command, .shift])
				.disabled(app.activeStore == nil)
			Button("Copy Frame") { if let store = app.activeStore { Task { await app.exports.copyFrame(store) } } }
				.keyboardShortcut("c", modifiers: [.command, .option])
				.disabled(app.activeStore == nil)
		}
		CommandGroup(replacing: .undoRedo) {
			Button(app.activeStore?.undoLabel.map { "Undo \($0)" } ?? "Undo") { undo() }
				.keyboardShortcut("z")
			Button(app.activeStore?.redoLabel.map { "Redo \($0)" } ?? "Redo") { redo() }
				.keyboardShortcut("z", modifiers: [.command, .shift])
		}
		CommandMenu("Edit Video") {
			Button("Polish") {
				guard let store = app.activeStore else { return }
				Task {
					if let plan = try? await store.polish(options: app.settings.polishOptions) {
						app.toasts.show("Polished", detail: plan.summary, showsUndo: true)
					}
				}
			}
			.keyboardShortcut("p")
			.disabled(app.activeStore == nil || app.activeStore?.isPolishing == true)
			Divider()
			Button("Add Zoom") { app.activeStore?.addZoom() }
			Button("Split Clip at Playhead") { app.activeStore?.splitAtPlayhead() }
			Button("Toggle 2× Speed on Clip") { app.activeStore?.addSpeed() }
			Button("Delete Clip") { if let store = app.activeStore, let clip = store.selectedClip { store.deleteClip(clip) } }
				.disabled(app.activeStore?.selectedClip == nil)
			Button("Blur an Area") { app.activeStore?.addMask() }
			Button("Add Text") { app.activeStore?.addText() }
			Button("Add Arrow") { app.activeStore?.addArrow() }
			Divider()
			Button("Delete Selection") { if let store = app.activeStore { store.delete(store.selection) } }
				.disabled(app.activeStore?.selection.isEmpty ?? true)
		}
		CommandGroup(after: .toolbar) {
			Button("Command Palette") { CommandPaletteController.shared.toggle(app: app) }
				.keyboardShortcut("k")
			Button("Library") { app.openLibraryWindow?() }
				.keyboardShortcut("l", modifiers: [.command, .shift])
			Divider()
		}
	}

	/// Text fields keep their own undo; everything else undoes project edits.
	private func undo() {
		if NSApp.keyWindow?.firstResponder is NSText {
			NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
		} else {
			app.activeStore?.undo()
		}
	}

	private func redo() {
		if NSApp.keyWindow?.firstResponder is NSText {
			NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
		} else {
			app.activeStore?.redo()
		}
	}
}

private struct MenuBarContent: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		let recorder = app.recorder
		if recorder.isRecording {
			Text("Recording · \(Format.time(recorder.elapsed, tenths: false))")
			Button("Finish Recording") { Task { await recorder.finish() } }
			Button(recorder.phase == .paused ? "Resume" : "Pause") { recorder.togglePause() }
			Button("Discard Recording") { Task { await recorder.discard() } }
		} else {
			Button("New Recording…") { recorder.showPicker() }
		}
		Divider()
		Button("Open Library") {
			NSApp.activate()
			app.openLibraryWindow?()
		}
		if let last = app.exports.lastExport {
			Button("Show \(last.lastPathComponent)") { app.exports.revealLastExport() }
		}
		Divider()
		Text(app.mcp.isRunning ? "MCP server on :\(app.settings.mcpPort)" : "MCP server off")
		SettingsLink { Text("Settings…") }
		Button("Quit Nebula") { NSApp.terminate(nil) }
	}
}

// MARK: - Global shortcut

/// A system-wide keyboard shortcut via Carbon (no Accessibility permission needed).
@MainActor
final class GlobalHotKey {
	private var ref: EventHotKeyRef?
	private var handler: EventHandlerRef?
	private static var actions: [UInt32: () -> Void] = [:]
	private static var nextID: UInt32 = 1

	init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
		let id = Self.nextID
		Self.nextID += 1
		Self.actions[id] = action
		var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
			var hotKeyID = EventHotKeyID()
			GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
			let id = hotKeyID.id
			DispatchQueue.main.async {
				MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
			}
			return noErr
		}, 1, &spec, nil, &handler)
		let hotKeyID = EventHotKeyID(signature: OSType(0x4E42_4C41), id: id) // 'NBLA'
		RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
	}

	func unregister() {
		if let ref { UnregisterEventHotKey(ref) }
		if let handler { RemoveEventHandler(handler) }
		ref = nil
		handler = nil
	}
}
