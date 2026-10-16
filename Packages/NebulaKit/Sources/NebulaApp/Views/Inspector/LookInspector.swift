import AppKit
import NebulaCore
import NebulaDesign
import NebulaRender
import SwiftUI
import UniformTypeIdentifiers

/// Background, frame, aspect ratio and presets.
struct LookInspector: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app
	@State private var backgroundTab: BackgroundTab = .desktop
	@State private var showCrop = false

	enum BackgroundTab: String, CaseIterable {
		case desktop = "Desktop"
		case macOS = "macOS"
		case color = "Color"
		case image = "Image"
	}

	private var style: Style { store.project.style }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "Background", trailing: backgroundCaption) {
				SegmentedPicker(selection: $backgroundTab, options: BackgroundTab.allCases.map { ($0, $0.rawValue) })
				switch backgroundTab {
				case .desktop: desktopChoices
				case .macOS: WallpaperGrid(selectedPath: selectedImagePath) { setImage($0) }
				case .color: colorChoices
				case .image: imageChoice
				}
				if case .image = style.background {
					NebulaSlider("Background blur", value: store.binding("Background blur", \.style.backgroundBlur), in: 0...1, format: Format.percent)
				}
			}

			InspectorSection(title: "Frame") {
				SegmentedPicker(selection: store.binding("Placement", \.style.placement), options: Style.Placement.allCases.map { ($0, $0.title) })
				if style.placement == .original {
					NebulaSlider("Scale", value: Binding(
						get: { 1 - 2 * store.project.style.padding },
						set: { value in store.apply("Scale", coalescing: "Scale") { $0.style.padding = (1 - value) / 2 } }
					), in: 0.5...1, format: Format.percent)
					if store.project.media.screen == nil {
						Text("Full-screen recordings fill the frame. Choose Fit with padding to show the background.")
							.font(.nebula(11.5, 550))
							.foregroundStyle(Theme.text3)
							.fixedSize(horizontal: false, vertical: true)
					}
				} else {
					NebulaSlider("Padding", value: store.binding("Padding", \.style.padding), in: 0...0.2, format: Format.percent)
				}
				NebulaSlider("Corner radius", value: store.binding("Corner radius", \.style.cornerRadius), in: 0...0.05) { "\(Int(($0 * 1000).rounded()))" }
				NebulaSlider("Shadow", value: store.binding("Shadow", \.style.shadow.opacity), in: 0...1, format: Format.percent)
				HStack {
					Text("Crop").font(.nebula(12.5, 600)).foregroundStyle(Theme.text2)
					Spacer()
					if style.crop != .full {
						Button("Reset") { store.apply("Reset crop") { $0.style.crop = .full } }
							.buttonStyle(NebulaButtonStyle(.ghost, height: 26))
					}
					Button(style.crop == .full ? "Crop…" : "Edit crop…") { showCrop = true }
						.buttonStyle(NebulaButtonStyle(.secondary, height: 26))
				}
			}

			InspectorSection(title: "Aspect ratio") {
				ChipPicker(selection: store.binding("Aspect ratio", \.style.aspectRatio), options: AspectRatio.allCases.map { ratio in
					(ratio, ratio == .auto && store.project.media.screen != nil ? "Auto · screen" : ratio.title)
				})
			}

			InspectorSection(title: "Presets") {
				FlowLayout(spacing: 6) {
					ForEach(app.presets.all) { preset in
						Button(preset.name) { store.applyPreset(preset) }
							.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
							.overlay(alignment: .topTrailing) {
								if app.settings.defaultPresetID == preset.id {
									Circle().fill(Theme.violet).frame(width: 6, height: 6).offset(x: -5, y: 5)
								}
							}
							.contextMenu {
								Button("Use for new recordings") { app.settings.defaultPresetID = preset.id }
								if !StylePreset.builtIn.contains(where: { $0.id == preset.id }) {
									Button("Delete preset") { app.presets.delete(preset) }
								}
							}
					}
				}
				Button {
					app.presets.save(StylePreset(name: "\(store.project.name) look", from: store.project))
					app.toasts.show("Saved look as a preset", detail: "Right-click a preset to use it for new recordings")
				} label: {
					Label("Save current look", systemImage: "plus")
				}
				.buttonStyle(NebulaButtonStyle(.ghost, height: 28))
			}
		}
		.onAppear { backgroundTab = tab(for: style.background) }
		.onDebugCommand { command in
			if command.hasPrefix("bg:"), let value = BackgroundTab(rawValue: String(command.dropFirst(3))) { backgroundTab = value }
			if command == "crop" { showCrop = true }
		}
		.sheet(isPresented: $showCrop) { CropEditor(store: store) }
	}

	// MARK: Background choices

	private var desktopFile: URL { store.bundle.mediaURL.appending(path: ProjectBundle.desktopFileName) }
	private var hasDesktop: Bool { FileManager.default.fileExists(atPath: desktopFile.path) }

	private var selectedImagePath: String? {
		if case .image(let path) = style.background { return path }
		return nil
	}

	private var backgroundCaption: String {
		switch style.background {
		case .image(let path) where path == Background.desktopPath: "Your desktop"
		case .image(let path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
		case .gradient: "Gradient"
		case .color(let color): color.hex
		}
	}

	@ViewBuilder private var desktopChoices: some View {
		VStack(alignment: .leading, spacing: 10) {
			if hasDesktop {
				WallpaperTile(url: desktopFile, selected: selectedImagePath == Background.desktopPath, large: true) {
					store.apply("Use desktop background") { $0.style.background = .desktop }
				}
				Text("The wallpaper that was on screen while you recorded.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
			} else {
				Text("This project has no captured desktop. Pick your current wallpaper or one from macOS.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
					.fixedSize(horizontal: false, vertical: true)
			}
			let current = WallpaperCatalog.currentDesktops()
			if !current.isEmpty {
				SectionHeader("Current wallpaper")
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
					ForEach(current, id: \.self) { url in
						WallpaperTile(url: url, selected: selectedImagePath == url.path) { setImage(url) }
					}
				}
			}
		}
	}

	private var colorChoices: some View {
		VStack(alignment: .leading, spacing: 12) {
			LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
				ForEach(Swatches.colors, id: \.self) { hex in
					let value = ColorValue(hex: hex) ?? .black
					SwatchTile(fill: AnyShapeStyle(value.color), selected: style.background == .color(value)) {
						store.apply("Background color") { $0.style.background = .color(value) }
					}
				}
			}
			SectionHeader("Gradients")
			LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
				ForEach(Swatches.gradients.indices, id: \.self) { index in
					let fill = Swatches.gradients[index]
					SwatchTile(fill: AnyShapeStyle(LinearGradient(colors: fill.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)), selected: style.background == .gradient(fill), height: 44) {
						store.apply("Background gradient") { $0.style.background = .gradient(fill) }
					}
				}
			}
			InspectorRow(title: "Custom") {
				ColorPicker("", selection: Binding(
					get: { if case .color(let c) = store.project.style.background { c.color } else { Color.black } },
					set: { color in store.apply("Background color", coalescing: "bg-color") { $0.style.background = .color(ColorValue(color)) } }
				), supportsOpacity: false)
				.labelsHidden()
			}
		}
	}

	private var imageChoice: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let path = selectedImagePath, path != Background.desktopPath {
				WallpaperTile(url: resolve(path), selected: true, large: true) {}
			}
			Button {
				let panel = NSOpenPanel()
				panel.allowedContentTypes = [.image]
				panel.message = "Choose a background image."
				guard panel.runModal() == .OK, let url = panel.url else { return }
				do { try store.setBackgroundImage(from: url) } catch { app.toasts.show("Couldn't use that image", detail: error.localizedDescription) }
			} label: {
				Label("Choose image…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
			}
			.buttonStyle(NebulaButtonStyle(.secondary, height: 32))
		}
	}

	private func resolve(_ path: String) -> URL {
		path.hasPrefix("/") ? URL(fileURLWithPath: path) : store.bundle.url.appending(path: path)
	}

	private func setImage(_ url: URL) {
		store.apply("Background image") { $0.style.background = .image(path: url.path) }
	}

	private func tab(for background: Background) -> BackgroundTab {
		switch background {
		case .image(let path) where path == Background.desktopPath: .desktop
		case .image(let path) where path.hasPrefix("/System/") || path.contains("Desktop Pictures") || path.contains("mobileAssetDesktop"): .macOS
		case .image: .image
		case .color, .gradient: .color
		}
	}
}

extension Background {
	static var desktopPath: String {
		if case .image(let path) = desktop { return path }
		return ""
	}
}

private enum Swatches {
	static let colors = [
		"#0B0B0F", "#000000", "#14101C", "#1B0036", "#0E1726", "#1A1A1F",
		"#2A2140", "#3B1F6E", "#8C28FF", "#B089F0", "#E8E6EF", "#FFFFFF",
	]

	static let gradients: [GradientFill] = [
		["#1B0036", "#8C28FF"], ["#0F0C29", "#302B63"], ["#000000", "#1B0036", "#B089F0"], ["#0B1A33", "#2E5BBA"],
		["#1A0B12", "#8A2A4F"], ["#0D1F1A", "#2F7D64"], ["#231A10", "#B8792E"], ["#141414", "#3A3A44"],
	].map { GradientFill(colors: $0.compactMap(ColorValue.init(hex:)), angle: 135) }
}

private struct SwatchTile: View {
	let fill: AnyShapeStyle
	let selected: Bool
	var height: CGFloat = 32
	let action: () -> Void

	var body: some View {
		RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
			.fill(fill)
			.frame(height: height)
			.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(selected ? Theme.lavender : Theme.hairlineStrong, lineWidth: selected ? 2 : 1))
			.contentShape(Rectangle())
			.onTapGesture(perform: action)
	}
}

/// A wallpaper thumbnail at a fixed 16:10 shape: the picture fills it and is clipped, so tiles
/// line up whatever the source image's proportions.
struct WallpaperTile: View {
	let url: URL
	let selected: Bool
	var large = false
	var help: String?
	let action: () -> Void

	var body: some View {
		Color.clear
			.aspectRatio(16.0 / 10.0, contentMode: .fit)
			.frame(maxWidth: .infinity)
			.overlay { AsyncFileImage(url: url, maxPixel: large ? 600 : 240, contentMode: .fill) }
			.clipShape(RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous).strokeBorder(selected ? Theme.lavender : Theme.hairlineStrong, lineWidth: selected ? 2 : 1))
			.contentShape(Rectangle())
			.onTapGesture(perform: action)
			.help(help ?? "")
	}
}

private struct WallpaperGrid: View {
	let selectedPath: String?
	let onSelect: (URL) -> Void
	@State private var wallpapers: [WallpaperCatalog.Wallpaper] = []

	var body: some View {
		LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
			ForEach(wallpapers) { wallpaper in
				WallpaperTile(url: wallpaper.thumbnail, selected: selectedPath == wallpaper.image.path, help: wallpaper.name) {
					onSelect(wallpaper.image)
				}
			}
		}
		.task { wallpapers = await Task.detached { WallpaperCatalog.all() }.value }
	}
}

/// Wallpapers that ship with macOS (or were downloaded by it) and are on disk.
enum WallpaperCatalog {
	struct Wallpaper: Identifiable, Hashable, Sendable {
		var id: String { image.path }
		var name: String
		var image: URL
		var thumbnail: URL
	}

	static func all() -> [Wallpaper] {
		let folders = [
			"/System/Library/Desktop Pictures",
			"/Library/Desktop Pictures",
			NSHomeDirectory() + "/Library/Application Support/com.apple.mobileAssetDesktop",
		]
		let thumbnails = "/System/Library/Desktop Pictures/.thumbnails"
		var seen = Set<String>()
		var result: [Wallpaper] = []
		for folder in folders {
			let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
			for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
				guard ["heic", "jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) else { continue }
				let name = url.deletingPathExtension().lastPathComponent
				guard !seen.contains(name) else { continue }
				seen.insert(name)
				let thumb = URL(fileURLWithPath: "\(thumbnails)/\(name).heic")
				let thumbnail = FileManager.default.fileExists(atPath: thumb.path) ? thumb : url
				result.append(Wallpaper(name: name, image: url, thumbnail: thumbnail))
			}
		}
		return result
	}

	@MainActor
	static func currentDesktops() -> [URL] {
		var urls: [URL] = []
		for screen in NSScreen.screens {
			if let url = NSWorkspace.shared.desktopImageURL(for: screen), !urls.contains(url),
			   ["heic", "jpg", "jpeg", "png", "tiff"].contains(url.pathExtension.lowercased()) {
				urls.append(url)
			}
		}
		return urls
	}
}

// MARK: - Crop

/// Drag the corners or the middle of the rectangle to choose the part of the recording to keep.
struct CropEditor: View {
	let store: ProjectStore
	@Environment(\.dismiss) private var dismiss
	@State private var frame: CGImage?
	@State private var crop: NormRect = .full
	@State private var dragStart: NormRect?

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Crop recording").font(.nebula(15, 750)).foregroundStyle(Theme.text1)
			GeometryReader { proxy in
				let aspect = store.project.media.aspect
				let size = fit(aspect, proxy.size)
				ZStack(alignment: .topLeading) {
					Group {
						if let frame { Image(decorative: frame, scale: 1).resizable() } else { Theme.surface2 }
					}
					.frame(width: size.width, height: size.height)
					let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width, height: crop.height * size.height)
					Path { path in
						path.addRect(CGRect(origin: .zero, size: size))
						path.addRect(rect)
					}
					.fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
					.allowsHitTesting(false)
					Rectangle()
						.strokeBorder(Theme.lavender, lineWidth: 1.5)
						.frame(width: rect.width, height: rect.height)
						.contentShape(Rectangle())
						.offset(x: rect.minX, y: rect.minY)
						.gesture(dragGesture(size: size) { start, dx, dy in
							var r = start
							r.x = (start.x + dx).clamped(to: 0...(1 - start.width))
							r.y = (start.y + dy).clamped(to: 0...(1 - start.height))
							return r
						})
					ForEach(0..<4, id: \.self) { corner in
						let left = corner % 2 == 0
						let top = corner < 2
						Circle().fill(.white).frame(width: 12, height: 12)
							.overlay(Circle().strokeBorder(Theme.violet, lineWidth: 1.5))
							.frame(width: 26, height: 26)
							.contentShape(Rectangle())
							.position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
							.gesture(dragGesture(size: size) { start, dx, dy in
								var minX = start.x, minY = start.y, maxX = start.maxX, maxY = start.maxY
								if left { minX = (minX + dx).clamped(to: 0...(maxX - 0.05)) } else { maxX = (maxX + dx).clamped(to: (minX + 0.05)...1) }
								if top { minY = (minY + dy).clamped(to: 0...(maxY - 0.05)) } else { maxY = (maxY + dy).clamped(to: (minY + 0.05)...1) }
								return NormRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
							})
					}
				}
				.frame(width: size.width, height: size.height)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.frame(width: 640, height: 400)
			HStack {
				Button("Reset") { crop = .full }.buttonStyle(NebulaButtonStyle(.ghost))
				Spacer()
				Button("Cancel") { dismiss() }.buttonStyle(NebulaButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
				Button("Apply crop") {
					let value = crop
					store.apply("Crop") { $0.style.crop = value }
					dismiss()
				}
				.buttonStyle(NebulaButtonStyle(.primary))
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		.background(Theme.surface1)
		.task {
			crop = store.project.style.crop
			frame = try? await FrameGrabber.sourceFrame(video: store.videoURL, at: store.playheadSourceTime, maxWidth: 1280)
		}
	}

	private func fit(_ aspect: Double, _ bounds: CGSize) -> CGSize {
		bounds.width / max(bounds.height, 1) > aspect
			? CGSize(width: bounds.height * aspect, height: bounds.height)
			: CGSize(width: bounds.width, height: bounds.width / aspect)
	}

	private func dragGesture(size: CGSize, update: @escaping (NormRect, Double, Double) -> NormRect) -> some Gesture {
		DragGesture(minimumDistance: 1)
			.onChanged { drag in
				let start = dragStart ?? crop
				dragStart = start
				crop = update(start, drag.translation.width / size.width, drag.translation.height / size.height)
			}
			.onEnded { _ in dragStart = nil }
	}
}
