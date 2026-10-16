import Foundation
import NebulaCore

extension TimeMap {
	/// The output span covered by the kept parts of a source range, from the start of the
	/// first kept part to the end of the last. Nil when the whole range is cut. An empty
	/// source range maps to an empty output range at its position, if that moment is kept.
	func outputRange(forSource range: TimeRange) -> TimeRange? {
		if range.isEmpty {
			return outputTime(forSource: range.start).map { TimeRange(start: $0, end: $0) }
		}
		var start: Double?
		var end: Double?
		for segment in segments {
			guard let part = segment.source.intersection(range) else { continue }
			let partStart = segment.outputStart + (part.start - segment.source.start) / segment.rate
			let partEnd = segment.outputStart + (part.end - segment.source.start) / segment.rate
			if start == nil { start = partStart }
			end = partEnd
		}
		guard let start, let end else { return nil }
		return TimeRange(start: start, end: end)
	}

	/// True when the middle of a source range is kept (not cut).
	func keepsMiddle(of range: TimeRange) -> Bool {
		outputTime(forSource: (range.start + range.end) / 2) != nil
	}
}
