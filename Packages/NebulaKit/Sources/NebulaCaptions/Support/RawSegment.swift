import Foundation

/// A recognizer segment, independent of the recognizer library. Times are in seconds.
struct RawSegment: Sendable, Hashable {
	/// A recognized word; `text` keeps its leading space, if any.
	struct Word: Sendable, Hashable {
		var text: String
		var start: Double
		var end: Double
	}

	var text: String
	var start: Double
	var end: Double
	var words: [Word]
}
