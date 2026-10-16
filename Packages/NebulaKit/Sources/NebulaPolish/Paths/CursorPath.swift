import Foundation
import NebulaCore

/// The cursor as it is drawn: smoothed position, shape, fade-out when idle and click pulses.
/// Precomputed once per project change so every frame is a cheap lookup.
public struct CursorPath: Sendable {
	public struct State: Sendable, Equatable {
		public var position: NormPoint
		/// Index into the input track's cursor shapes, or -1 when hidden.
		public var shape: Int
		/// 0–1, for idle fade-out.
		public var opacity: Double
		/// Speed in normalized units per second, for motion blur.
		public var velocity: (dx: Double, dy: Double)
		/// 0–1 progress of the most recent click effect, nil when none is playing.
		public var clickProgress: Double?
		public var clickPoint: NormPoint?
		/// Multiplier for the click "bounce".
		public var pressScale: Double

		public static func == (lhs: State, rhs: State) -> Bool {
			lhs.position == rhs.position && lhs.shape == rhs.shape && lhs.opacity == rhs.opacity
		}
	}

	public static let sampleRate = 120.0
	static let clickEffectDuration = 0.45

	public let start: Double
	let positions: [NormPoint]
	let shapes: [Int]
	let opacity: [Double]
	let clicks: [ClickEvent]
	let bounce: Bool

	/// Empty path (no telemetry): no cursor is drawn.
	public var isEmpty: Bool { positions.isEmpty }

	public init(input: InputTrack, settings: CursorSettings, duration: Double) {
		let samples = input.cursor.sorted { $0.t < $1.t }
		bounce = settings.clickBounce
		clicks = input.clicks.sorted { $0.t < $1.t }
		guard let first = samples.first, duration > 0 else {
			start = 0
			positions = []
			shapes = []
			opacity = []
			return
		}
		start = 0
		let count = Int((duration * Self.sampleRate).rounded(.up)) + 1
		let dt = 1 / Self.sampleRate

		// Smoothing maps to a critically damped spring: 0 → very stiff (raw), 1 → loose.
		let smoothing = settings.smoothing.clamped(to: 0...1)
		let stiffness = 2400 * pow(0.02, smoothing) + 40
		var springX = Spring(tension: stiffness, friction: 2 * sqrt(stiffness), value: first.x)
		var springY = Spring(tension: stiffness, friction: 2 * sqrt(stiffness), value: first.y)

		var positions = [NormPoint]()
		var shapes = [Int]()
		var lastMove = first.t
		var lastRaw = first.point
		var idle = [Double]()
		positions.reserveCapacity(count)
		var cursorIndex = 0
		var clickIndex = 0
		let sortedClicks = clicks
		for i in 0..<count {
			let t = Double(i) * dt
			while cursorIndex + 1 < samples.count, samples[cursorIndex + 1].t <= t { cursorIndex += 1 }
			while clickIndex < sortedClicks.count, sortedClicks[clickIndex].t < t - dt { clickIndex += 1 }
			let raw = Self.interpolate(samples, index: cursorIndex, time: t)
			// Compare against where the cursor last "settled", so slow drags still count as movement.
			if raw.distance(to: lastRaw) > 0.003 {
				lastMove = t
				lastRaw = raw
			}
			// Clicks pin the cursor exactly where the click happened, so effects line up.
			if clickIndex < sortedClicks.count, abs(sortedClicks[clickIndex].t - t) < dt {
				let click = sortedClicks[clickIndex]
				lastMove = t
				springX.snap(to: click.x)
				springY.snap(to: click.y)
			} else if smoothing < 0.02 {
				springX.snap(to: raw.x)
				springY.snap(to: raw.y)
			} else {
				springX.step(toward: raw.x, dt: dt)
				springY.step(toward: raw.y, dt: dt)
			}
			positions.append(NormPoint(x: springX.value, y: springY.value))
			shapes.append(samples[cursorIndex].shape)
			if settings.hideWhenIdle {
				let still = t - lastMove
				let fade = ((still - settings.idleDelay) / 0.35).clamped(to: 0...1)
				idle.append(1 - fade)
			} else {
				idle.append(1)
			}
		}
		// Fade back in slightly *before* movement resumes so the cursor never pops in.
		var lead = idle
		let leadFrames = Int(0.2 * Self.sampleRate)
		for i in idle.indices where idle[i] > 0.99 {
			for j in max(0, i - leadFrames)..<i { lead[j] = max(lead[j], Double(j - (i - leadFrames)) / Double(leadFrames)) }
		}
		self.positions = positions
		self.shapes = shapes
		self.opacity = lead
	}

	private static func interpolate(_ samples: [CursorSample], index: Int, time: Double) -> NormPoint {
		let a = samples[index]
		guard index + 1 < samples.count else { return a.point }
		let b = samples[index + 1]
		// Samples are written on movement, so a long gap means the cursor held still at `a`
		// and only moved right before `b`.
		let moveStart = b.t - a.t > 0.25 ? b.t - 0.05 : a.t
		let span = b.t - moveStart
		guard span > 0, time > moveStart else { return a.point }
		let f = ((time - moveStart) / span).clamped(to: 0...1)
		return NormPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
	}

	/// Cursor state at a source time.
	public func state(at time: Double) -> State? {
		guard !positions.isEmpty else { return nil }
		let f = (time * Self.sampleRate).clamped(to: 0...Double(positions.count - 1))
		let i = Int(f)
		let j = min(i + 1, positions.count - 1)
		let w = f - Double(i)
		let p = NormPoint(x: positions[i].x + (positions[j].x - positions[i].x) * w, y: positions[i].y + (positions[j].y - positions[i].y) * w)
		let prev = positions[max(0, i - 1)]
		let velocity = (dx: (positions[j].x - prev.x) * Self.sampleRate / 2, dy: (positions[j].y - prev.y) * Self.sampleRate / 2)

		var clickProgress: Double?
		var clickPoint: NormPoint?
		var pressScale = 1.0
		if let click = clicks.last(where: { $0.t <= time && time - $0.t < Self.clickEffectDuration }) {
			clickProgress = (time - click.t) / Self.clickEffectDuration
			clickPoint = click.point
		}
		if bounce, let click = clicks.last(where: { $0.t <= time }) {
			let held = (click.upT ?? click.t + 0.08)
			if time <= held {
				pressScale = 0.82
			} else if time - held < 0.18 {
				// Overshoot back to full size.
				let k = (time - held) / 0.18
				pressScale = 0.82 + 0.18 * (1 - pow(1 - k, 3)) + 0.06 * sin(k * .pi)
			}
		}
		return State(
			position: p,
			shape: shapes[i],
			opacity: opacity[i],
			velocity: velocity,
			clickProgress: clickProgress,
			clickPoint: clickPoint,
			pressScale: pressScale
		)
	}
}
