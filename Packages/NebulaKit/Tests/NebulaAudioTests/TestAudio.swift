import AVFoundation
import Foundation
import Testing
@testable import NebulaAudio

/// Generates deterministic test audio files.
enum TestAudio {
	static let sampleRate = 48_000.0
	/// Layout of the standard test signal: noise, then tone + noise, then noise.
	static let toneStart = 2.0
	static let toneEnd = 3.5
	static let totalDuration = 5.0
	static let toneAmplitude: Float = 0.5
	static let noiseLevel: Float = 0.01

	/// A fresh temporary directory, removed by `cleanUp`.
	static func makeDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appending(path: "NebulaAudioTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	static func cleanUp(_ url: URL) {
		try? FileManager.default.removeItem(at: url)
	}

	/// 2 s of low noise, 1.5 s of a 440 Hz tone plus the same noise, then 1.5 s of noise.
	static func toneWithNoise(
		duration: Double = totalDuration,
		toneStart: Double = toneStart,
		toneEnd: Double = toneEnd,
		seed: UInt64 = 1
	) -> [Float] {
		var random = SplitMix64(seed: seed)
		let count = Int(duration * sampleRate)
		var samples = [Float](repeating: 0, count: count)
		for index in 0..<count {
			let time = Double(index) / sampleRate
			var value = noiseLevel * random.nextGaussian()
			if time >= toneStart, time < toneEnd {
				value += toneAmplitude * Float(sin(2 * Double.pi * 440 * time))
			}
			samples[index] = value
		}
		return samples
	}

	/// Writes Float32 linear PCM (`.caf` / `.wav` / `.aiff` by extension). `channels[c]` is channel `c`.
	static func write(channels: [[Float]], to url: URL, sampleRate: Double = sampleRate) throws {
		let channelCount = channels.count
		let frames = channels.first?.count ?? 0
		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: sampleRate,
			AVNumberOfChannelsKey: channelCount,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		]
		let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
		let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
		buffer.frameLength = AVAudioFrameCount(frames)
		let data = try #require(buffer.floatChannelData)
		for (channel, samples) in channels.enumerated() {
			for index in 0..<frames {
				data[channel][index] = samples[index]
			}
		}
		try file.write(from: buffer)
		file.close()
	}

	static func write(mono samples: [Float], to url: URL, sampleRate: Double = sampleRate) throws {
		try write(channels: [samples], to: url, sampleRate: sampleRate)
	}

	/// Decodes a file to mono samples with the module's own reader.
	static func readMono(_ url: URL) async throws -> (samples: [Float], sampleRate: Double) {
		let source = try #require(try await AudioSource.load(url: url))
		let samples = try await BlockingWork.run { _ in
			let reader = try source.makeReader()
			var samples: [Float] = []
			while let chunk = try reader.nextChunk() {
				samples.append(contentsOf: chunk)
			}
			return samples
		}
		return (samples, source.sampleRate)
	}

	/// Duration of the first audio track as reported by AVFoundation.
	static func duration(of url: URL) async throws -> Double {
		let asset = AVURLAsset(url: url)
		let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
		return try await track.load(.timeRange).duration.seconds
	}

	/// RMS of `samples` between `start` and `end` seconds.
	static func rms(_ samples: [Float], from start: Double, to end: Double, sampleRate: Double = sampleRate) -> Float {
		let lower = max(0, Int(start * sampleRate))
		let upper = min(samples.count, Int(end * sampleRate))
		guard lower < upper else { return 0 }
		var sum: Double = 0
		for index in lower..<upper {
			sum += Double(samples[index] * samples[index])
		}
		return Float((sum / Double(upper - lower)).squareRoot())
	}
}

/// Small deterministic random number generator.
struct SplitMix64 {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}

	/// Uniform in [0, 1).
	mutating func nextUniform() -> Double {
		Double(next() >> 11) / Double(1 << 53)
	}

	/// Standard normal sample (Box–Muller).
	mutating func nextGaussian() -> Float {
		let u1 = max(nextUniform(), 1e-12)
		let u2 = nextUniform()
		return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
	}
}
