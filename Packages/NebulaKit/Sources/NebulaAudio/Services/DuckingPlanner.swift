import NebulaCore

/// Plans a volume envelope that lowers music while someone is speaking.
public enum DuckingPlanner {
	/// Builds a gain envelope over `[0, duration]` that is 1 away from speech and `duckTo` during it.
	///
	/// The gain ramps linearly down over `attack` seconds *before* each speech range starts, so the
	/// music is already ducked when speech begins, and back up over `release` seconds after it ends.
	/// Speech ranges whose ramps would overlap are joined so the music stays ducked between them.
	/// The result is a multiplier: apply it on top of the music track's own volume.
	/// - Parameters:
	///   - speech: speech ranges in seconds (any order, may overlap).
	///   - duration: length of the envelope in seconds.
	///   - duckTo: gain while ducked, clamped to 0...1.
	///   - attack: ramp-down time in seconds.
	///   - release: ramp-up time in seconds.
	public static func envelope(
		speech: [TimeRange],
		duration: Double,
		duckTo: Double,
		attack: Double = 0.15,
		release: Double = 0.6
	) -> GainEnvelope {
		guard duration > 0, duration.isFinite else { return .unity }
		let duck = duckTo.isFinite ? duckTo.clamped(to: 0...1) : 1
		let attack = attack.isFinite ? max(0, attack) : 0
		let release = release.isFinite ? max(0, release) : 0
		let bounds = TimeRange(start: 0, end: duration)

		var regions: [TimeRange] = []
		for range in TimeRange.merge(speech.compactMap { $0.intersection(bounds) }) {
			if let last = regions.last, range.start - attack <= last.end + release {
				regions[regions.count - 1].end = max(last.end, range.end)
			} else {
				regions.append(range)
			}
		}
		guard duck < 1, !regions.isEmpty else {
			return GainEnvelope(points: [.init(time: 0, gain: 1), .init(time: duration, gain: 1)])
		}

		var points: [GainEnvelope.Point] = []
		for region in regions {
			let rampStart = region.start - attack
			if rampStart > 0 {
				if points.isEmpty { points.append(.init(time: 0, gain: 1)) }
				points.append(.init(time: rampStart, gain: 1))
			} else if points.isEmpty {
				// The ramp began before time zero: start part-way down.
				let progress = attack > 0 ? (0 - rampStart) / attack : 1
				points.append(.init(time: 0, gain: 1 + (duck - 1) * progress))
			}
			points.append(.init(time: region.start, gain: duck))
			points.append(.init(time: region.end, gain: duck))
			guard region.end < duration else { continue }
			let rampEnd = region.end + release
			if rampEnd <= duration {
				points.append(.init(time: rampEnd, gain: 1))
			} else {
				// The ramp is cut off by the end: finish part-way up.
				points.append(.init(time: duration, gain: duck + (1 - duck) * (duration - region.end) / release))
			}
		}
		if let last = points.last, last.time < duration {
			points.append(.init(time: duration, gain: last.gain))
		}
		return GainEnvelope(points: deduplicated(points))
	}

	/// Removes exact duplicate consecutive points.
	private static func deduplicated(_ points: [GainEnvelope.Point]) -> [GainEnvelope.Point] {
		var result: [GainEnvelope.Point] = []
		for point in points where result.last != point {
			result.append(point)
		}
		return result
	}
}
