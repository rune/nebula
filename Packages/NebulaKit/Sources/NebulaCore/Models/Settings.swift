import Foundation

/// How the virtual camera moves between zooms.
public struct CameraSettings: Codable, Hashable, Sendable {
	public enum Preset: String, Codable, Sendable, CaseIterable {
		case slow, mellow, quick, rapid, custom

		public var title: String { rawValue.capitalized }

		/// Spring stiffness and damping for the preset (unit mass).
		public var spring: (tension: Double, friction: Double)? {
			switch self {
			case .slow: (60, 15)
			case .mellow: (100, 20)
			case .quick: (170, 26)
			case .rapid: (300, 34)
			case .custom: nil
			}
		}
	}

	public var preset: Preset
	public var tension: Double
	public var friction: Double
	/// 0–1. Blur along camera and cursor motion.
	public var motionBlur: Double
	/// Fraction of the zoomed view the cursor can move in before the camera pans (follow zooms).
	public var followDeadzone: Double

	public init(preset: Preset = .mellow, tension: Double = 100, friction: Double = 20, motionBlur: Double = 0.5, followDeadzone: Double = 0.55) {
		self.preset = preset
		self.tension = tension
		self.friction = friction
		self.motionBlur = motionBlur
		self.followDeadzone = followDeadzone
	}

	/// The spring actually used, honouring presets.
	public var spring: (tension: Double, friction: Double) {
		preset.spring ?? (tension, friction)
	}
}

public struct CursorSettings: Codable, Hashable, Sendable {
	public enum ClickEffect: String, Codable, Sendable, CaseIterable {
		case none, circle, ripple
	}

	public var visible: Bool
	/// Multiplier on the natural cursor size, 0.5–4.
	public var size: Double
	/// 0 (raw) – 1 (very smooth).
	public var smoothing: Double
	public var hideWhenIdle: Bool
	/// Seconds without movement before an idle cursor fades out.
	public var idleDelay: Double
	public var clickEffect: ClickEffect
	public var clickColor: ColorValue
	/// Briefly shrink the cursor on click.
	public var clickBounce: Bool

	public init(
		visible: Bool = true,
		size: Double = 1.6,
		smoothing: Double = 0.6,
		hideWhenIdle: Bool = true,
		idleDelay: Double = 2.5,
		clickEffect: ClickEffect = .ripple,
		clickColor: ColorValue = ColorValue(hex: "#B089F0")!,
		clickBounce: Bool = true
	) {
		self.visible = visible
		self.size = size
		self.smoothing = smoothing
		self.hideWhenIdle = hideWhenIdle
		self.idleDelay = idleDelay
		self.clickEffect = clickEffect
		self.clickColor = clickColor
		self.clickBounce = clickBounce
	}
}

/// On-screen keycaps for pressed keyboard shortcuts.
public struct ShortcutOverlaySettings: Codable, Hashable, Sendable {
	public enum Position: String, Codable, Sendable, CaseIterable {
		case bottomCenter, bottomLeft, bottomRight, topCenter
	}

	public var enabled: Bool
	public var position: Position
	/// Keycap height relative to output height.
	public var size: Double

	public init(enabled: Bool = true, position: Position = .bottomCenter, size: Double = 0.055) {
		self.enabled = enabled
		self.position = position
		self.size = size
	}
}

public struct AudioSettings: Codable, Hashable, Sendable {
	public var microphoneVolume: Double
	public var systemVolume: Double
	public var noiseReduction: Bool
	public var volumes: [VolumeItem]
	public var music: MusicTrack?

	public init(
		microphoneVolume: Double = 1,
		systemVolume: Double = 0.8,
		noiseReduction: Bool = false,
		volumes: [VolumeItem] = [],
		music: MusicTrack? = nil
	) {
		self.microphoneVolume = microphoneVolume
		self.systemVolume = systemVolume
		self.noiseReduction = noiseReduction
		self.volumes = volumes
		self.music = music
	}
}

public struct MusicTrack: Codable, Hashable, Sendable {
	/// File name inside the project bundle's `media/` folder.
	public var file: String
	public var volume: Double
	/// Volume multiplier while someone is speaking, 0–1.
	public var duckTo: Double
	public var loop: Bool

	public init(file: String, volume: Double = 0.35, duckTo: Double = 0.35, loop: Bool = true) {
		self.file = file
		self.volume = volume
		self.duckTo = duckTo
		self.loop = loop
	}
}

public struct ExportSettings: Codable, Hashable, Sendable {
	public enum Format: String, Codable, Sendable, CaseIterable {
		case mp4, gif
	}

	public enum Codec: String, Codable, Sendable, CaseIterable {
		case h264, hevc
	}

	public enum Resolution: String, Codable, Sendable, CaseIterable {
		case p720 = "720p", p1080 = "1080p", p1440 = "1440p", p2160 = "4K"

		/// Height of a 16:9 frame; for other aspect ratios the shorter side.
		public var shortSide: Int {
			switch self {
			case .p720: 720
			case .p1080: 1080
			case .p1440: 1440
			case .p2160: 2160
			}
		}
	}

	public enum Quality: String, Codable, Sendable, CaseIterable {
		case studio, social, web

		/// Bits per pixel per frame for H.264; HEVC uses ~65% of this.
		public var bitsPerPixel: Double {
			switch self {
			case .studio: 0.18
			case .social: 0.10
			case .web: 0.06
			}
		}
	}

	public var format: Format
	public var codec: Codec
	public var resolution: Resolution
	public var fps: Int
	public var quality: Quality
	public var gifFPS: Int
	/// GIF width in pixels.
	public var gifWidth: Int
	public var gifLoop: Bool

	public init(
		format: Format = .mp4,
		codec: Codec = .h264,
		resolution: Resolution = .p1080,
		fps: Int = 60,
		quality: Quality = .studio,
		gifFPS: Int = 20,
		gifWidth: Int = 960,
		gifLoop: Bool = true
	) {
		self.format = format
		self.codec = codec
		self.resolution = resolution
		self.fps = fps
		self.quality = quality
		self.gifFPS = gifFPS
		self.gifWidth = gifWidth
		self.gifLoop = gifLoop
	}
}
