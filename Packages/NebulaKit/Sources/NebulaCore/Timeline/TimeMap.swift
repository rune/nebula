import Foundation

/// Maps recording (source) time to exported (output) time after cuts and speed changes.
///
/// The source timeline is split into segments at every cut and speed boundary. Cut segments
/// have no output; kept segments play at their rate. Overlapping speed items resolve to the
/// last one in the list.
public struct TimeMap: Hashable, Sendable {
	public struct Segment: Hashable, Sendable {
		public var source: TimeRange
		public var outputStart: Double
		public var rate: Double

		public var outputEnd: Double { outputStart + source.duration / rate }
	}

	public let duration: Double
	public let segments: [Segment]

	public init(duration: Double, cuts: [CutItem], speeds: [SpeedItem]) {
		self.duration = duration
		let bounds = TimeRange(start: 0, end: duration)
		let cutRanges = TimeRange.merge(cuts.compactMap { $0.range.intersection(bounds) })
		let speedRanges = speeds.compactMap { item in item.range.intersection(bounds).map { ($0, item.rate) } }

		var edges = Set([0, duration])
		for range in cutRanges { edges.insert(range.start); edges.insert(range.end) }
		for (range, _) in speedRanges { edges.insert(range.start); edges.insert(range.end) }
		let sorted = edges.sorted()

		var segments: [Segment] = []
		var output = 0.0
		for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
			let middle = (start + end) / 2
			if cutRanges.contains(where: { $0.contains(middle) }) { continue }
			let rate = speedRanges.last(where: { $0.0.contains(middle) })?.1 ?? 1
			let clampedRate = rate.clamped(to: SpeedItem.rateRange)
			let segment = Segment(source: TimeRange(start: start, end: end), outputStart: output, rate: clampedRate)
			if let last = segments.last, last.rate == clampedRate, last.source.end == start {
				segments[segments.count - 1].source.end = end
			} else {
				segments.append(segment)
			}
			output = segments[segments.count - 1].outputEnd
		}
		self.segments = segments
	}

	public var outputDuration: Double { segments.last?.outputEnd ?? 0 }

	/// Output time for a source time, or nil if that moment is cut.
	public func outputTime(forSource time: Double) -> Double? {
		guard let segment = segments.first(where: { $0.source.contains(time) || (time == $0.source.end && $0 == segments.last) }) else {
			return nil
		}
		return segment.outputStart + (time - segment.source.start) / segment.rate
	}

	/// Source time for an output time (clamped to the output duration).
	public func sourceTime(forOutput time: Double) -> Double {
		guard let first = segments.first else { return 0 }
		let t = time.clamped(to: 0...outputDuration)
		let segment = segments.last(where: { $0.outputStart <= t }) ?? first
		return min(segment.source.end, segment.source.start + (t - segment.outputStart) * segment.rate)
	}

	/// Playback rate at a source time (1 when outside speed items, 0 when cut).
	public func rate(atSource time: Double) -> Double {
		segments.first(where: { $0.source.contains(time) })?.rate ?? 0
	}

	/// The nearest source time that isn't cut (for snapping the playhead out of cuts).
	public func nearestKeptSourceTime(to time: Double) -> Double {
		if segments.contains(where: { $0.source.contains(time) }) { return time }
		let next = segments.first(where: { $0.source.start >= time })
		return next?.source.start ?? segments.last?.source.end ?? 0
	}
}
