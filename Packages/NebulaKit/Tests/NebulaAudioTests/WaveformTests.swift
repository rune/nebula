import Foundation
import NebulaCore
import Testing
@testable import NebulaAudio

@Suite("Waveform")
struct WaveformTests {
	@Test("Builds one peak per slice, higher in the tone section")
	func buildsPeaks() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let url = directory.appending(path: "microphone.caf")
		try TestAudio.write(mono: TestAudio.toneWithNoise(), to: url)

		let waveform = try await WaveformBuilder.build(url: url, samplesPerSecond: 50)
		#expect(waveform.samplesPerSecond == 50)
		#expect(abs(waveform.peaks.count - 250) <= 1)
		#expect(abs(waveform.duration - TestAudio.totalDuration) < 0.03)
		#expect(waveform.peaks.allSatisfy { (0...1).contains($0) })

		let tone = waveform.peak(in: TimeRange(start: 2.2, end: 3.3))
		let quiet = waveform.peak(in: TimeRange(start: 0.2, end: 1.8))
		let after = waveform.peak(in: TimeRange(start: 3.7, end: 4.8))
		#expect(tone > 0.45)
		#expect(quiet < 0.08)
		#expect(after < 0.08)
		#expect(tone > quiet * 5)
	}

	@Test("Mixes stereo to mono")
	func mixesStereo() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let url = directory.appending(path: "stereo.caf")
		let left = TestAudio.toneWithNoise()
		let right = [Float](repeating: 0, count: left.count)
		try TestAudio.write(channels: [left, right], to: url)

		let waveform = try await WaveformBuilder.build(url: url, samplesPerSecond: 20)
		#expect(abs(waveform.peaks.count - 100) <= 1)
		let tone = waveform.peak(in: TimeRange(start: 2.2, end: 3.3))
		#expect(tone > 0.22 && tone < 0.3)
	}

	@Test("Honours the requested resolution")
	func resolution() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let url = directory.appending(path: "short.wav")
		try TestAudio.write(mono: TestAudio.toneWithNoise(duration: 1, toneStart: 0, toneEnd: 1), to: url)
		let waveform = try await WaveformBuilder.build(url: url, samplesPerSecond: 7)
		#expect(waveform.peaks.count == 7)
	}

	@Test("Missing files throw fileNotFound")
	func missingFile() async throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID().uuidString).caf")
		await #expect(throws: AudioProcessingError.fileNotFound(url)) {
			try await WaveformBuilder.build(url: url)
		}
	}

	@Test("Rejects a non-positive resolution")
	func invalidResolution() async throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "unused.caf")
		await #expect(throws: AudioProcessingError.self) {
			try await WaveformBuilder.build(url: url, samplesPerSecond: 0)
		}
	}

	@Test("peak(in:) covers overlapping slices and clamps to the audio")
	func peakLookup() {
		let waveform = Waveform(samplesPerSecond: 10, peaks: [0.1, 0.2, 0.9, 0.3, 0.4])
		#expect(waveform.peak(in: TimeRange(start: 0, end: 0.5)) == 0.9)
		#expect(waveform.peak(in: TimeRange(start: 0.05, end: 0.15)) == 0.2)
		#expect(waveform.peak(in: TimeRange(start: 0.3, end: 10)) == 0.4)
		#expect(waveform.peak(in: TimeRange(start: 0.25, end: 0.25)) == 0.9)
		#expect(waveform.peak(in: TimeRange(start: 2, end: 3)) == 0)
		#expect(waveform.peak(in: TimeRange(start: -1, end: 0.05)) == 0.1)
		#expect(Waveform.empty().peak(in: TimeRange(start: 0, end: 1)) == 0)
		#expect(waveform.duration == 0.5)
	}
}
