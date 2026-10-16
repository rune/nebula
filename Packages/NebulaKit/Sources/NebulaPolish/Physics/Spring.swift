import Foundation

/// A damped spring (unit mass) stepped with semi-implicit Euler at a fixed sub-step, which
/// stays stable for the stiff presets and gives the same path every time (deterministic export).
public struct Spring: Sendable {
	public var tension: Double
	public var friction: Double
	public var value: Double
	public var velocity: Double

	public init(tension: Double, friction: Double, value: Double) {
		self.tension = tension
		self.friction = friction
		self.value = value
		self.velocity = 0
	}

	static let substep = 1.0 / 480.0

	public mutating func step(toward target: Double, dt: Double) {
		var remaining = dt
		while remaining > 1e-9 {
			let h = min(Self.substep, remaining)
			let force = tension * (target - value) - friction * velocity
			velocity += force * h
			value += velocity * h
			remaining -= h
		}
	}

	public mutating func snap(to target: Double) {
		value = target
		velocity = 0
	}
}
