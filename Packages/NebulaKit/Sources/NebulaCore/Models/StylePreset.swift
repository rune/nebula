import Foundation

/// A reusable look: everything visual, nothing timeline-specific.
public struct StylePreset: Codable, Hashable, Sendable, Identifiable {
	public var id: UUID
	public var name: String
	public var style: Style
	public var camera: CameraSettings
	public var cursor: CursorSettings
	public var shortcutOverlay: ShortcutOverlaySettings
	public var captionStyle: CaptionStyle

	public init(
		id: UUID = UUID(),
		name: String,
		style: Style,
		camera: CameraSettings,
		cursor: CursorSettings,
		shortcutOverlay: ShortcutOverlaySettings,
		captionStyle: CaptionStyle = CaptionStyle()
	) {
		self.id = id
		self.name = name
		self.style = style
		self.camera = camera
		self.cursor = cursor
		self.shortcutOverlay = shortcutOverlay
		self.captionStyle = captionStyle
	}

	public init(name: String, from project: Project) {
		self.init(
			name: name,
			style: project.style,
			camera: project.camera,
			cursor: project.cursor,
			shortcutOverlay: project.shortcutOverlay,
			captionStyle: project.captions?.style ?? CaptionStyle()
		)
	}

	/// Applies the look to a project. Crop stays: it belongs to the recording, not the look.
	public func apply(to project: inout Project) {
		let crop = project.style.crop
		project.style = style
		project.style.crop = crop
		project.camera = camera
		project.cursor = cursor
		project.shortcutOverlay = shortcutOverlay
		project.captions?.style = captionStyle
	}

	public static let builtIn: [StylePreset] = [
		StylePreset(
			name: "Nebula",
			style: Style(),
			camera: CameraSettings(),
			cursor: CursorSettings(),
			shortcutOverlay: ShortcutOverlaySettings()
		),
		StylePreset(
			name: "Minimal",
			style: Style(background: .color(ColorValue(hex: "#0B0B0F")!), padding: 0.05, cornerRadius: 0.012, shadow: ShadowStyle(opacity: 0.35)),
			camera: CameraSettings(preset: .quick, motionBlur: 0.3),
			cursor: CursorSettings(size: 1.4, clickEffect: .circle),
			shortcutOverlay: ShortcutOverlaySettings()
		),
		StylePreset(
			name: "Social",
			style: Style(background: .wallpaper("dusk"), padding: 0.09, cornerRadius: 0.03, aspectRatio: .vertical),
			camera: CameraSettings(preset: .mellow, motionBlur: 0.6),
			cursor: CursorSettings(size: 2.2),
			shortcutOverlay: ShortcutOverlaySettings(size: 0.06)
		),
	]
}
