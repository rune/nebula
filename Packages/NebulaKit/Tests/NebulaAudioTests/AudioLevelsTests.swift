import Foundation
import Testing
@testable import NebulaAudio

@Suite("Audio levels")
struct AudioLevelsTests {
	@Test("RMS per frame matches the generated signal")
	func rmsLevels() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let url = directory.appending(path: "levels.caf")
		try TestAudio.write(mono: TestAudio.toneWithNoise(), to: url)

		let levels = try await AudioLevels.rmsLevels(url: url, frameDuration: 0.02)
		#expect(levels.count == 250)
		// Frames 110...170 are inside the tone (2.2–3.4 s): RMS ≈ 0.5 / √2.
		for level in levels[110...170] {
			#expect(abs(level - 0.3537) < 0.01)
		}
		// Frames 10...90 are noise only: RMS ≈ 0.01.
		for level in levels[10...90] {
			#expect(level > 0.006 && level < 0.014)
		}
	}

	@Test("Fractional frame lengths do not drift")
	func fractionalFrames() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let url = directory.appending(path: "fractional.caf")
		try TestAudio.write(mono: TestAudio.toneWithNoise(duration: 3), to: url)
		// 48 000 × 0.0133 = 638.4 samples per frame.
		let levels = try await AudioLevels.rmsLevels(url: url, frameDuration: 0.0133)
		#expect(levels.count == Int((3 / 0.0133).rounded(.up)))
	}

	@Test("Accumulator splits frames at rounded boundaries across chunks")
	func accumulator() {
		var accumulator = FrameStatsAccumulator(samplesPerFrame: 2.5)
		accumulator.append([1, -2, 3])
		accumulator.append([0, 0, 4, 1])
		accumulator.finish()
		// Boundaries at 3 (round 2.5 up), 5, 8: frames [1,-2,3], [0,0], [4,1].
		#expect(accumulator.peaks == [1, 0, 1])
		#expect(accumulator.rms.count == 3)
		#expect(accumulator.sampleCount == 7)
	}
}
