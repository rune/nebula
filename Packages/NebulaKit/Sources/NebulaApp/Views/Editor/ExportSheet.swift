import AppKit
import NebulaCore
import NebulaDesign
import NebulaRender
import SwiftUI

/// Export settings, progress and result.
struct ExportSheet: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var settings = ExportSettings()
	@State private var destination: URL?
	@State private var task: Task<Void, Never>?
	@State private var result: URL?
	@State private var error: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			HStack {
				Text("Export").font(.nebula(17, 750)).foregroundStyle(Theme.text1)
				Spacer()
				Text("\(Format.time(store.timeMap.outputDuration, tenths: false)) · \(sizeLabel)")
					.font(.nebula(12, 600)).foregroundStyle(Theme.text3)
			}
			if let job = app.exports.job {
				progress(job)
			} else if let result {
				finished(result)
			} else {
				form
			}
		}
		.padding(22)
		.frame(width: 460)
		.background(Theme.surface1)
		.onAppear {
			settings = store.project.export
		}
	}

	// MARK: Form

	private var form: some View {
		VStack(alignment: .leading, spacing: 18) {
			SegmentedPicker(selection: $settings.format, options: [(.mp4, "MP4 video"), (.gif, "GIF")])
			if settings.format == .mp4 {
				field("Resolution") {
					ChipPicker(selection: $settings.resolution, options: ExportSettings.Resolution.allCases.map { ($0, $0.rawValue) })
				}
				field("Frame rate") {
					SegmentedPicker(selection: $settings.fps, options: [(30, "30 fps"), (60, "60 fps")])
				}
				field("Quality") {
					SegmentedPicker(selection: $settings.quality, options: [(.studio, "Studio"), (.social, "Social"), (.web, "Web")])
				}
				field("Codec") {
					SegmentedPicker(selection: $settings.codec, options: [(.h264, "H.264 · plays everywhere"), (.hevc, "HEVC · smaller")])
				}
			} else {
				field("Width") {
					ChipPicker(selection: $settings.gifWidth, options: [480, 720, 960, 1280].map { ($0, "\($0) px") })
				}
				field("Frame rate") {
					SegmentedPicker(selection: $settings.gifFPS, options: [(10, "10 fps"), (15, "15 fps"), (20, "20 fps"), (30, "30 fps")])
				}
				InspectorToggle("Loop forever", isOn: $settings.gifLoop)
			}
			HStack(spacing: 8) {
				Image(systemName: "folder").foregroundStyle(Theme.text3)
				Text(destinationLabel).font(.nebula(12, 600)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
				Spacer()
				Button("Change…", action: chooseDestination).buttonStyle(NebulaButtonStyle(.ghost, height: 26))
			}
			.padding(.horizontal, 10)
			.frame(height: 36)
			.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
			if let error {
				Text(error).font(.nebula(12, 600)).foregroundStyle(Color(hex: 0xFF8FA3))
			}
			HStack {
				Text("Estimated \(estimate)").font(.nebula(12, 600)).foregroundStyle(Theme.text3)
				Spacer()
				Button("Cancel") { dismiss() }
					.buttonStyle(NebulaButtonStyle(.secondary, height: 32))
					.keyboardShortcut(.cancelAction)
				Button("Export", action: start)
					.buttonStyle(NebulaButtonStyle(.primary, height: 32))
					.keyboardShortcut(.defaultAction)
			}
		}
	}

	private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.nebula(12, 650)).foregroundStyle(Theme.text2)
			content()
		}
	}

	private func progress(_ job: ExportController.Job) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Rendering \(job.format == .gif ? "GIF" : "video")… \(Format.percent(job.progress))")
				.font(.nebula(13, 650)).foregroundStyle(Theme.text1)
			GeometryReader { proxy in
				ZStack(alignment: .leading) {
					Capsule().fill(Theme.surface3)
					Capsule().fill(Theme.sliderGradient).frame(width: max(6, proxy.size.width * job.progress))
				}
			}
			.frame(height: 6)
			.animation(.linear(duration: 0.2), value: job.progress)
			HStack {
				Text("Every frame is drawn with the same renderer as the preview.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
				Spacer()
				Button("Stop") {
					task?.cancel()
				}
				.buttonStyle(NebulaButtonStyle(.secondary, height: 30))
			}
		}
	}

	private func finished(_ url: URL) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 10) {
				Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.success)
				VStack(alignment: .leading, spacing: 2) {
					Text(url.lastPathComponent).font(.nebula(13, 700)).foregroundStyle(Theme.text1)
					Text(fileSize(url)).font(.nebula(11.5, 600)).foregroundStyle(Theme.text3)
				}
			}
			HStack {
				Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
					.buttonStyle(NebulaButtonStyle(.secondary, height: 32))
				Button("Copy file") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.writeObjects([url as NSURL])
					app.toasts.show("Copied \(url.lastPathComponent)")
				}
				.buttonStyle(NebulaButtonStyle(.secondary, height: 32))
				Spacer()
				Button("Done") { dismiss() }
					.buttonStyle(NebulaButtonStyle(.primary, height: 32))
					.keyboardShortcut(.defaultAction)
			}
		}
	}

	// MARK: Actions

	private func start() {
		error = nil
		let settings = settings
		store.apply("Export settings") { $0.export = settings }
		let target = destination ?? app.exports.defaultDestination(for: store, settings: settings)
		task = Task {
			do {
				result = try await app.exports.export(store, settings: settings, to: target)
			} catch is CancellationError {
				try? FileManager.default.removeItem(at: target)
			} catch {
				self.error = error.localizedDescription
			}
		}
	}

	private func chooseDestination() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [settings.format == .gif ? .gif : .mpeg4Movie]
		panel.nameFieldStringValue = "\(store.project.name).\(settings.format == .gif ? "gif" : "mp4")"
		panel.directoryURL = AppPaths.exports
		if panel.runModal() == .OK { destination = panel.url }
	}

	// MARK: Labels

	private var canvas: CGSize {
		if settings.format == .gif {
			let full = SceneLayout.canvasSize(for: store.project, shortSide: 1080)
			return CGSize(width: Double(settings.gifWidth), height: (full.height * Double(settings.gifWidth) / full.width).rounded())
		}
		return SceneLayout.canvasSize(for: store.project, shortSide: settings.resolution.shortSide)
	}

	private var sizeLabel: String {
		"\(Int(canvas.width)) × \(Int(canvas.height))"
	}

	private var destinationLabel: String {
		if let destination { return destination.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~") }
		return "~/Movies/Nebula Exports"
	}

	private var estimate: String {
		let seconds = store.timeMap.outputDuration
		if settings.format == .gif {
			let bytes = Double(canvas.width * canvas.height) * Double(settings.gifFPS) * seconds * 0.12
			return Format.bytes(Int64(bytes))
		}
		let bpp = settings.quality.bitsPerPixel * (settings.codec == .hevc ? 0.65 : 1)
		let bits = Double(canvas.width * canvas.height) * Double(settings.fps) * bpp * seconds
		return Format.bytes(Int64(bits / 8))
	}

	private func fileSize(_ url: URL) -> String {
		let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		return Format.bytes(Int64(size))
	}
}
