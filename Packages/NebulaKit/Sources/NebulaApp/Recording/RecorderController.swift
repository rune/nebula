import AppKit
import Foundation
import NebulaCapture
import NebulaCore
import Observation
import os

/// The recording flow: picker → countdown → recording (pause/restart/discard) → finish.
@MainActor
@Observable
public final class RecorderController {
	public enum Phase: Equatable {
		case idle
		case choosing
		case countdown(Int)
		case recording
		case paused
		case finishing
	}

	public enum Mode: String, CaseIterable {
		case display, window, area

		public var title: String { rawValue.capitalized }

		public var symbol: String {
			switch self {
			case .display: "display"
			case .window: "macwindow"
			case .area: "viewfinder"
			}
		}
	}

	public private(set) var phase: Phase = .idle
	public var mode: Mode = .display
	public private(set) var displays: [DisplayInfo] = []
	public private(set) var windows: [WindowInfo] = []
	public private(set) var microphones: [MicrophoneInfo] = []
	public var displayID: CGDirectDisplayID?
	public var windowID: CGWindowID?
	/// Area in the chosen display's points (top-left origin).
	public var area: CGRect?
	public private(set) var elapsed: Double = 0
	public private(set) var errorMessage: String?
	/// Set when an MCP client started the recording, so its result can be reported back.
	public private(set) var startedByAssistant = false

	@ObservationIgnored private let recorder = ScreenRecorder()
	@ObservationIgnored private var bundle: ProjectBundle?
	@ObservationIgnored private var ticker: Timer?
	@ObservationIgnored private var countdownTask: Task<Void, Never>?
	@ObservationIgnored weak var app: AppModel?
	@ObservationIgnored private var finishContinuation: CheckedContinuation<ProjectBundle?, Never>?
	/// Capture is starting (after the countdown, before the first frame).
	@ObservationIgnored private var starting = false
	/// Stop was pressed while starting; finish as soon as capture is running.
	@ObservationIgnored private var stopRequested = false
	/// Cancel was pressed while starting; throw the recording away once it's running.
	@ObservationIgnored private var discardRequested = false
	private static let logger = Logger(subsystem: "app.nebula", category: "recorder")

	public var isRecording: Bool { phase == .recording || phase == .paused }

	init() {
		recorder.onFailure = { [weak self] error in
			self?.errorMessage = error.localizedDescription
			Task { await self?.finish() }
		}
	}

	// MARK: Picker

	public func showPicker() {
		guard phase == .idle else { return }
		errorMessage = nil
		phase = .choosing
		Task {
			await refreshSources()
			await askForMicrophoneIfNeeded()
		}
	}

	/// Asks for microphone access while the bar is up, not after the countdown.
	private func askForMicrophoneIfNeeded() async {
		guard let settings = app?.settings, settings.microphoneID != nil, Permissions.microphone == .notDetermined else { return }
		if !(await Permissions.requestMicrophone()) { settings.microphoneID = nil }
	}

	public func cancelPicker() {
		if starting {
			discardRequested = true
			return
		}
		countdownTask?.cancel()
		if phase == .choosing || { if case .countdown = phase { return true } else { return false } }() {
			phase = .idle
		}
	}

	public func refreshSources() async {
		if Permissions.screenRecording != .granted { Permissions.requestScreenRecording() }
		displays = (try? await CaptureSources.displays()) ?? []
		windows = (try? await CaptureSources.windows()) ?? []
		microphones = CaptureSources.microphones()
		if displayID == nil || !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id }
		if let windowID, !windows.contains(where: { $0.id == windowID }) { self.windowID = nil }
		if let settings = app?.settings, let mic = settings.microphoneID, !microphones.contains(where: { $0.id == mic }) {
			settings.microphoneID = CaptureSources.defaultMicrophone?.id
		}
	}

	public var source: RecordingSource? {
		switch mode {
		case .display: displayID.map { .display($0) }
		case .window: windowID.map { .window($0) }
		case .area:
			if let displayID, let area, area.width >= 64, area.height >= 64 { .area(displayID, area) } else { nil }
		}
	}

	// MARK: Recording

	/// Starts after the countdown. `assistant` marks MCP-initiated recordings.
	public func start(assistant: Bool = false) {
		guard let source, phase == .choosing || phase == .idle else {
			errorMessage = mode == .area ? "Drag to select an area first." : mode == .window ? "Choose a window to record." : "Choose a display."
			return
		}
		startedByAssistant = assistant
		let seconds = app?.settings.countdown ?? 3
		countdownTask = Task { [weak self] in
			guard let self else { return }
			for remaining in stride(from: seconds, to: 0, by: -1) {
				self.phase = .countdown(remaining)
				try? await Task.sleep(for: .seconds(1))
				if Task.isCancelled { return }
			}
			if seconds <= 0 {
				// Let the control pill appear before capture starts, so it is left out of the recording.
				self.phase = .countdown(0)
				try? await Task.sleep(for: .milliseconds(150))
				if Task.isCancelled { return }
			}
			await self.beginCapture(source: source)
		}
	}

	private func beginCapture(source: RecordingSource) async {
		guard let app else { return }
		starting = true
		stopRequested = false
		discardRequested = false
		defer { starting = false }
		do {
			if app.settings.microphoneID != nil, Permissions.microphone != .granted {
				// Normally asked when the bar opened; denied or missing means no microphone.
				if Permissions.microphone == .notDetermined, await Permissions.requestMicrophone() {} else { app.settings.microphoneID = nil }
			}
			let bundle = try app.library.newBundle()
			self.bundle = bundle
			let options = RecordingOptions(
				source: source,
				microphoneID: app.settings.microphoneID,
				systemAudio: app.settings.systemAudio,
				hideDesktopIcons: app.settings.hideDesktopIcons,
				frameRate: app.settings.frameRate
			)
			try await recorder.start(
				options: options,
				videoURL: bundle.url.appending(path: ProjectBundle.videoFileName),
				microphoneURL: bundle.url.appending(path: ProjectBundle.microphoneFileName)
			)
			phase = .recording
			elapsed = 0
			ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated { self?.elapsed = self?.recorder.elapsed ?? 0 }
			}
			if discardRequested {
				discardRequested = false
				Task { await self.discard() }
			} else if stopRequested {
				stopRequested = false
				Task { await self.finish() }
			}
		} catch {
			errorMessage = error.localizedDescription
			phase = .choosing
			if let bundle { try? FileManager.default.removeItem(at: bundle.url) }
			bundle = nil
		}
	}

	public func togglePause() {
		switch phase {
		case .recording:
			recorder.pause()
			phase = .paused
		case .paused:
			recorder.resume()
			phase = .recording
		default:
			break
		}
	}

	public func discard() async {
		ticker?.invalidate()
		await recorder.cancel()
		if let bundle { try? FileManager.default.removeItem(at: bundle.url) }
		bundle = nil
		phase = .idle
		finishContinuation?.resume(returning: nil)
		finishContinuation = nil
	}

	public func restart() async {
		await discard()
		phase = .choosing
		start(assistant: startedByAssistant)
	}

	/// Stops, builds the project and opens it in the editor.
	@discardableResult
	public func finish() async -> ProjectBundle? {
		if starting {
			stopRequested = true
			return await waitForFinish()
		}
		if case .countdown = phase {
			cancelPicker()
			return nil
		}
		guard isRecording, let bundle else { return nil }
		phase = .finishing
		ticker?.invalidate()
		defer {
			self.bundle = nil
			phase = .idle
		}
		do {
			let result = try await recorder.stop()
			try await app?.createProject(from: result, in: bundle)
			finishContinuation?.resume(returning: bundle)
			finishContinuation = nil
			return bundle
		} catch {
			errorMessage = error.localizedDescription
			Self.logger.error("Finishing failed: \(error.localizedDescription, privacy: .public)")
			finishContinuation?.resume(returning: nil)
			finishContinuation = nil
			return nil
		}
	}

	/// For MCP: waits until the current recording finishes (by the user or a stop call).
	func waitForFinish() async -> ProjectBundle? {
		await withCheckedContinuation { finishContinuation = $0 }
	}
}
