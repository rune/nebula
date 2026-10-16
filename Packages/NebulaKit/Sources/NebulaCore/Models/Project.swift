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
public struct MediaInfo: Codable, Hashable, Sendable {
	/// Video file name inside the bundle.
	public var videoFile: String
	public var duration: Double
	/// Pixel size of the recording.
	public var width: Int
	public var height: Int
	public var frameRate: Double
	public var hasSystemAudio: Bool
	public var hasMicrophone: Bool

	public init(
		videoFile: String = ProjectBundle.videoFileName,
		duration: Double,
		width: Int,
		height: Int,
		frameRate: Double = 60,
		hasSystemAudio: Bool = false,
		hasMicrophone: Bool = false
	) {
		self.videoFile = videoFile
		self.duration = duration
		self.width = width
		self.height = height
		self.frameRate = frameRate
		self.hasSystemAudio = hasSystemAudio
		self.hasMicrophone = hasMicrophone
	}

	public var aspect: Double { Double(width) / Double(max(height, 1)) }
}
