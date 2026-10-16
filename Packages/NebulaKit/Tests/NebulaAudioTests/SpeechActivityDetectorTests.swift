import Foundation
import NebulaCore
import Testing
@testable import NebulaAudio

@Suite("Speech activity")
struct SpeechActivityDetectorTests {
	/// Builds a level sequence from (seconds, linear level) segments at 20 ms frames.
	private func levels(_ segments: [(Double, Float)], frameDuration: Double = 0.02) -> [Float] {
		segments.flatMap { duration, level in
			[Float](repeating: level, count: Int((duration / frameDuration).rounded()))
		}
	}

	@Test("Finds the tone section of a file")
	func detectsToneInFile() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let url = directory.appending(path: "microphone.caf")
		try TestAudio.write(mono: TestAudio.toneWithNoise(), to: url)

		let ranges = try await SpeechActivityDetector.detect(url: url)
		#expect(ranges.count == 1)
		let range = try #require(ranges.first)
		#expect(abs(range.start - TestAudio.toneStart) <= 0.15)
		#expect(abs(range.end - TestAudio.toneEnd) <= 0.15)
	}

	@Test("Finds a single burst in levels")
	func singleBurst() throws {
		let input = levels([(2, 0.001), (1, 0.3), (2, 0.001)])
		let ranges = SpeechActivityDetector.detect(levels: input, frameDuration: 0.02)
		#expect(ranges.count == 1)
		let range = try #require(ranges.first)
		#expect(abs(range.start - 2) <= 0.1)
		#expect(abs(range.end - 3) <= 0.1)
	}

	@Test("Drops blips shorter than 0.2 s")
	func dropsBlips() {
		let input = levels([(2, 0.001), (0.06, 0.3), (2, 0.001)])
		#expect(SpeechActivityDetector.detect(levels: input, frameDuration: 0.02).isEmpty)
	}

	@Test("Merges gaps shorter than 0.35 s and keeps longer ones apart")
	func mergesGaps() {
		let short = levels([(1, 0.001), (0.5, 0.2), (0.3, 0.001), (0.5, 0.2), (1, 0.001)])
		#expect(SpeechActivityDetector.detect(levels: short, frameDuration: 0.02).count == 1)

		let long = levels([(1, 0.001), (0.5, 0.2), (1.0, 0.001), (0.5, 0.2), (1, 0.001)])
		let ranges = SpeechActivityDetector.detect(levels: long, frameDuration: 0.02)
		#expect(ranges.count == 2)
		if ranges.count == 2 {
			#expect(ranges[0].end < ranges[1].start)
		}
	}

	@Test("Hangover bridges short dips above the offset threshold")
	func hysteresis() {
		// A dip that stays 8 dB above the floor (between offset and onset margins) does not split the segment.
		let input = levels([(2, 0.001), (0.5, 0.2), (0.6, 0.0025), (0.5, 0.2), (2, 0.001)])
		let ranges = SpeechActivityDetector.detect(levels: input, frameDuration: 0.02)
		#expect(ranges.count == 1)
	}

	@Test("Long continuous speech does not become its own noise floor")
	func sustainedSpeech() throws {
		let input = levels([(3, 0.003), (20, 0.2), (3, 0.003)])
		let ranges = SpeechActivityDetector.detect(levels: input, frameDuration: 0.02)
		#expect(ranges.count == 1)
		let range = try #require(ranges.first)
		#expect(abs(range.start - 3) <= 0.1)
		#expect(abs(range.end - 23) <= 0.1)
	}

	@Test("Constant noise and silence produce no speech")
	func noSpeech() {
		#expect(SpeechActivityDetector.detect(levels: levels([(5, 0.01)]), frameDuration: 0.02).isEmpty)
		#expect(SpeechActivityDetector.detect(levels: levels([(5, 0)]), frameDuration: 0.02).isEmpty)
		#expect(SpeechActivityDetector.detect(levels: [], frameDuration: 0.02).isEmpty)
		#expect(SpeechActivityDetector.detect(levels: [0.5, 0.5], frameDuration: 0).isEmpty)
	}

	@Test("Quiet speech under the absolute threshold is ignored")
	func absoluteThreshold() {
		// -66 dBFS bursts over a -80 dBFS floor are too quiet to be speech.
		let input = levels([(2, 0.0001), (1, 0.0005), (2, 0.0001)])
		#expect(SpeechActivityDetector.detect(levels: input, frameDuration: 0.02).isEmpty)
	}

	@Test("Digital silence does not lower the noise floor")
	func digitalSilence() {
		// Zeros, then steady -46 dBFS noise: the noise must not count as speech.
		let input = levels([(2, 0), (6, 0.005)])
		#expect(SpeechActivityDetector.detect(levels: input, frameDuration: 0.02).isEmpty)
	}

	@Test("Speech at the edges is clamped to the levels' extent")
	func edges() throws {
		let input = levels([(1, 0.3), (2, 0.001), (1, 0.3)])
		let ranges = SpeechActivityDetector.detect(levels: input, frameDuration: 0.02)
		#expect(ranges.count == 2)
		#expect(ranges.first?.start == 0)
		let last = try #require(ranges.last)
		#expect(abs(last.end - 4) < 1e-9)
	}
}
