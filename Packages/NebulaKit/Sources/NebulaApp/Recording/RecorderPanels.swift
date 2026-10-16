import AppKit
import NebulaCapture
import NebulaDesign
import Observation
import SwiftUI

/// The floating windows of the recording flow: source bar, selection overlay, countdown, the
/// control pill and speaker notes. They follow `RecorderController.phase`.
///
/// Nebula's own windows are left out of recordings, so these can stay on screen while recording.
@MainActor
final class RecorderPanels {
	private let app: AppModel
	private var bar: KeyablePanel?
	private var overlay: NSPanel?
	private var countdown: NSPanel?
	private var control: NSPanel?
	private var notes: NSPanel?
	private var hiddenWindows: [NSWindow] = []

	init(app: AppModel) {
		self.app = app
		observe()
	}

	private func observe() {
		withObservationTracking {
			let recorder = app.recorder
			_ = (recorder.phase, recorder.mode, recorder.displayID, recorder.windowID, recorder.area, recorder.displays.count)
			_ = app.settings.speakerNotes
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.sync()
				self?.observe()
			}
		}
	}

	private var recorder: RecorderController { app.recorder }

	private func sync() {
		switch recorder.phase {
		case .idle:
			[bar, overlay, countdown, control, notes].forEach { $0?.orderOut(nil) }
			restoreWindows()
		case .choosing:
			hideAppWindows()
			showBar()
			showOverlay(interactive: recorder.mode == .area)
			countdown?.orderOut(nil)
			control?.orderOut(nil)
			notes?.orderOut(nil)
		case .countdown:
			bar?.orderOut(nil)
			showOverlay(interactive: false)
			showCountdown()
			// Shown before capture starts so they are left out of the recording.
			showControl()
			if app.settings.speakerNotes { showNotes() }
		case .recording, .paused, .finishing:
			bar?.orderOut(nil)
			countdown?.orderOut(nil)
			showOverlay(interactive: false)
			showControl()
			if app.settings.speakerNotes { showNotes() } else { notes?.orderOut(nil) }
		}
	}

	// MARK: App windows

	private func hideAppWindows() {
		for window in NSApp.windows where window.isVisible && !(window is NSPanel) && window.styleMask.contains(.titled) {
			hiddenWindows.append(window)
			window.orderOut(nil)
		}
	}

	private func restoreWindows() {
		for window in hiddenWindows where app.recorder.phase == .idle {
			window.orderFront(nil)
		}
		hiddenWindows.removeAll()
	}

	// MARK: Panels

	private func makePanel(level: NSWindow.Level, interactive: Bool = true) -> KeyablePanel {
		let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
		panel.level = level
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = false
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
		panel.ignoresMouseEvents = !interactive
		return panel
	}

	private func host<V: View>(_ view: V) -> NSHostingView<some View> {
		let hosting = NSHostingView(rootView: view.environment(app).environment(\.colorScheme, .dark))
		hosting.sizingOptions = []
		return hosting
	}

	private var targetScreen: NSScreen {
		let id: CGDirectDisplayID? = switch recorder.mode {
		case .window: windowDisplay?.id ?? recorder.displayID
		default: recorder.displayID
		}
		return id.flatMap(Self.screen(for:)) ?? NSScreen.main ?? NSScreen.screens[0]
	}

	private var windowDisplay: DisplayInfo? {
		guard let id = recorder.windowID, let window = recorder.windows.first(where: { $0.id == id }) else { return nil }
		let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
		return recorder.displays.first { $0.frame.contains(center) } ?? recorder.displays.first
	}

	static func screen(for id: CGDirectDisplayID) -> NSScreen? {
		NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
	}

	private func showBar() {
		let panel = bar ?? makePanel(level: .popUpMenu)
		if bar == nil {
			panel.contentView = host(RecorderBar())
			bar = panel
		}
		let size = NSSize(width: 760, height: 76)
		let frame = targetScreen.visibleFrame
		panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 36, width: size.width, height: size.height), display: true)
		panel.orderFrontRegardless()
		panel.makeKey()
	}

	private func showOverlay(interactive: Bool) {
		let panel = overlay ?? makePanel(level: .statusBar)
		if overlay == nil {
			panel.contentView = host(SelectionOverlay())
			overlay = panel
		}
		panel.ignoresMouseEvents = !interactive
		panel.setFrame(targetScreen.frame, display: true)
		panel.orderFrontRegardless()
	}

	private func showCountdown() {
		let panel = countdown ?? makePanel(level: .popUpMenu, interactive: false)
		if countdown == nil {
			panel.contentView = host(CountdownView())
			countdown = panel
		}
		let frame = targetScreen.frame
		panel.setFrame(NSRect(x: frame.midX - 90, y: frame.midY - 90, width: 180, height: 180), display: true)
		panel.orderFrontRegardless()
	}

	private func showControl() {
		let panel = control ?? makePanel(level: .popUpMenu)
		if control == nil {
			panel.contentView = host(RecordingControl())
			panel.isMovableByWindowBackground = true
			control = panel
			let size = NSSize(width: 330, height: 60)
			let frame = targetScreen.visibleFrame
			panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 30, width: size.width, height: size.height), display: true)
		}
		panel.orderFrontRegardless()
	}

	private func showNotes() {
		let panel = notes ?? makePanel(level: .floating)
		if notes == nil {
			panel.contentView = host(SpeakerNotesView())
			panel.isMovableByWindowBackground = true
			notes = panel
			let frame = targetScreen.visibleFrame
			panel.setFrame(NSRect(x: frame.maxX - 380, y: frame.maxY - 300, width: 360, height: 280), display: true)
		}
		panel.orderFrontRegardless()
	}
}

// MARK: - Source bar

private struct RecorderBar: View {
	@Environment(AppModel.self) private var app
	@State private var showOptions = false

	var body: some View {
		let recorder = app.recorder
		@Bindable var settings = app.settings
		HStack(spacing: 10) {
			IconButton("xmark", help: "Cancel (Esc)") { recorder.cancelPicker() }
				.keyboardShortcut(.cancelAction)
			HStack(spacing: 2) {
				ForEach(RecorderController.Mode.allCases, id: \.self) { mode in
					ModeButton(mode: mode, selected: recorder.mode == mode) { recorder.mode = mode }
				}
			}
			.padding(3)
			.background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface2))
			Divider().frame(height: 34).overlay(Theme.hairline)
			SourceMenu()
			MicrophoneMenu()
			IconButton(settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash", help: settings.systemAudio ? "Recording system audio" : "System audio off", isOn: settings.systemAudio) {
				settings.systemAudio.toggle()
			}
			IconButton("ellipsis", help: "Options") { showOptions.toggle() }
				.popover(isPresented: $showOptions, arrowEdge: .top) { RecordingOptionsView().environment(app) }
			Spacer(minLength: 0)
			Button {
				recorder.start()
			} label: {
				HStack(spacing: 9) {
					Circle().fill(.white).frame(width: 12, height: 12)
					Text("Record")
					Text("↩").font(.nebula(11, 700)).opacity(0.7)
				}
			}
			.buttonStyle(NebulaButtonStyle(.primary, height: 44))
			.keyboardShortcut(.defaultAction)
			.disabled(recorder.source == nil)
		}
		.padding(.horizontal, 12)
		.frame(height: 66)
		.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface1))
		.overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairlineStrong))
		.overlay(alignment: .top) {
			if let error = recorder.errorMessage {
				Text(error)
					.font(.nebula(12, 650))
					.foregroundStyle(Color(hex: 0xFF8FA3))
					.padding(.horizontal, 12).padding(.vertical, 6)
					.background(Capsule().fill(Theme.surface2))
					.offset(y: -34)
			}
		}
		.padding(5)
	}
}

private struct ModeButton: View {
	let mode: RecorderController.Mode
	let selected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Image(systemName: mode.symbol).font(.system(size: 14))
				Text(mode.title).font(.nebula(11, 650))
			}
			.foregroundStyle(selected ? Theme.text1 : Theme.text3)
			.frame(width: 64, height: 46)
			.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.surface3 : .clear))
			.overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Theme.hairlineStrong : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

/// Labelled two-line menu used for the display/window and microphone choices.
private struct BarMenu<Content: View>: View {
	let caption: String
	let title: String
	@ViewBuilder let content: Content

	var body: some View {
		Menu {
			content
		} label: {
			VStack(alignment: .leading, spacing: 2) {
				Text(caption.uppercased()).font(.nebula(9.5, 750)).tracking(0.6).foregroundStyle(Theme.text3)
				HStack(spacing: 5) {
					Text(title).font(.nebula(12.5, 650)).foregroundStyle(Theme.text1).lineLimit(1)
					Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
				}
			}
			.padding(.horizontal, 12)
			.frame(width: 170, height: 46, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
			.contentShape(Rectangle())
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
	}
}

private struct SourceMenu: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		let recorder = app.recorder
		if recorder.mode == .window {
			BarMenu(caption: "Window", title: recorder.windows.first { $0.id == recorder.windowID }.map { "\($0.appName) — \($0.title)" } ?? "Choose a window") {
				ForEach(Dictionary(grouping: recorder.windows, by: \.appName).sorted { $0.key < $1.key }, id: \.key) { appName, windows in
					Section(appName) {
						ForEach(windows) { window in
							Button(window.title) { recorder.windowID = window.id }
						}
					}
				}
				Divider()
				Button("Refresh") { Task { await recorder.refreshSources() } }
			}
		} else {
			BarMenu(caption: "Display", title: recorder.displays.first { $0.id == recorder.displayID }?.name ?? "Display") {
				ForEach(recorder.displays) { display in
					Button(String("\(display.name) — \(Int(display.frame.width)) × \(Int(display.frame.height))")) {
						recorder.displayID = display.id
						if recorder.mode == .area { recorder.area = nil }
					}
				}
			}
		}
	}
}

private struct MicrophoneMenu: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		let settings = app.settings
		BarMenu(caption: "Microphone", title: app.recorder.microphones.first { $0.id == settings.microphoneID }?.name ?? "No microphone") {
			Button("No microphone") { settings.microphoneID = nil }
			Divider()
			ForEach(app.recorder.microphones) { mic in
				Button(mic.name) { settings.microphoneID = mic.id }
			}
		}
	}
}

private struct RecordingOptionsView: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		@Bindable var settings = app.settings
		VStack(alignment: .leading, spacing: 14) {
			InspectorRow(title: "Countdown") {
				SegmentedPicker(selection: $settings.countdown, options: [(0, "Off"), (3, "3 s"), (5, "5 s")]).frame(width: 150)
			}
			InspectorToggle("Hide desktop icons", isOn: $settings.hideDesktopIcons)
			InspectorToggle("Speaker notes", isOn: $settings.speakerNotes)
			Hairline()
			InspectorRow(title: "Frame rate") {
				SegmentedPicker(selection: $settings.frameRate, options: [(30, "30"), (60, "60")]).frame(width: 110)
			}
			if Permissions.accessibility != .granted {
				Hairline()
				VStack(alignment: .leading, spacing: 6) {
					Text("Allow Accessibility so Polish can see clicks and text fields.")
						.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
						.fixedSize(horizontal: false, vertical: true)
					Button("Allow…") { Permissions.requestAccessibility() }.buttonStyle(NebulaButtonStyle(.secondary, height: 26))
				}
			}
		}
		.padding(16)
		.frame(width: 300)
		.background(Theme.surface1)
	}
}

// MARK: - Selection overlay

/// Draws what will be recorded. In area mode, drag to draw the area, drag inside to move it and
/// drag the handles to resize.
private struct SelectionOverlay: View {
	@Environment(AppModel.self) private var app
	@State private var dragStart: CGRect?
	@State private var drawOrigin: CGPoint?

	var body: some View {
		let recorder = app.recorder
		GeometryReader { proxy in
			ZStack(alignment: .topLeading) {
				if let rect = highlight(in: proxy.size) {
					let choosing = recorder.phase == .choosing
					if choosing {
						Path { path in
							path.addRect(CGRect(origin: .zero, size: proxy.size))
							path.addRect(rect)
						}
						.fill(Color.black.opacity(recorder.mode == .area ? 0.45 : 0.25), style: FillStyle(eoFill: true))
					}
					Rectangle()
						.strokeBorder(Theme.violet, style: StrokeStyle(lineWidth: choosing ? 2 : 1.5, dash: choosing ? [] : [8, 6]))
						.frame(width: rect.width, height: rect.height)
						.offset(x: rect.minX, y: rect.minY)
						.allowsHitTesting(false)
					if choosing {
						Text(verbatim: "\(Int(rect.width)) × \(Int(rect.height))")
							.font(.nebula(12, 700))
							.monospacedDigit()
							.foregroundStyle(Theme.text1)
							.padding(.horizontal, 9).padding(.vertical, 5)
							.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface1))
							.offset(x: rect.midX - 50, y: max(8, rect.minY - 34))
							.frame(width: 100)
							.allowsHitTesting(false)
					}
					if choosing && recorder.mode == .area {
						Color.clear
							.frame(width: rect.width, height: rect.height)
							.contentShape(Rectangle())
							.offset(x: rect.minX, y: rect.minY)
							.gesture(moveGesture(rect, bounds: proxy.size))
						ForEach(0..<4, id: \.self) { corner in
							handle(corner, rect: rect, bounds: proxy.size)
						}
					}
				} else if recorder.mode == .area && recorder.phase == .choosing {
					Color.black.opacity(0.45)
					Text("Drag to choose the area to record")
						.font(.nebula(15, 700))
						.foregroundStyle(Theme.text1)
						.padding(.horizontal, 16).padding(.vertical, 10)
						.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface1))
						.position(x: proxy.size.width / 2, y: proxy.size.height / 2)
				}
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
			.contentShape(Rectangle())
			.gesture(drawGesture(bounds: proxy.size), including: recorder.mode == .area && recorder.phase == .choosing ? .all : .subviews)
		}
		.ignoresSafeArea()
	}

	/// The rectangle to outline, in this screen's top-left points.
	private func highlight(in size: CGSize) -> CGRect? {
		let recorder = app.recorder
		switch recorder.mode {
		case .display:
			return recorder.phase == .choosing ? CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1) : nil
		case .area:
			return recorder.area
		case .window:
			guard let id = recorder.windowID, let window = recorder.windows.first(where: { $0.id == id }) else { return nil }
			let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
			guard let display = recorder.displays.first(where: { $0.frame.contains(center) }) else { return nil }
			return window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
		}
	}

	private func drawGesture(bounds: CGSize) -> some Gesture {
		DragGesture(minimumDistance: 3)
			.onChanged { drag in
				let origin = drawOrigin ?? drag.startLocation
				drawOrigin = origin
				let rect = CGRect(
					x: min(origin.x, drag.location.x), y: min(origin.y, drag.location.y),
					width: abs(drag.location.x - origin.x), height: abs(drag.location.y - origin.y)
				)
				app.recorder.area = rect.intersection(CGRect(origin: .zero, size: bounds)).integral
			}
			.onEnded { _ in drawOrigin = nil }
	}

	private func moveGesture(_ rect: CGRect, bounds: CGSize) -> some Gesture {
		DragGesture(minimumDistance: 1)
			.onChanged { drag in
				let start = dragStart ?? rect
				dragStart = start
				var moved = start.offsetBy(dx: drag.translation.width, dy: drag.translation.height)
				moved.origin.x = moved.origin.x.clamped(to: 0...(bounds.width - moved.width))
				moved.origin.y = moved.origin.y.clamped(to: 0...(bounds.height - moved.height))
				app.recorder.area = moved.integral
			}
			.onEnded { _ in dragStart = nil }
	}

	private func handle(_ corner: Int, rect: CGRect, bounds: CGSize) -> some View {
		let left = corner % 2 == 0
		let top = corner < 2
		return RoundedRectangle(cornerRadius: 3, style: .continuous)
			.fill(.white)
			.overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.violet, lineWidth: 1.5))
			.frame(width: 12, height: 12)
			.frame(width: 28, height: 28)
			.contentShape(Rectangle())
			.position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
			.gesture(DragGesture(minimumDistance: 1)
				.onChanged { drag in
					let start = dragStart ?? rect
					dragStart = start
					var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
					if left { minX = (minX + drag.translation.width).clamped(to: 0...(maxX - 64)) } else { maxX = (maxX + drag.translation.width).clamped(to: (minX + 64)...bounds.width) }
					if top { minY = (minY + drag.translation.height).clamped(to: 0...(maxY - 64)) } else { maxY = (maxY + drag.translation.height).clamped(to: (minY + 64)...bounds.height) }
					app.recorder.area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
				}
				.onEnded { _ in dragStart = nil })
	}
}

// MARK: - Countdown

private struct CountdownView: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		ZStack {
			if case .countdown(let value) = app.recorder.phase, value > 0 {
				RoundedRectangle(cornerRadius: 36, style: .continuous)
					.fill(Theme.surface1.opacity(0.94))
					.overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(Theme.hairlineStrong))
				Text("\(value)")
					.font(.nebula(84, 800))
					.monospacedDigit()
					.foregroundStyle(Theme.text1)
					.contentTransition(.numericText(countsDown: true))
					.animation(Theme.snappy, value: value)
			}
		}
		.frame(width: 160, height: 160)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

// MARK: - Control pill

private struct RecordingControl: View {
	@Environment(AppModel.self) private var app
	@State private var confirmDiscard = false

	var body: some View {
		let recorder = app.recorder
		HStack(spacing: 6) {
			HStack(spacing: 8) {
				Circle()
					.fill(recorder.phase == .paused ? Theme.text3 : Theme.recording)
					.frame(width: 9, height: 9)
				Text(label(recorder))
					.font(.nebula(14, 700))
					.monospacedDigit()
					.foregroundStyle(Theme.text1)
					.frame(width: 64, alignment: .leading)
			}
			.padding(.leading, 12)
			IconButton(recorder.phase == .paused ? "play.fill" : "pause.fill", help: recorder.phase == .paused ? "Resume" : "Pause") { recorder.togglePause() }
				.disabled(!recorder.isRecording)
			IconButton("arrow.counterclockwise", help: "Restart") { Task { await recorder.restart() } }
				.disabled(!recorder.isRecording)
			IconButton("trash", help: "Discard") {
				if confirmDiscard {
					confirmDiscard = false
					Task { await recorder.discard() }
				} else {
					confirmDiscard = true
				}
			}
			.overlay(alignment: .top) {
				if confirmDiscard {
					Text("Click again to discard")
						.font(.nebula(11, 650)).foregroundStyle(Color(hex: 0xFF8FA3))
						.fixedSize()
						.offset(y: -22)
				}
			}
			.disabled(!recorder.isRecording && recorder.phase != .finishing)
			Button {
				if case .countdown = recorder.phase {
					recorder.cancelPicker()
				} else {
					Task { await recorder.finish() }
				}
			} label: {
				HStack(spacing: 6) {
					RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
					Text(isCountdown(recorder) ? "Cancel" : "Stop")
				}
			}
			.buttonStyle(NebulaButtonStyle(.primary, height: 34))
			.disabled(recorder.phase == .finishing)
			.padding(.trailing, 6)
		}
		.frame(height: 50)
		.background(Capsule().fill(Theme.surface1))
		.overlay(Capsule().strokeBorder(Theme.hairlineStrong))
		.padding(5)
		.task(id: confirmDiscard) {
			guard confirmDiscard else { return }
			try? await Task.sleep(for: .seconds(3))
			confirmDiscard = false
		}
	}

	private func isCountdown(_ recorder: RecorderController) -> Bool {
		if case .countdown = recorder.phase { return true }
		return false
	}

	private func label(_ recorder: RecorderController) -> String {
		switch recorder.phase {
		case .countdown(let value): value > 0 ? "in \(value)…" : "Starting…"
		case .finishing: "Saving…"
		default: Format.time(recorder.elapsed, tenths: false)
		}
	}
}

// MARK: - Speaker notes

private struct SpeakerNotesView: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		@Bindable var settings = app.settings
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				SectionHeader("Speaker notes")
				Spacer()
				Text("Not recorded").font(.nebula(10.5, 650)).foregroundStyle(Theme.text3)
			}
			TextEditor(text: $settings.notesText)
				.font(.nebula(15, 600))
				.foregroundStyle(Theme.text1)
				.scrollContentBackground(.hidden)
				.background(Color.clear)
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface1.opacity(0.96)))
		.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairlineStrong))
		.padding(4)
	}
}
