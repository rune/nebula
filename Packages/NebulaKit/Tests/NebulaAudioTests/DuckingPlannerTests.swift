import NebulaCore
import Testing
@testable import NebulaAudio

@Suite("Ducking")
struct DuckingPlannerTests {
	private func close(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
		abs(a - b) <= tolerance
	}

	@Test("Full volume away from speech, duckTo inside, linear ramps between")
	func basicEnvelope() {
		let envelope = DuckingPlanner.envelope(
			speech: [TimeRange(start: 2, end: 4)], duration: 10, duckTo: 0.3, attack: 0.15, release: 0.6
		)
		#expect(close(envelope.gain(at: 0), 1))
		#expect(close(envelope.gain(at: 1.85), 1))
		#expect(close(envelope.gain(at: 1.925), 0.65))
		#expect(close(envelope.gain(at: 2), 0.3))
		#expect(close(envelope.gain(at: 3), 0.3))
		#expect(close(envelope.gain(at: 4), 0.3))
		#expect(close(envelope.gain(at: 4.3), 0.65))
		#expect(close(envelope.gain(at: 4.6), 1))
		#expect(close(envelope.gain(at: 9.9), 1))
		#expect(close(envelope.gain(at: 20), 1))
		#expect(envelope.points.first?.time == 0)
		#expect(envelope.points.last?.time == 10)
		#expect(zip(envelope.points, envelope.points.dropFirst()).allSatisfy { $0.time <= $1.time })
	}

	@Test("Close speech ranges stay ducked in between")
	func joinsNearbyRanges() {
		let envelope = DuckingPlanner.envelope(
			speech: [TimeRange(start: 2, end: 3), TimeRange(start: 3.5, end: 4)], duration: 10, duckTo: 0.2
		)
		#expect(close(envelope.gain(at: 3.25), 0.2))
		let apart = DuckingPlanner.envelope(
			speech: [TimeRange(start: 2, end: 3), TimeRange(start: 5, end: 6)], duration: 10, duckTo: 0.2
		)
		#expect(close(apart.gain(at: 4), 1))
	}

	@Test("Speech at the very start and end is ducked up to the edges")
	func edges() {
		let envelope = DuckingPlanner.envelope(
			speech: [TimeRange(start: 0, end: 1), TimeRange(start: 9, end: 12)], duration: 10, duckTo: 0.4
		)
		#expect(close(envelope.gain(at: 0), 0.4))
		#expect(close(envelope.gain(at: 0.5), 0.4))
		#expect(close(envelope.gain(at: 1.3), 0.7))
		#expect(close(envelope.gain(at: 5), 1))
		#expect(close(envelope.gain(at: 10), 0.4))
		#expect(envelope.points.allSatisfy { (0...10).contains($0.time) })
	}

	@Test("Ramps cut by the edges start or end part-way")
	func partialRamps() {
		let envelope = DuckingPlanner.envelope(
			speech: [TimeRange(start: 0.1, end: 1), TimeRange(start: 5, end: 9.7)],
			duration: 10, duckTo: 0, attack: 0.2, release: 0.6
		)
		#expect(close(envelope.gain(at: 0), 0.5))
		#expect(close(envelope.gain(at: 10), 0.5))
	}

	@Test("No speech or no ducking keeps full volume")
	func unity() {
		let none = DuckingPlanner.envelope(speech: [], duration: 10, duckTo: 0.3)
		#expect(close(none.gain(at: 5), 1))
		let noDuck = DuckingPlanner.envelope(speech: [TimeRange(start: 1, end: 2)], duration: 10, duckTo: 1)
		#expect(close(noDuck.gain(at: 1.5), 1))
		#expect(close(GainEnvelope.unity.gain(at: 3), 1))
		#expect(close(DuckingPlanner.envelope(speech: [], duration: 0, duckTo: 0.3).gain(at: 0), 1))
	}

	@Test("Zero attack makes an instant step")
	func instantStep() {
		let envelope = DuckingPlanner.envelope(
			speech: [TimeRange(start: 2, end: 3)], duration: 5, duckTo: 0.25, attack: 0, release: 0
		)
		#expect(close(envelope.gain(at: 1.999), 1))
		#expect(close(envelope.gain(at: 2), 0.25))
		#expect(close(envelope.gain(at: 2.999), 0.25))
		#expect(close(envelope.gain(at: 3.001), 1))
	}
}
