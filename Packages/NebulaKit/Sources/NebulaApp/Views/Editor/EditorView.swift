import AppKit
import NebulaCore
import NebulaDesign
import NebulaPolish
import SwiftUI

/// One editor window: title bar, preview + inspector, timeline.
public struct EditorWindow: View {
	let url: URL
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var store: ProjectStore?
	@State private var error: String?

	public init(url: URL) {
		self.url = url
	}

	public var body: some View {
		Group {
			if let store {
				EditorView(store: store)
			} else if let error {
				VStack(spacing: 12) {
					Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Theme.text3)
					Text("Couldn't open this project").font(.nebula(15, 700)).foregroundStyle(Theme.text1)
					Text(error).font(.nebula(12.5, 550)).foregroundStyle(Theme.text2)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.frame(minWidth: 1080, minHeight: 700)
		.background(Theme.window)
		.ignoresSafeArea(.container, edges: .top)
		.task {
			do {
				store = try app.store(for: url)
				app.activeStoreURL = url
			} catch {
				self.error = error.localizedDescription
			}
		}
		.background(WindowAccessor { window in
			window.titlebarAppearsTransparent = true
			window.titleVisibility = .hidden
			window.isMovableByWindowBackground = false
			window.backgroundColor = NSColor(Theme.window)
			window.tabbingMode = .disallowed
			window.setFrameAutosaveName("Editor")
			// An empty unified toolbar makes the title bar 52 pt tall, so the traffic lights sit
			// centred in Nebula's own bar, which is drawn underneath.
			if window.toolbar == nil {
				let toolbar = NSToolbar(identifier: "editor")
				window.toolbar = toolbar
				window.toolbarStyle = .unified
			}
			EditorWindowTracker.shared.track(window, url: url, app: app)
		})
		.onDisappear { app.close(url) }
	}
}

/// Keeps `activeStoreURL` pointing at the frontmost editor.
@MainActor
final class EditorWindowTracker {
	static let shared = EditorWindowTracker()
	private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

	func track(_ window: NSWindow, url: URL, app: AppModel) {
		let key = ObjectIdentifier(window)
		guard observers[key] == nil else { return }
		if window.isKeyWindow { app.activeStoreURL = url }
		observers[key] = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
			MainActor.assumeIsolated { app.activeStoreURL = url }
		}
	}
}

struct EditorView: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app

	var body: some View {
		VStack(spacing: 0) {
			EditorTitleBar(store: store)
			HStack(alignment: .top, spacing: 0) {
				VStack(spacing: 0) {
					PreviewStage(store: store)
					TransportBar(store: store)
				}
				Inspector(store: store)
					.padding(.trailing, 14)
					.padding(.vertical, 10)
			}
			Hairline()
			TimelineView(store: store)
				.frame(height: 286)
		}
		.background(Theme.window)
		.overlay(alignment: .bottom) {
			ToastView(toasts: app.toasts) { app.activeStore?.undo() }
				.padding(.bottom, 304)
		}
		.overlay(alignment: .top) {
			if app.exports.quickExportURL == store.bundle.url {
				QuickExportCard(store: store)
					.padding(.top, 64)
					.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.animation(Theme.smooth, value: app.exports.quickExportURL)
		.background(EditorKeyHandler(store: store))
		.sheet(isPresented: Binding(
			get: { app.showExportSheet && app.activeStoreURL == store.bundle.url },
			set: { app.showExportSheet = $0 }
		)) {
			ExportSheet(store: store)
		}
		.environment(\.colorScheme, .dark)
	}
}

// MARK: - Title bar

private struct EditorTitleBar: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app
	@State private var renaming = false
	@State private var name = ""
	@State private var showPolish = false

	var body: some View {
		HStack(spacing: 12) {
			Color.clear.frame(width: 70)
			Button("Library") { app.openLibraryWindow?() }
				.buttonStyle(.plain)
				.font(.nebula(13, 600))
				.foregroundStyle(Theme.text3)
			Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
			if renaming {
				TextField("", text: $name)
					.textFieldStyle(.plain)
					.font(.nebula(13, 700))
					.foregroundStyle(Theme.text1)
					.frame(width: 220)
					.onSubmit(commitRename)
					.onExitCommand { renaming = false }
			} else {
				Text(store.project.name)
					.font(.nebula(13, 700))
					.foregroundStyle(Theme.text1)
					.onTapGesture(count: 2) {
						name = store.project.name
						renaming = true
					}
					.help("Double-click to rename")
			}
			SaveIndicator(store: store)
			Spacer()
			AssistantPill()
			IconButton("arrow.uturn.backward", help: store.undoLabel.map { "Undo \($0)" } ?? "Undo") { store.undo() }
				.disabled(!store.canUndo)
				.opacity(store.canUndo ? 1 : 0.4)
			Button {
				showPolish.toggle()
			} label: {
				HStack(spacing: 7) {
					if store.isPolishing {
						ProgressView().controlSize(.mini).tint(Theme.lavender)
					} else {
						Image(systemName: "sparkles")
					}
					Text("Polish")
				}
			}
			.buttonStyle(NebulaButtonStyle(.accent, height: 30))
			.popover(isPresented: $showPolish, arrowEdge: .bottom) { PolishPopover(store: store) { showPolish = false } }
			Button {
				app.showExportSheet = true
			} label: {
				HStack(spacing: 7) {
					Image(systemName: "square.and.arrow.up")
					Text("Export")
				}
			}
			.buttonStyle(NebulaButtonStyle(.primary, height: 30))
			.disabled(app.exports.isExporting)
		}
		.padding(.horizontal, 16)
		.frame(height: 52)
		.background(Theme.window)
		.overlay(alignment: .bottom) { Hairline() }
	}

	private func commitRename() {
		let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
		renaming = false
		guard !value.isEmpty, value != store.project.name else { return }
		store.apply("Rename") { $0.name = value }
		app.refreshLibrary()
	}
}

private struct SaveIndicator: View {
	let store: ProjectStore

	var body: some View {
		HStack(spacing: 5) {
			Circle().fill(store.saveError == nil ? Theme.success : Theme.recording).frame(width: 6, height: 6)
			Text(store.saveError == nil ? (store.lastSaved == nil ? "Saved" : "Saved") : "Not saved")
				.font(.nebula(12, 600))
				.foregroundStyle(Theme.text3)
		}
		.help(store.saveError ?? "Changes save automatically")
	}
}

/// Shows that an MCP client (Claude) can edit this project.
private struct AssistantPill: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		if app.mcp.isRunning {
			let connected = app.mcp.callCount > 0
			HStack(spacing: 6) {
				Circle().fill(connected ? Theme.lavender : Theme.text3).frame(width: 6, height: 6)
				Text(connected ? "Claude connected" : "MCP ready").font(.nebula(12, 650))
			}
			.foregroundStyle(connected ? Theme.lavender : Theme.text3)
			.padding(.horizontal, 11)
			.frame(height: 28)
			.background(Capsule().fill(connected ? Theme.violetSoft : Theme.surface1))
			.overlay(Capsule().strokeBorder(connected ? Theme.violetLine.opacity(0.6) : Theme.hairlineStrong))
			.help(app.mcp.lastCall.map { "Last tool call: \($0)" } ?? app.mcp.url)
		}
	}
}

// MARK: - Polish

private struct PolishPopover: View {
	let store: ProjectStore
	let close: () -> Void
	@Environment(AppModel.self) private var app

	var body: some View {
		@Bindable var settings = app.settings
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Polish").font(.nebula(15, 750)).foregroundStyle(Theme.text1)
				Text("Reads your clicks, typing, pauses and voice, then edits the recording. Each run is one undo step.")
					.font(.nebula(12, 550)).foregroundStyle(Theme.text2)
					.fixedSize(horizontal: false, vertical: true)
			}
			VStack(spacing: 12) {
				InspectorToggle("Zoom in on clicks and typing", isOn: $settings.polishOptions.autoZoom)
				InspectorToggle("Cut pauses and dead air", isOn: $settings.polishOptions.cutDeadAir)
				InspectorToggle("Speed up long typing", isOn: $settings.polishOptions.speedUpTyping)
				InspectorToggle("Trim start and end", isOn: $settings.polishOptions.trimEnds)
				InspectorToggle("Smooth the cursor", isOn: $settings.polishOptions.polishCursor)
			}
			NebulaSlider("Strongest zoom", value: $settings.polishOptions.maxZoom, in: 1.2...3) { String(format: "%.1f×", $0) }
			Hairline()
			HStack {
				if store.project.zooms.contains(where: { $0.source == .polish }) || store.project.cuts.contains(where: { $0.source == .polish }) {
					Text("Replaces the previous Polish edits; your own edits stay.")
						.font(.nebula(11, 550)).foregroundStyle(Theme.text3)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer()
				Button {
					close()
					Task {
						do {
							let plan = try await store.polish(options: app.settings.polishOptions)
							app.toasts.show("Polished", detail: plan.summary, showsUndo: true)
						} catch {
							app.toasts.show("Polish failed", detail: error.localizedDescription)
						}
					}
				} label: {
					Label("Polish", systemImage: "sparkles")
				}
				.buttonStyle(NebulaButtonStyle(.primary, height: 32))
				.keyboardShortcut(.defaultAction)
				.disabled(store.isPolishing)
			}
		}
		.padding(18)
		.frame(width: 320)
		.background(Theme.surface1)
	}
}

// MARK: - Quick export

/// Shown once after a recording: polish and export in one click, or copy straight away.
private struct QuickExportCard: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app
	@State private var working: String?

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
			VStack(alignment: .leading, spacing: 1) {
				Text("Recording saved").font(.nebula(13, 700)).foregroundStyle(Theme.text1)
				Text(working ?? "\(Format.time(store.project.media.duration, tenths: false)) · ready to edit")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
			}
			Spacer(minLength: 16)
			Button {
				run("Polishing and exporting…") {
					_ = try await store.polish(options: app.settings.polishOptions)
					try await app.exports.export(store)
				}
			} label: { Label("Polish & export", systemImage: "sparkles") }
			.buttonStyle(NebulaButtonStyle(.accent, height: 30))
			Button {
				run("Copying…") { await app.exports.copyVideo(store) }
			} label: { Label("Copy", systemImage: "doc.on.doc") }
			.buttonStyle(NebulaButtonStyle(.secondary, height: 30))
			IconButton("xmark", help: "Dismiss") { app.exports.quickExportURL = nil }
		}
		.disabled(working != nil)
		.padding(.leading, 14)
		.padding(.trailing, 6)
		.frame(height: 52)
		.frame(maxWidth: 560)
		.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2))
		.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairlineStrong))
		.shadow(color: .black.opacity(0.5), radius: 18, y: 10)
		.task {
			try? await Task.sleep(for: .seconds(20))
			if working == nil, app.exports.quickExportURL == store.bundle.url { app.exports.quickExportURL = nil }
		}
	}

	private func run(_ message: String, _ work: @escaping () async throws -> Void) {
		working = message
		Task {
			do { try await work() } catch { app.toasts.show("Couldn't finish", detail: error.localizedDescription) }
			working = nil
			app.exports.quickExportURL = nil
		}
	}
}

// MARK: - Toasts

struct ToastView: View {
	let toasts: ToastCenter
	let undo: () -> Void

	var body: some View {
		ZStack {
			if let toast = toasts.current {
				HStack(spacing: 10) {
					if toast.isAssistant {
						Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lavender)
					}
					VStack(alignment: .leading, spacing: 1) {
						Text(toast.title).font(.nebula(12.5, 700)).foregroundStyle(Theme.text1).lineLimit(1)
						if let detail = toast.detail {
							Text(detail).font(.nebula(11.5, 550)).foregroundStyle(Theme.text2).lineLimit(2)
						}
					}
					if toast.showsUndo {
						Button("Undo") {
							undo()
							toasts.dismiss()
						}
						.buttonStyle(NebulaButtonStyle(.ghost, height: 26))
					}
				}
				.padding(.leading, 14)
				.padding(.trailing, toast.showsUndo ? 6 : 14)
				.padding(.vertical, 8)
				.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
				.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairlineStrong))
				.shadow(color: .black.opacity(0.5), radius: 18, y: 10)
				.frame(maxWidth: 480)
				.transition(.move(edge: .bottom).combined(with: .opacity))
				.id(toast.id)
			}
		}
		.animation(Theme.smooth, value: toasts.current)
	}
}

// MARK: - Keyboard

/// Single-key editing shortcuts (Space, Z, C, …). Ignored while a text field is being edited.
private struct EditorKeyHandler: NSViewRepresentable {
	let store: ProjectStore

	func makeNSView(context: Context) -> KeyView {
		let view = KeyView()
		view.store = store
		return view
	}

	func updateNSView(_ nsView: KeyView, context: Context) {
		nsView.store = store
	}

	final class KeyView: NSView {
		weak var store: ProjectStore?
		private var monitor: Any?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				let handled = MainActor.assumeIsolated {
					guard let self, let window = self.window, event.window === window else { return false }
					return self.handle(event)
				}
				return handled ? nil : event
			}
		}

		override func removeFromSuperview() {
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
			super.removeFromSuperview()
		}

		private func handle(_ event: NSEvent) -> Bool {
			guard let store else { return false }
			if window?.firstResponder is NSText { return false }
			if window?.attachedSheet != nil { return false }
			let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
			guard flags.isEmpty || flags == .shift else { return false }
			switch event.keyCode {
			case 49: store.preview.togglePlay() // space
			case 51, 117: // delete, forward delete
				if let clip = store.selectedClip, store.selection.isEmpty { store.deleteClip(clip) } else { store.delete(store.selection) }
			case 123: store.preview.step(frames: flags == .shift ? -60 : -1) // left
			case 124: store.preview.step(frames: flags == .shift ? 60 : 1) // right
			case 115: store.preview.seek(to: 0) // home
			case 119: store.preview.seek(to: store.preview.duration) // end
			case 53: // escape
				guard !store.selection.isEmpty || store.selectedClipTime != nil else { return false }
				store.selection = []
				store.selectClip(nil)
			default:
				guard flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
				switch key {
				case "z": store.addZoom()
				case "c", "b": store.splitAtPlayhead()
				case "s": store.addSpeed()
				case "m": store.addMask()
				case "t": store.addText()
				case "a": store.addArrow()
				case "k": store.preview.togglePlay()
				case "j": store.preview.step(frames: -60)
				case "l": store.preview.step(frames: 60)
				default: return false
				}
			}
			return true
		}
	}
}
