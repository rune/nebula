import AVFoundation
import Foundation
import NebulaAudio
import NebulaCore
import NebulaPolish
import NebulaRender
import Observation
import os

/// Who made an edit. Assistant edits are announced with a toast.
public enum EditSource: Sendable, Equatable {
	case user
	case assistant
}

/// The single source of truth for one open project. Every change goes through `apply`, which
/// records undo, autosaves and refreshes the preview.
@MainActor
@Observable
public final class ProjectStore: Identifiable {
	public let id = UUID()
	public let bundle: ProjectBundle
	public private(set) var project: Project
	public private(set) var input: InputTrack
	public let preview = PreviewEngine()

	public var selection: Set<ItemID> = [] {
		didSet { if !selection.isEmpty { selectedClipTime = nil } }
	}
	/// A source time inside the selected clip. Clips are derived, so they're found by time.
	public var selectedClipTime: Double?
	public private(set) var lastSaved: Date?
	public private(set) var saveError: String?
	public private(set) var micWaveform: Waveform?
	public private(set) var systemWaveform: Waveform?
	public private(set) var speech: [TimeRange] = []
	public private(set) var isPolishing = false
	public private(set) var busyMessage: String?

	/// Short side of the preview render, set by the preview view from its size.
	public var previewShortSide: Int = 1080 {
		didSet { if previewShortSide != oldValue { refreshPreview() } }
	}

	/// Called after every edit: (label, source). The app shows toasts and notifies MCP clients.
	@ObservationIgnored public var onEdit: ((String, EditSource) -> Void)?

	@ObservationIgnored private var history = EditHistory()
	@ObservationIgnored private var saveTask: Task<Void, Never>?
	@ObservationIgnored private var sceneBuildInFlight = false
	@ObservationIgnored private var sceneDirty = false
	/// The last scene built, so the next edit can reuse its camera and cursor paths.
	@ObservationIgnored private var lastScene: RenderScene?
	@ObservationIgnored private var frameActivity: ActivitySeries?
	private static let logger = Logger(subsystem: "app.nebula", category: "project")

	public var canUndo: Bool { history.canUndo }
	public var canRedo: Bool { history.canRedo }
	public var undoLabel: String? { history.undoLabel }
	public var redoLabel: String? { history.redoLabel }
	public var timeMap: TimeMap { project.timeMap }
	public var videoURL: URL { bundle.videoURL(for: project) }

	public init(bundle: ProjectBundle) throws {
		self.bundle = bundle
		self.project = try bundle.readProject()
		self.input = bundle.readInput()
		refreshPreview()
		Task { await loadSignals() }
	}

	// MARK: - Editing

	/// Applies a change as one undoable step. `coalescing` merges rapid repeats (slider drags).
	public func apply(_ label: String, source: EditSource = .user, coalescing: String? = nil, _ change: (inout Project) -> Void) {
		var next = project
		change(&next)
		guard next != project else { return }
		history.record(previous: project, label: label, coalescingKey: coalescing)
		let timelineChanged = next.cuts != project.cuts || next.speeds != project.speeds
		project = next
		if timelineChanged { selection = selection.filter { id in item(id) != nil } }
		didChange(label: label, source: source)
	}

	public func undo() {
		guard let entry = history.undo(current: project) else { return }
		project = entry.project
		didChange(label: "Undo \(entry.label)", source: .user)
	}

	public func redo() {
		guard let entry = history.redo(current: project) else { return }
		project = entry.project
		didChange(label: "Redo \(entry.label)", source: .user)
	}

	private func didChange(label: String, source: EditSource) {
		refreshPreview()
		scheduleSave()
		onEdit?(label, source)
	}

	// MARK: - Preview

	public var media: CompositionBuilder.Media {
		var mic = bundle.microphoneURL(for: project)
		if project.audio.noiseReduction, FileManager.default.fileExists(atPath: bundle.denoisedMicrophoneURL.path) {
			mic = bundle.denoisedMicrophoneURL
		}
		let music = project.audio.music.map { bundle.mediaURL.appending(path: $0.file) }
		return CompositionBuilder.Media(video: videoURL, microphone: mic, music: music, speech: speech)
	}

	public func makeScene() -> RenderScene {
		RenderScene(project: project, input: input, bundleURL: bundle.url, reusing: lastScene)
	}

	/// Rebuilds the preview scene. Builds never overlap: edits arriving during a build (a drag
	/// sends dozens a second) collapse into one more build of the latest state.
	private func refreshPreview() {
		sceneDirty = true
		guard !sceneBuildInFlight else { return }
		sceneBuildInFlight = true
		Task { [weak self] in
			while let self, self.sceneDirty {
				self.sceneDirty = false
				let project = self.project
				let input = self.input
				let bundleURL = self.bundle.url
				let media = self.media
				let canvas = SceneLayout.canvasSize(for: project, shortSide: self.previewShortSide)
				let previous = self.lastScene
				// Camera and cursor paths are the costly part; keep them off the main thread, and
				// reuse them when the edit didn't touch them.
				let scene = await Task.detached(priority: .userInitiated) {
					RenderScene(project: project, input: input, bundleURL: bundleURL, reusing: previous)
				}.value
				self.lastScene = scene
				self.preview.update(scene: scene, media: media, canvas: canvas)
			}
			self?.sceneBuildInFlight = false
		}
	}

	// MARK: - Saving

	private func scheduleSave() {
		saveTask?.cancel()
		saveTask = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(600))
			guard !Task.isCancelled else { return }
			self?.saveNow()
		}
	}

	public func saveNow() {
		var snapshot = project
		snapshot.playhead = timeMap.sourceTime(forOutput: preview.currentTime)
		do {
			try bundle.write(snapshot)
			lastSaved = Date()
			saveError = nil
		} catch {
			saveError = error.localizedDescription
			Self.logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: - Signals

	private func loadSignals() async {
		if let mic = bundle.microphoneURL(for: project) {
			micWaveform = try? await WaveformBuilder.build(url: mic)
			speech = (try? await SpeechActivityDetector.detect(url: mic)) ?? []
			if !speech.isEmpty { refreshPreview() }
		}
		if project.media.hasSystemAudio {
			systemWaveform = try? await WaveformBuilder.build(url: videoURL)
		}
	}

	// MARK: - Polish

	/// Analyses the recording and applies Polish as one undoable edit. Returns a summary.
	@discardableResult
	public func polish(options: PolishOptions = PolishOptions(), source: EditSource = .user) async throws -> PolishPlanner.Plan {
		isPolishing = true
		busyMessage = "Reading the recording…"
		defer {
			isPolishing = false
			busyMessage = nil
		}
		if frameActivity == nil {
			frameActivity = try await FrameActivityAnalyzer.analyze(video: videoURL)
		}
		let signals = PolishSignals(frameActivity: frameActivity, speech: project.media.hasMicrophone ? speech : nil)
		let project = project
		let input = input
		let plan = await Task.detached(priority: .userInitiated) {
			PolishPlanner.plan(project: project, input: input, signals: signals, options: options)
		}.value
		apply("Polish: \(plan.summary)", source: source) { PolishPlanner.apply(plan, to: &$0, options: options) }
		return plan
	}

	// MARK: - Audio

	public func setNoiseReduction(_ enabled: Bool) async {
		if enabled, let mic = bundle.microphoneURL(for: project), !FileManager.default.fileExists(atPath: bundle.denoisedMicrophoneURL.path) {
			busyMessage = "Reducing noise…"
			defer { busyMessage = nil }
			try? FileManager.default.createDirectory(at: bundle.mediaURL, withIntermediateDirectories: true)
			do {
				try await NoiseReducer.process(input: mic, output: bundle.denoisedMicrophoneURL)
			} catch {
				saveError = error.localizedDescription
				return
			}
		}
		apply(enabled ? "Turn on noise reduction" : "Turn off noise reduction") { $0.audio.noiseReduction = enabled }
	}

	public func setMusic(from url: URL?) throws {
		guard let url else {
			apply("Remove music") { $0.audio.music = nil }
			return
		}
		let file = try bundle.importMedia(from: url)
		apply("Add music") { $0.audio.music = MusicTrack(file: file) }
	}

	public func setBackgroundImage(from url: URL) throws {
		let file = try bundle.importMedia(from: url)
		apply("Set background image") { $0.style.background = .image(path: "\(ProjectBundle.mediaFolderName)/\(file)") }
	}

	// MARK: - Items

	public enum ItemRef: Equatable {
		case zoom(ZoomItem)
		case cut(CutItem)
		case speed(SpeedItem)
		case mask(MaskItem)
		case annotation(AnnotationItem)
		case volume(VolumeItem)

		public var range: TimeRange {
			switch self {
			case .zoom(let item): item.range
			case .cut(let item): item.range
			case .speed(let item): item.range
			case .mask(let item): item.range
			case .annotation(let item): item.range
			case .volume(let item): item.range
			}
		}
	}

	public func item(_ id: ItemID) -> ItemRef? {
		if let item = project.zooms.first(where: { $0.id == id }) { return .zoom(item) }
		if let item = project.cuts.first(where: { $0.id == id }) { return .cut(item) }
		if let item = project.speeds.first(where: { $0.id == id }) { return .speed(item) }
		if let item = project.masks.first(where: { $0.id == id }) { return .mask(item) }
		if let item = project.annotations.first(where: { $0.id == id }) { return .annotation(item) }
		if let item = project.audio.volumes.first(where: { $0.id == id }) { return .volume(item) }
		return nil
	}

	/// Changes the time range of any item.
	public func setRange(_ id: ItemID, to range: TimeRange, label: String = "Move", coalescing: String? = nil) {
		let bounded = range.clamped(to: project.sourceRange)
		guard bounded.duration > 0.05 else { return }
		apply(label, coalescing: coalescing) { project in
			if let i = project.zooms.firstIndex(where: { $0.id == id }) { project.zooms[i].range = bounded; project.zooms[i].source = .user }
			if let i = project.cuts.firstIndex(where: { $0.id == id }) { project.cuts[i].range = bounded }
			if let i = project.speeds.firstIndex(where: { $0.id == id }) { project.speeds[i].range = bounded }
			if let i = project.masks.firstIndex(where: { $0.id == id }) { project.masks[i].range = bounded }
			if let i = project.annotations.firstIndex(where: { $0.id == id }) { project.annotations[i].range = bounded }
			if let i = project.audio.volumes.firstIndex(where: { $0.id == id }) { project.audio.volumes[i].range = bounded }
		}
	}

	public func delete(_ ids: Set<ItemID>) {
		guard !ids.isEmpty else { return }
		apply(ids.count == 1 ? "Delete" : "Delete \(ids.count) items") { project in
			project.zooms.removeAll { ids.contains($0.id) }
			project.cuts.removeAll { ids.contains($0.id) }
			project.speeds.removeAll { ids.contains($0.id) }
			project.masks.removeAll { ids.contains($0.id) }
			project.annotations.removeAll { ids.contains($0.id) }
			project.audio.volumes.removeAll { ids.contains($0.id) }
		}
		selection.subtract(ids)
	}

	/// Source time under the playhead.
	public var playheadSourceTime: Double { timeMap.sourceTime(forOutput: preview.currentTime) }

	/// A range of `length` source seconds starting at the playhead, kept inside the recording.
	public func rangeAtPlayhead(length: Double) -> TimeRange {
		let start = min(playheadSourceTime, max(0, project.media.duration - length))
		return TimeRange(start: start, end: min(project.media.duration, start + length))
	}

	public func addZoom() {
		let zoom = ZoomItem(range: rangeAtPlayhead(length: 2.5), target: .follow, scale: 1.8)
		apply("Add zoom") { $0.zooms.append(zoom) }
		selection = [zoom.id]
	}

	/// Speeds up the selected clip, or the clip under the playhead, to 2×.
	public func addSpeed() {
		guard let clip = selectedClip ?? project.clip(atSource: playheadSourceTime) else { return }
		setRate(clip.rate == 1 ? 2 : 1, for: clip)
	}

	public func addMask() {
		let item = MaskItem(range: rangeAtPlayhead(length: 3), rect: NormRect(x: 0.35, y: 0.4, width: 0.3, height: 0.12))
		apply("Add blur") { $0.masks.append(item) }
		selection = [item.id]
	}

	public func addText() {
		let item = AnnotationItem(range: rangeAtPlayhead(length: 3), kind: .text(TextAnnotation(text: "Label", position: NormPoint(x: 0.5, y: 0.2))))
		apply("Add text") { $0.annotations.append(item) }
		selection = [item.id]
	}

	public func addArrow() {
		let item = AnnotationItem(range: rangeAtPlayhead(length: 3), kind: .arrow(ArrowAnnotation(from: NormPoint(x: 0.4, y: 0.4), to: NormPoint(x: 0.55, y: 0.55))))
		apply("Add arrow") { $0.annotations.append(item) }
		selection = [item.id]
	}

	// MARK: - Clips

	public var selectedClip: Clip? {
		selectedClipTime.flatMap { project.clip(atSource: $0) }
	}

	public func selectClip(_ clip: Clip?) {
		guard let clip else {
			selectedClipTime = nil
			return
		}
		selection = []
		selectedClipTime = clip.source.start + min(0.01, clip.source.duration / 2)
	}

	/// Splits the clip under the playhead (like a blade tool).
	public func splitAtPlayhead() {
		let time = playheadSourceTime
		apply("Split") { $0.split(atSource: time) }
	}

	/// Removes a clip and closes the gap.
	public func deleteClip(_ clip: Clip) {
		apply("Delete clip") { $0.deleteClip(clip) }
		selectedClipTime = nil
	}

	public func setRate(_ rate: Double, for clip: Clip, coalescing: String? = nil) {
		apply("Speed \(rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.2g", rate))×", coalescing: coalescing) { $0.setRate(rate, for: clip) }
	}

	/// Trims a clip edge during a drag. `base` is the project when the drag began, so each step
	/// replaces the last one instead of adding to it.
	public func trim(_ clip: Clip, edge: Project.ClipEdge, toSource time: Double, base: Project) {
		apply("Trim clip", coalescing: "trim-\(clip.index)") { project in
			project = base
			project.trim(clip, edge: edge, toSource: time)
		}
	}

	/// Brings back material removed between two clips.
	public func restore(_ range: TimeRange) {
		apply("Restore") { $0.restore(range) }
	}

	public func applyPreset(_ preset: StylePreset) {
		apply("Apply style \(preset.name)") { preset.apply(to: &$0) }
	}
}
