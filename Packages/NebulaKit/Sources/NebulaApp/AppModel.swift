import AppKit
import Foundation
import NebulaCaptions
import NebulaCapture
import NebulaCore
import NebulaRender
import Observation
import os

/// The app's root state: library, open projects, recorder, presets, settings, MCP server.
@MainActor
@Observable
public final class AppModel {
	public static let shared = AppModel()

	public let settings = AppSettings()
	public let presets = PresetStore()
	public let toasts = ToastCenter()
	public let recorder = RecorderController()
	public let exports = ExportController()
	public private(set) var library = ProjectLibrary()
	public private(set) var entries: [ProjectLibrary.Entry] = []
	public private(set) var stores: [URL: ProjectStore] = [:]
	/// The project in the frontmost editor window.
	public var activeStoreURL: URL?
	public var showCommandPalette = false
	public var showExportSheet = false
	public var lastError: String?
	public let mcp: MCPController

	/// Set by the SwiftUI scene so model code can open editor windows.
	@ObservationIgnored public var openEditorWindow: ((URL) -> Void)?
	@ObservationIgnored public var openLibraryWindow: (() -> Void)?
	@ObservationIgnored let transcriber = CaptionTranscriber(modelsFolder: AppPaths.models)
	private static let logger = Logger(subsystem: "app.nebula", category: "app")

	public var activeStore: ProjectStore? { activeStoreURL.flatMap { stores[$0] } }

	init() {
		mcp = MCPController()
		recorder.app = self
		exports.app = self
		mcp.app = self
		refreshLibrary()
	}

	/// Called once from the app delegate after launch.
	public func launch() {
		mcp.applySettings()
		Task { await recoverInterruptedRecordings() }
	}

	/// Recordings are written as fragmented movies, so a crash or power loss leaves a playable
	/// file without a project. Rebuild those projects; drop bundles with nothing in them.
	private func recoverInterruptedRecordings() async {
		let urls = (try? FileManager.default.contentsOfDirectory(at: library.rootURL, includingPropertiesForKeys: nil)) ?? []
		var recovered = 0
		for url in urls where url.pathExtension == ProjectBundle.fileExtension {
			let bundle = ProjectBundle(url: url)
			guard !FileManager.default.fileExists(atPath: bundle.projectURL.path) else { continue }
			let video = url.appending(path: ProjectBundle.videoFileName)
			let microphone = url.appending(path: ProjectBundle.microphoneFileName)
			let size = (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
			let media = size > 0 ? try? await MediaProbe.mediaInfo(
				video: video,
				videoFileName: ProjectBundle.videoFileName,
				microphone: FileManager.default.fileExists(atPath: microphone.path) ? microphone : nil,
				microphoneFileName: ProjectBundle.microphoneFileName
			) : nil
			guard let media, media.duration > 0.5 else {
				try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
				Self.logger.info("Removed empty recording \(url.lastPathComponent, privacy: .public)")
				continue
			}
			var project = Project(name: bundle.name, media: media)
			if let preset = presets.preset(id: settings.defaultPresetID) { preset.apply(to: &project) }
			if project.style.background == Background.desktop,
			   !FileManager.default.fileExists(atPath: bundle.mediaURL.appending(path: ProjectBundle.desktopFileName).path) {
				project.style.background = Style().background
			}
			do {
				if !FileManager.default.fileExists(atPath: bundle.inputURL.path) { try bundle.write(InputTrack.empty) }
				try bundle.write(project)
				try? await Thumbnailer.writeThumbnail(video: video, to: bundle.thumbnailURL, at: min(1, media.duration / 2))
				recovered += 1
			} catch {
				Self.logger.error("Couldn't recover \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
			}
		}
		if recovered > 0 {
			toasts.show(recovered == 1 ? "Recovered an interrupted recording" : "Recovered \(recovered) interrupted recordings", detail: "They're in your library")
		}
		refreshLibrary()
	}

	// MARK: Library

	public func refreshLibrary() {
		let library = library
		Task {
			let entries = await Task.detached { library.entries() }.value
			self.entries = entries
		}
	}

	// MARK: Projects

	public func store(for url: URL) throws -> ProjectStore {
		if let existing = stores[url] { return existing }
		let store = try ProjectStore(bundle: ProjectBundle(url: url))
		store.onEdit = { [weak self, weak store] label, source in
			guard let self, let store else { return }
			if source == .assistant {
				self.toasts.show(label, detail: "Claude", isAssistant: true, showsUndo: true)
			}
			_ = store
		}
		stores[url] = store
		return store
	}

	public func open(_ url: URL) {
		do {
			_ = try store(for: url)
			activeStoreURL = url
			openEditorWindow?(url)
		} catch {
			lastError = error.localizedDescription
		}
	}

	public func close(_ url: URL) {
		stores[url]?.saveNow()
		stores[url]?.preview.pause()
		stores[url] = nil
		if activeStoreURL == url { activeStoreURL = nil }
		refreshLibrary()
	}

	public func delete(_ entry: ProjectLibrary.Entry) {
		close(entry.bundle.url)
		try? library.moveToTrash(entry.bundle)
		refreshLibrary()
	}

	/// Builds a project for a finished recording and opens it.
	func createProject(from result: RecordingResult, in bundle: ProjectBundle) async throws {
		let micURL = result.microphoneURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
		var media = try await MediaProbe.mediaInfo(
			video: result.videoURL,
			videoFileName: ProjectBundle.videoFileName,
			microphone: micURL,
			microphoneFileName: ProjectBundle.microphoneFileName
		)
		media.screen = result.screen
		var project = Project(name: bundle.name, media: media)
		(presets.preset(id: settings.defaultPresetID) ?? StylePreset.builtIn[0]).apply(to: &project)
		if let jpeg = result.desktopJPEG {
			try FileManager.default.createDirectory(at: bundle.mediaURL, withIntermediateDirectories: true)
			try jpeg.write(to: bundle.mediaURL.appending(path: ProjectBundle.desktopFileName), options: .atomic)
		} else if project.style.background == Background.desktop {
			project.style.background = Style().background
		}
		try bundle.write(result.input)
		try bundle.write(project)
		try? await Thumbnailer.writeThumbnail(video: result.videoURL, to: bundle.thumbnailURL, at: min(1, media.duration / 2))
		refreshLibrary()
		open(bundle.url)
		exports.showQuickExport(for: bundle.url)
	}

	/// Imports a video file (MP4/MOV) or an OpenScreen project as a new Nebula project.
	@discardableResult
	public func importFile(_ url: URL) async -> URL? {
		do {
			let bundle = try library.newBundle(named: url.deletingPathExtension().lastPathComponent)
			if url.pathExtension.lowercased() == "openscreen" {
				let data = try Data(contentsOf: url)
				let videoPath = try OpenScreenImporter.videoPath(inProjectData: data)
				let source = URL(fileURLWithPath: videoPath)
				let fileName = "recording.\(source.pathExtension.isEmpty ? "mp4" : source.pathExtension)"
				try FileManager.default.copyItem(at: source, to: bundle.url.appending(path: fileName))
				let media = try await MediaProbe.mediaInfo(video: bundle.url.appending(path: fileName), videoFileName: fileName, microphone: nil, microphoneFileName: nil)
				let cursor = try? Data(contentsOf: URL(fileURLWithPath: videoPath + ".cursor.json"))
				let result = try OpenScreenImporter.convert(projectData: data, cursorData: cursor, media: media, name: bundle.name)
				try bundle.write(result.input)
				try bundle.write(result.project)
			} else {
				let fileName = "recording.\(url.pathExtension.lowercased())"
				try FileManager.default.copyItem(at: url, to: bundle.url.appending(path: fileName))
				let media = try await MediaProbe.mediaInfo(video: bundle.url.appending(path: fileName), videoFileName: fileName, microphone: nil, microphoneFileName: nil)
				var project = Project(name: bundle.name, media: media)
				// Imported videos have no captured desktop; keep everything but that.
				if let preset = presets.preset(id: settings.defaultPresetID) { preset.apply(to: &project) }
				if project.style.background == Background.desktop { project.style.background = Style().background }
				try bundle.write(InputTrack.empty)
				try bundle.write(project)
			}
			let project = try bundle.readProject()
			try? await Thumbnailer.writeThumbnail(video: bundle.videoURL(for: project), to: bundle.thumbnailURL, at: min(1, project.media.duration / 2))
			refreshLibrary()
			open(bundle.url)
			return bundle.url
		} catch {
			lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
			toasts.show("Import failed", detail: error.localizedDescription)
			return nil
		}
	}

	// MARK: Captions

	public func generateCaptions(for store: ProjectStore, model: CaptionModel = .base, source: EditSource = .user, progress: @escaping @MainActor (String) -> Void) async throws {
		let audio = store.bundle.microphoneURL(for: store.project) ?? store.videoURL
		let segments = try await transcriber.transcribe(audio: audio, model: model) { update in
			Task { @MainActor in progress(update.title) }
		}
		let lines = CaptionLayout.lines(for: segments)
		store.apply("Generate captions", source: source) { project in
			var track = project.captions ?? CaptionTrack()
			track.segments = lines
			track.enabled = true
			project.captions = track
		}
	}
}
