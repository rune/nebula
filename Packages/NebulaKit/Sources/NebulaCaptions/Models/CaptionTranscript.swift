import Foundation
import NebulaCore

/// The result of transcribing a recording.
public struct CaptionTranscript: Sendable, Hashable {
	/// Speech segments in source time, with word timings. Pass them through
	/// ``CaptionLayout/lines(for:maxCharacters:)`` before showing them as captions.
	public var segments: [CaptionSegment]
	/// The spoken language code (for example "en"), detected when none was requested.
	public var language: String?

	public init(segments: [CaptionSegment], language: String?) {
		self.segments = segments
		self.language = language
	}
}
