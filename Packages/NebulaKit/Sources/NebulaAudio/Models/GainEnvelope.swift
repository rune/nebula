/// A piecewise-linear volume envelope over time (seconds), e.g. music ducked under speech.
///
/// Points must be sorted by time. Two points at the same time form an instant step.
/// Before the first point the first gain applies, after the last point the last gain applies,
/// and an envelope without points has a gain of 1 everywhere.
public struct GainEnvelope: Sendable, Hashable {
	/// One breakpoint of the envelope.
	public struct Point: Sendable, Hashable {
		/// Time in seconds.
		public var time: Double
		/// Linear gain multiplier (1 = unchanged).
		public var gain: Double

		public init(time: Double, gain: Double) {
			self.time = time
			self.gain = gain
		}
	}

	/// Breakpoints sorted by time.
	public var points: [Point]

	public init(points: [Point]) {
		self.points = points
	}

	/// A flat envelope at full volume.
	public static let unity = GainEnvelope(points: [])

	/// The gain at `time`, linearly interpolated between breakpoints.
	public func gain(at time: Double) -> Double {
		guard let first = points.first, let last = points.last else { return 1 }
		if time < first.time { return first.gain }
		if time >= last.time { return last.gain }
		// First point strictly after `time`.
		var low = 0
		var high = points.count - 1
		while low < high {
			let mid = (low + high) / 2
			if points[mid].time > time {
				high = mid
			} else {
				low = mid + 1
			}
		}
		let after = points[low]
		let before = points[max(0, low - 1)]
		let span = after.time - before.time
		guard span > 0 else { return after.gain }
		return before.gain + (after.gain - before.gain) * (time - before.time) / span
	}
}
