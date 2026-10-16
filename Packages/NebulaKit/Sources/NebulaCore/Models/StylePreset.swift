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
			id: UUID(uuidString: "6A1C2F7E-0000-4000-8000-000000000001")!,
			name: "Real desktop",
			style: Style(background: .desktop, placement: .original),
			camera: CameraSettings(),
			cursor: CursorSettings(),
			shortcutOverlay: ShortcutOverlaySettings()
		),
		StylePreset(
			id: UUID(uuidString: "6A1C2F7E-0000-4000-8000-000000000002")!,
			name: "Clean",
			style: Style(background: .color(ColorValue(hex: "#0B0B0F")!), placement: .fit, padding: 0.05, cornerRadius: 0.014, shadow: ShadowStyle(opacity: 0.35)),
			camera: CameraSettings(preset: .quick, motionBlur: 0.3),
			cursor: CursorSettings(size: 1.4, clickEffect: .circle),
			shortcutOverlay: ShortcutOverlaySettings()
		),
		StylePreset(
			id: UUID(uuidString: "6A1C2F7E-0000-4000-8000-000000000003")!,
			name: "Vertical",
			style: Style(background: .desktop, backgroundBlur: 0.4, placement: .fit, padding: 0.04, cornerRadius: 0.025, aspectRatio: .vertical),
			camera: CameraSettings(preset: .mellow, motionBlur: 0.4),
			cursor: CursorSettings(size: 2.2),
			shortcutOverlay: ShortcutOverlaySettings(size: 0.05)
		),
	]
}
