import Foundation

/// A clip on the edited timeline: a kept stretch of the recording that plays at one rate.
///
/// Clips aren't stored. They are derived from the cuts, speed changes and split points, so the
/// editor can work like a video editor (split, ripple-delete, trim, speed per clip) while the
/// project keeps one simple representation that MCP clients and Polish also write.
public struct Clip: Hashable, Sendable, Identifiable {
	public var index: Int
	/// Part of the recording this clip plays.
	public var source: TimeRange
	/// Where it starts in the exported video.
	public var outputStart: Double
	public var rate: Double

	public var id: Int { index }
	public var outputDuration: Double { source.duration / rate }
	public var outputEnd: Double { outputStart + outputDuration }
	public var output: TimeRange { TimeRange(start: outputStart, end: outputEnd) }
}

extension TimeMap {
	static let epsilon = 1e-4

	/// Kept segments, further divided at `splits` (source times).
	public func clips(splits: [Double]) -> [Clip] {
		var clips: [Clip] = []
		for segment in segments {
			let inner = splits.filter { $0 > segment.source.start + Self.epsilon && $0 < segment.source.end - Self.epsilon }.sorted()
			var start = segment.source.start
			for edge in inner + [segment.source.end] {
				let source = TimeRange(start: start, end: edge)
				let outputStart = segment.outputStart + (start - segment.source.start) / segment.rate
				clips.append(Clip(index: clips.count, source: source, outputStart: outputStart, rate: segment.rate))
				start = edge
			}
		}
		return clips
	}

	/// The output span of a source range: from its first kept moment to its last. Nil if all of
	/// it is cut.
	public func outputRange(forSource range: TimeRange) -> TimeRange? {
		var start: Double?
		var end: Double?
		for segment in segments {
			guard let part = segment.source.intersection(range) else { continue }
			let a = segment.outputStart + (part.start - segment.source.start) / segment.rate
			let b = segment.outputStart + (part.end - segment.source.start) / segment.rate
			start = min(start ?? a, a)
			end = max(end ?? b, b)
		}
		guard let start, let end else { return nil }
		return TimeRange(start: start, end: end)
	}

	/// True when `time` is inside kept material (not cut).
	func isKept(_ time: Double) -> Bool {
		segments.contains { $0.source.contains(time) }
	}
}

extension Project {
	public enum ClipEdge: Sendable {
		case start, end
	}

	/// Shortest clip a trim may leave, in source seconds.
	public static let minimumClipLength = 0.1

	public var clips: [Clip] { timeMap.clips(splits: splits ?? []) }

	/// The clip playing at a source time.
	public func clip(atSource time: Double) -> Clip? {
		clips.first { $0.source.contains(time) } ?? clips.last.flatMap { abs($0.source.end - time) < TimeMap.epsilon ? $0 : nil }
	}

	/// Splits the clip under `time` in two. Returns false when there is nothing to split.
	@discardableResult
	public mutating func split(atSource time: Double) -> Bool {
		guard let clip = clip(atSource: time),
		      time > clip.source.start + TimeMap.epsilon, time < clip.source.end - TimeMap.epsilon else { return false }
		splits = ((splits ?? []) + [time]).sorted()
		return true
	}

	/// Removes a clip; everything after it moves up (a ripple delete).
	public mutating func deleteClip(_ clip: Clip) {
		cuts.append(CutItem(range: clip.source))
		normalizeSplits()
	}

	/// Plays a clip at `rate` (1 = normal speed).
	public mutating func setRate(_ rate: Double, for clip: Clip) {
		setRate(rate, over: clip.source)
	}

	mutating func setRate(_ rate: Double, over range: TimeRange) {
		speeds = speeds.flatMap { speed -> [SpeedItem] in
			guard speed.range.overlaps(range) else { return [speed] }
			return TimeRange.subtract([speed.range], [range]).enumerated().map { index, piece in
				SpeedItem(id: index == 0 ? speed.id : .make("speed"), range: piece, rate: speed.rate, source: speed.source)
			}
		}
		if abs(rate - 1) > 1e-6 {
			speeds.append(SpeedItem(range: range, rate: rate.clamped(to: SpeedItem.rateRange)))
		}
		// Keep the clip's edges even when its speed returns to normal.
		splits = (splits ?? []) + [range.start, range.end]
		normalizeSplits()
	}

	/// Moves one edge of a clip to a source time. Trimming in removes material (ripple); trimming
	/// out brings back material that was cut, up to the neighbouring clip.
	public mutating func trim(_ clip: Clip, edge: ClipEdge, toSource time: Double) {
		let map = timeMap
		switch edge {
		case .end:
			// A clip that touches the next one can't grow; otherwise it can grow into the cut.
			let limit = map.isKept(clip.source.end) && clip.source.end < media.duration - TimeMap.epsilon
				? clip.source.end
				: map.segments.first(where: { $0.source.start >= clip.source.end - TimeMap.epsilon && $0.source.start > clip.source.start })?.source.start ?? media.duration
			let end = time.clamped(to: (clip.source.start + Self.minimumClipLength)...max(limit, clip.source.start + Self.minimumClipLength))
			if end < clip.source.end - TimeMap.epsilon {
				cuts.append(CutItem(range: TimeRange(start: end, end: clip.source.end)))
			} else if end > clip.source.end + TimeMap.epsilon {
				restore(TimeRange(start: clip.source.end, end: end))
				setRate(clip.rate, over: TimeRange(start: clip.source.start, end: end))
			}
		case .start:
			let limit = map.isKept(clip.source.start - TimeMap.epsilon)
				? clip.source.start
				: map.segments.last(where: { $0.source.end <= clip.source.start + TimeMap.epsilon && $0.source.end < clip.source.end })?.source.end ?? 0
			let start = time.clamped(to: min(limit, clip.source.end - Self.minimumClipLength)...(clip.source.end - Self.minimumClipLength))
			if start > clip.source.start + TimeMap.epsilon {
				cuts.append(CutItem(range: TimeRange(start: clip.source.start, end: start)))
			} else if start < clip.source.start - TimeMap.epsilon {
				restore(TimeRange(start: start, end: clip.source.start))
				setRate(clip.rate, over: TimeRange(start: start, end: clip.source.end))
			}
		}
		normalizeSplits()
	}

	/// Un-cuts a source range.
	public mutating func restore(_ range: TimeRange) {
		cuts = cuts.flatMap { cut -> [CutItem] in
			guard cut.range.overlaps(range) else { return [cut] }
			return TimeRange.subtract([cut.range], [range]).enumerated().map { index, piece in
				CutItem(id: index == 0 ? cut.id : .make("cut"), range: piece, source: cut.source)
			}
		}
	}

	/// Drops split points that no longer divide kept material.
	mutating func normalizeSplits() {
		let segments = timeMap.segments
		let kept = (splits ?? []).filter { time in
			segments.contains { time > $0.source.start + TimeMap.epsilon && time < $0.source.end - TimeMap.epsilon }
		}
		var unique: [Double] = []
		for time in kept.sorted() where unique.last.map({ time - $0 > TimeMap.epsilon }) ?? true {
			unique.append(time)
		}
		splits = unique.isEmpty ? nil : unique
	}
}
