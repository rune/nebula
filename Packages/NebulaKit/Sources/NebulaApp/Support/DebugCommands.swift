import AppKit
import NebulaCore
import SwiftUI

extension Notification.Name {
	/// Debug builds: a command for views that keep their own state (tabs, popovers).
	static let nebulaDebugCommand = Notification.Name("app.nebula.debug.local")
}

extension View {
	/// Runs `handler` for debug commands (debug builds only; does nothing in release).
	@ViewBuilder
	func onDebugCommand(_ handler: @escaping (String) -> Void) -> some View {
		#if DEBUG
		onReceive(NotificationCenter.default.publisher(for: .nebulaDebugCommand)) { note in
			if let command = note.object as? String { handler(command) }
		}
		#else
		self
		#endif
	}
}

#if DEBUG
/// Debug builds only: drives the UI from outside so every screen can be checked without
/// clicking. Post the distributed notification `app.nebula.debug.command` with a command string,
/// e.g. `picker`, `mode:area`, `area:200,150,900,560`, `tab:camera`, `select-clip:1`, `palette`.
@MainActor
enum DebugCommands {
	private static var observer: NSObjectProtocol?

	static func install() {
		observer = DistributedNotificationCenter.default().addObserver(forName: .init("app.nebula.debug.command"), object: nil, queue: .main) { note in
			let command = note.object as? String ?? ""
			MainActor.assumeIsolated { run(command) }
		}
	}

	static func run(_ command: String) {
		let app = AppModel.shared
		let recorder = app.recorder
		let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
		let name = parts.first ?? ""
		let argument = parts.count > 1 ? parts[1] : ""
		let numbers = argument.split(separator: ",").compactMap { Double($0) }
		let store = app.activeStore

		switch name {
		case "picker": recorder.showPicker()
		case "cancel": recorder.cancelPicker()
		case "mode": recorder.mode = RecorderController.Mode(rawValue: argument) ?? .display
		case "area" where numbers.count == 4:
			recorder.area = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
		case "window": recorder.windowID = recorder.windows.first { $0.appName.localizedCaseInsensitiveContains(argument) }?.id ?? recorder.windows.first?.id
		case "record": recorder.start()
		case "pause": recorder.togglePause()
		case "stop": Task { await recorder.finish() }
		case "palette": CommandPaletteController.shared.toggle(app: app)
		case "export": app.showExportSheet = true
		case "dismiss": app.showExportSheet = false
		case "library": app.openLibraryWindow?()
		case "open":
			if let entry = app.entries.first(where: { $0.name == argument }) ?? app.entries.first { app.open(entry.bundle.url) }
		case "seek": store?.preview.seek(to: numbers.first ?? 0)
		case "select-clip":
			if let store, let index = numbers.first.map(Int.init), store.project.clips.indices.contains(index) { store.selectClip(store.project.clips[index]) }
		case "select":
			guard let store else { break }
			let ids: [ItemID] = switch argument {
			case "zoom": store.project.zooms.map(\.id)
			case "mask": store.project.masks.map(\.id)
			case "text", "arrow": store.project.annotations.map(\.id)
			case "volume": store.project.audio.volumes.map(\.id)
			default: []
			}
			if let first = ids.first { store.selection = [first] }
		case "deselect":
			store?.selection = []
			store?.selectClip(nil)
		case "add":
			switch argument {
			case "mask": store?.addMask()
			case "text": store?.addText()
			case "arrow": store?.addArrow()
			case "zoom": store?.addZoom()
			default: break
			}
		case "size" where numbers.count == 2:
			if let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.mainWindow {
				var frame = window.frame
				frame.size = CGSize(width: numbers[0], height: numbers[1])
				window.setFrame(frame, display: true)
			}
		case "key":
			NSApp.windows.first { $0.title.localizedCaseInsensitiveContains(argument) && $0.isVisible }?.makeKeyAndOrderFront(nil)
		default:
			// Tabs, popovers and other view state.
			NotificationCenter.default.post(name: .nebulaDebugCommand, object: command)
		}
	}
}
#endif
