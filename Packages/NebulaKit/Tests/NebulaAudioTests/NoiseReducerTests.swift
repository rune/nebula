import Foundation
import Synchronization
import Testing
@testable import NebulaAudio

@Suite("Noise reduction")
struct NoiseReducerTests {
	@Test("Keeps the duration, lowers the noise and keeps the tone")
	func reducesNoise() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let input = directory.appending(path: "microphone.caf")
		let output = directory.appending(path: "denoised.m4a")
		let original = TestAudio.toneWithNoise()
		try TestAudio.write(mono: original, to: input)

		let updates = Mutex<[Double]>([])
		try await NoiseReducer.process(input: input, output: output, strength: 0.8) { value in
			updates.withLock { $0.append(value) }
		}

		#expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
		let duration = try await TestAudio.duration(of: output)
		#expect(abs(duration - TestAudio.totalDuration) <= 0.05)

		let (processed, sampleRate) = try await TestAudio.readMono(output)
		#expect(sampleRate == TestAudio.sampleRate)
		#expect(abs(Double(processed.count) / sampleRate - TestAudio.totalDuration) <= 0.05)

		let noiseBefore = TestAudio.rms(original, from: 0.5, to: 1.5)
		let noiseAfter = TestAudio.rms(processed, from: 0.5, to: 1.5)
		let tailBefore = TestAudio.rms(original, from: 4.0, to: 4.8)
		let tailAfter = TestAudio.rms(processed, from: 4.0, to: 4.8)
		let toneBefore = TestAudio.rms(original, from: 2.2, to: 3.3)
		let toneAfter = TestAudio.rms(processed, from: 2.2, to: 3.3)
		// At least 12 dB less noise, and the tone within 1 dB.
		#expect(noiseAfter < noiseBefore / 4)
		#expect(tailAfter < tailBefore / 4)
		#expect(abs(20 * log10(toneAfter / toneBefore)) < 1)

		let progress = updates.withLock { $0 }
		#expect(progress.first == 0)
		#expect(progress.last == 1)
		#expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
	}

	@Test("Strength 0 leaves the signal essentially unchanged")
	func zeroStrength() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let input = directory.appending(path: "in.caf")
		let output = directory.appending(path: "out.m4a")
		let original = TestAudio.toneWithNoise()
		try TestAudio.write(mono: original, to: input)

		try await NoiseReducer.process(input: input, output: output, strength: 0)
		let (processed, _) = try await TestAudio.readMono(output)
		let before = TestAudio.rms(original, from: 0.5, to: 1.5)
		let after = TestAudio.rms(processed, from: 0.5, to: 1.5)
		#expect(abs(20 * log10(after / before)) < 1)
	}

	@Test("STFT round trip with unity gain reconstructs the input")
	func perfectReconstruction() throws {
		let gate = try #require(SpectralGate(sampleRate: 48_000, strength: 0))
		let input = TestAudio.toneWithNoise(duration: 0.5, toneStart: 0, toneEnd: 0.5)
		// Noise profile of zero opens every bin; strength 0 also sets the floor to 1.
		let size = gate.size
		let hop = gate.hop
		var frames = FrameBuffer(size: size, hop: hop, leadingZeros: size - hop)
		frames.append(input)
		frames.appendZeros(size + hop)
		var overlap = [Float](repeating: 0, count: size)
		var output: [Float] = []
		var frame = [Float](repeating: 0, count: size)
		while frames.nextFrame(into: &frame) {
			let processed = gate.process(frame)
			for index in 0..<size { overlap[index] += processed[index] }
			output.append(contentsOf: overlap[0..<hop])
			overlap.removeFirst(hop)
			overlap.append(contentsOf: repeatElement(0, count: hop))
		}
		let aligned = Array(output.dropFirst(size - hop).prefix(input.count))
		#expect(aligned.count == input.count)
		let maxError = zip(aligned, input).map { abs($0 - $1) }.max() ?? 1
		#expect(maxError < 1e-4)
	}

	@Test("Replaces an existing output file")
	func replacesOutput() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let input = directory.appending(path: "in.caf")
		let output = directory.appending(path: "out.m4a")
		try TestAudio.write(mono: TestAudio.toneWithNoise(duration: 1), to: input)
		try Data("old".utf8).write(to: output)

		try await NoiseReducer.process(input: input, output: output)
		let duration = try await TestAudio.duration(of: output)
		#expect(abs(duration - 1) <= 0.05)
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
		#expect(Set(leftovers) == ["in.caf", "out.m4a"])
	}

	@Test("Missing input throws and writes nothing")
	func missingInput() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let input = directory.appending(path: "missing.caf")
		let output = directory.appending(path: "out.m4a")
		await #expect(throws: AudioProcessingError.fileNotFound(input)) {
			try await NoiseReducer.process(input: input, output: output)
		}
		#expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
	}

	@Test("Processes a minute of audio in reasonable time")
	func minuteOfAudio() async throws {
		let directory = try TestAudio.makeDirectory()
		defer { TestAudio.cleanUp(directory) }
		let input = directory.appending(path: "minute.caf")
		let output = directory.appending(path: "minute.m4a")
		try TestAudio.write(mono: TestAudio.toneWithNoise(duration: 60, toneStart: 10, toneEnd: 40), to: input)

		let clock = ContinuousClock()
		let elapsed = try await clock.measure {
			try await NoiseReducer.process(input: input, output: output)
		}
		let duration = try await TestAudio.duration(of: output)
		#expect(abs(duration - 60) <= 0.05)
		// Generous bound: debug builds are far slower than release.
		#expect(elapsed < .seconds(20))
		let speech = try await SpeechActivityDetector.detect(url: input)
		#expect(speech.count == 1)
	}
}
