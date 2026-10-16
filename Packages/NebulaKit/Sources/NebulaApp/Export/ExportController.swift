import AppKit
import Foundation
import NebulaCore
import NebulaRender
import Observation
import UniformTypeIdentifiers

/// Exports projects and tracks progress for the UI.
@MainActor
@Observable
public final class ExportController {
	public struct Job: Equatable {
		public var projectName: String
		public var progress: Double
		public var format: ExportSettings.Format
	}

	public private(set) var job: Job?
	public private(set) var lastExport: URL?
	/// The project offered in the quick-export widget after a recording.
	public var quickExportURL: URL?
	@ObservationIgnored weak var app: AppModel?
	@ObservationIgnored private var task: Task<URL, Error>?

	public var isExporting: Bool { job != nil }

	/// Default destination: `~/Movies/Nebula Exports/<name>.<ext>`, never overwriting.
	public func defaultDestination(for store: ProjectStore, settings: ExportSettings) -> URL {
		try? FileManager.default.createDirectory(at: AppPaths.exports, withIntermediateDirectories: true)
		let ext = settings.format == .gif ? "gif" : "mp4"
		var url = AppPaths.exports.appending(path: "\(store.project.name).\(ext)")
		var counter = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = AppPaths.exports.appending(path: "\(store.project.name) \(counter).\(ext)")
			counter += 1
		}
		return url
	}

	/// Renders the project. Returns the written file.
	@discardableResult
	public func export(_ store: ProjectStore, settings: ExportSettings? = nil, to destination: URL? = nil) async throws -> URL {
		let settings = settings ?? store.project.export
		let url = destination ?? defaultDestination(for: store, settings: settings)
		job = Job(projectName: store.project.name, progress: 0, format: settings.format)
		defer { job = nil }
		let scene = store.makeScene()
		let media = store.media
		let canvas: CGSize
		if settings.format == .gif {
			let full = SceneLayout.canvasSize(for: store.project, shortSide: 1080)
			let width = CGFloat(settings.gifWidth)
			canvas = CGSize(width: (width / 2).rounded() * 2, height: (full.height * width / full.width / 2).rounded() * 2)
		} else {
			canvas = SceneLayout.canvasSize(for: store.project, shortSide: settings.resolution.shortSide)
		}
		let fps = settings.format == .gif ? settings.gifFPS : settings.fps
		let playable = try await CompositionBuilder.build(scene: scene, media: media, renderSize: canvas, frameRate: fps, quality: .export)
		let report: @Sendable (Double) -> Void = { value in
			Task { @MainActor [weak self] in self?.job?.progress = value }
		}
		if settings.format == .gif {
			try await GIFExporter.export(playable, fps: settings.gifFPS, loop: settings.gifLoop, to: url, progress: report)
		} else {
			try await VideoExporter.export(playable, settings: settings, to: url, progress: report)
		}
		lastExport = url
		app?.toasts.show("Exported \(url.lastPathComponent)", detail: "Saved to \(url.deletingLastPathComponent().lastPathComponent)")
		return url
	}

	public func cancel() {
		task?.cancel()
	}

	/// Exports with the project's settings and puts the file on the clipboard.
	public func copyVideo(_ store: ProjectStore) async {
		do {
			let temp = FileManager.default.temporaryDirectory.appending(path: "\(store.project.name).mp4")
			var settings = store.project.export
			settings.format = .mp4
			let url = try await export(store, settings: settings, to: temp)
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			pasteboard.writeObjects([url as NSURL])
			app?.toasts.show("Video copied", detail: "Paste it into any app")
		} catch {
			app?.toasts.show("Couldn't copy the video", detail: error.localizedDescription)
		}
	}

	/// Copies the frame under the playhead as a PNG.
	public func copyFrame(_ store: ProjectStore) async {
		do {
			let canvas = SceneLayout.canvasSize(for: store.project, shortSide: 2160)
			let playable = try await CompositionBuilder.build(scene: store.makeScene(), media: store.media, renderSize: canvas, quality: .export)
			let image = try await FrameGrabber.renderedFrame(playable, at: store.preview.currentTime)
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
			app?.toasts.show("Frame copied")
		} catch {
			app?.toasts.show("Couldn't copy the frame", detail: error.localizedDescription)
		}
	}

	func showQuickExport(for url: URL) {
		quickExportURL = url
	}

	public func revealLastExport() {
		if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
	}
}
