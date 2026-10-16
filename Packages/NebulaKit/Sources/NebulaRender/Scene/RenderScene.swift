import Foundation
import NebulaCore
import NebulaPolish

/// An immutable snapshot of everything needed to draw any frame of a project. Built on every
/// edit (cheap: the expensive parts are the camera and cursor paths) and handed to the
/// compositor, preview and export.
public struct RenderScene: Sendable {
	public let project: Project
	public let input: InputTrack
	public let timeMap: TimeMap
	public let camera: CameraPath
	public let cursor: CursorPath
	/// Caption lines (already split to caption length), in source time.
	public let captionLines: [CaptionSegment]
	/// Shortcut presses shown as keycaps, in source time.
	public let shortcuts: [KeyEvent]
	/// Resolves relative media paths (custom background images).
	public let bundleURL: URL?

	/// `previous` lets an edit reuse the camera and cursor paths (the expensive part) when their
	/// inputs didn't change, which is true for every style edit and slider drag.
	public init(project: Project, input: InputTrack, captionLines: [CaptionSegment]? = nil, bundleURL: URL?, reusing previous: RenderScene? = nil) {
		self.project = project
		self.input = input
		self.timeMap = project.timeMap
		let old = previous?.project
		let sameCursor = old != nil && old?.cursor == project.cursor && old?.media.duration == project.media.duration && previous?.input == input
		let cursor = sameCursor ? previous!.cursor : CursorPath(input: input, settings: project.cursor, duration: project.media.duration)
		self.cursor = cursor
		let sameCamera = sameCursor && old?.camera == project.camera && old?.zooms == project.zooms
			&& old?.cuts == project.cuts && old?.speeds == project.speeds
		self.camera = sameCamera ? previous!.camera : CameraPath(project: project, cursor: cursor)
		self.captionLines = captionLines ?? project.captions?.segments ?? []
		self.shortcuts = input.keys.filter { $0.kind == .shortcut && !$0.keys.isEmpty }.sorted { $0.t < $1.t }
		self.bundleURL = bundleURL
	}

	public var outputDuration: Double { timeMap.outputDuration }
}

/// How hard the compositor works on a frame.
public struct RenderQuality: Sendable, Hashable {
	public var motionBlur: Bool

	public init(motionBlur: Bool) {
		self.motionBlur = motionBlur
	}

	public static let export = RenderQuality(motionBlur: true)
	public static let preview = RenderQuality(motionBlur: true)
	/// While scrubbing: skip the expensive effects.
	public static let draft = RenderQuality(motionBlur: false)
}
