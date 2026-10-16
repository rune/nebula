import Foundation

/// A Nebula project: everything the editor changes. Media lives next to it in the bundle.
public struct Project: Codable, Hashable, Sendable {
	public static let currentFormatVersion = 1

	public var formatVersion: Int
	public var id: UUID
	public var name: String
	public var createdAt: Date
	public var media: MediaInfo

	public var cuts: [CutItem]
	public var speeds: [SpeedItem]
	public var zooms: [ZoomItem]
	public var masks: [MaskItem]
	public var annotations: [AnnotationItem]
	public var captions: CaptionTrack?
	public var audio: AudioSettings

	public var style: Style
	public var camera: CameraSettings
	public var cursor: CursorSettings
	public var shortcutOverlay: ShortcutOverlaySettings
	public var export: ExportSettings
	/// Playhead position when the project was last saved (source seconds).
	public var playhead: Double

	public init(
		id: UUID = UUID(),
		name: String,
		createdAt: Date = Date(),
		media: MediaInfo,
		style: Style = Style(),
		camera: CameraSettings = CameraSettings(),
		cursor: CursorSettings = CursorSettings(),
		shortcutOverlay: ShortcutOverlaySettings = ShortcutOverlaySettings(),
		export: ExportSettings = ExportSettings()
	) {
		self.formatVersion = Self.currentFormatVersion
		self.id = id
		self.name = name
		// Whole seconds, so the date survives an ISO 8601 round trip unchanged.
		self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
		self.media = media
		self.cuts = []
		self.speeds = []
		self.zooms = []
		self.masks = []
		self.annotations = []
		self.captions = nil
		self.audio = AudioSettings()
		self.style = style
		self.camera = camera
		self.cursor = cursor
		self.shortcutOverlay = shortcutOverlay
		self.export = export
		self.playhead = 0
	}

	public var sourceRange: TimeRange { TimeRange(start: 0, end: media.duration) }

	public var timeMap: TimeMap { TimeMap(duration: media.duration, cuts: cuts, speeds: speeds) }
}

/// Facts about the recorded media, filled in once at import or recording time.
///
/// The video file holds the video track and, when recorded, system audio as its only audio
/// track. The microphone is a separate audio file so it can be denoised, transcribed and
/// leveled on its own.
public struct MediaInfo: Codable, Hashable, Sendable {
	/// Video file name inside the bundle.
	public var videoFile: String
	/// Microphone audio file name inside the bundle, if a mic was recorded.
	public var microphoneFile: String?
	public var duration: Double
	/// Pixel size of the recording.
	public var width: Int
	public var height: Int
	public var frameRate: Double
	public var hasSystemAudio: Bool
	/// For window and area recordings: the screen they were on and where they sat on it.
	public var screen: ScreenGeometry?

	public init(
		videoFile: String = ProjectBundle.videoFileName,
		microphoneFile: String? = nil,
		duration: Double,
		width: Int,
		height: Int,
		frameRate: Double = 60,
		hasSystemAudio: Bool = false,
		screen: ScreenGeometry? = nil
	) {
		self.videoFile = videoFile
		self.microphoneFile = microphoneFile
		self.duration = duration
		self.width = width
		self.height = height
		self.frameRate = frameRate
		self.hasSystemAudio = hasSystemAudio
		self.screen = screen
	}

	public var hasMicrophone: Bool { microphoneFile != nil }
	public var aspect: Double { Double(width) / Double(max(height, 1)) }
}

/// The screen a window or area recording came from.
public struct ScreenGeometry: Codable, Hashable, Sendable {
	/// Screen size in pixels.
	public var width: Int
	public var height: Int
	/// The recorded window or area within the screen, normalized.
	public var captureRect: NormRect

	public init(width: Int, height: Int, captureRect: NormRect) {
		self.width = width
		self.height = height
		self.captureRect = captureRect
	}

	public var aspect: Double { Double(width) / Double(max(height, 1)) }
}
