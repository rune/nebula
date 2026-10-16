import Accelerate

/// Splits a stream of mono samples into fixed-length frames and records each frame's peak and RMS.
///
/// Frame boundaries are placed at `round(index * samplesPerFrame)`, so a fractional frame length
/// does not drift over long files. A trailing partial frame is kept.
struct FrameStatsAccumulator {
	let samplesPerFrame: Double
	private(set) var peaks: [Float] = []
	private(set) var rms: [Float] = []
	private(set) var sampleCount = 0

	private var frameIndex = 0
	private var frameEnd: Int
	private var currentPeak: Float = 0
	private var currentSquares: Double = 0
	private var currentCount = 0

	init(samplesPerFrame: Double, expectedSamples: Int = 0) {
		self.samplesPerFrame = max(1, samplesPerFrame)
		self.frameEnd = Int(self.samplesPerFrame.rounded())
		if expectedSamples > 0 {
			let frames = Int((Double(expectedSamples) / self.samplesPerFrame).rounded(.up)) + 1
			peaks.reserveCapacity(frames)
			rms.reserveCapacity(frames)
		}
	}

	mutating func append(_ samples: [Float]) {
		samples.withUnsafeBufferPointer { buffer in
			guard let base = buffer.baseAddress else { return }
			var offset = 0
			while offset < buffer.count {
				let take = min(buffer.count - offset, frameEnd - sampleCount)
				var peak: Float = 0
				var squares: Float = 0
				vDSP_maxmgv(base + offset, 1, &peak, vDSP_Length(take))
				vDSP_svesq(base + offset, 1, &squares, vDSP_Length(take))
				currentPeak = max(currentPeak, peak)
				currentSquares += Double(squares)
				currentCount += take
				offset += take
				sampleCount += take
				if sampleCount >= frameEnd {
					closeFrame()
				}
			}
		}
	}

	/// Closes the trailing partial frame, if any.
	mutating func finish() {
		if currentCount > 0 {
			closeFrame()
		}
	}

	private mutating func closeFrame() {
		peaks.append(min(1, currentPeak))
		rms.append(currentCount > 0 ? Float((currentSquares / Double(currentCount)).squareRoot()) : 0)
		currentPeak = 0
		currentSquares = 0
		currentCount = 0
		frameIndex += 1
		frameEnd = max(sampleCount + 1, Int((Double(frameIndex + 1) * samplesPerFrame).rounded()))
	}
}

extension FrameStatsAccumulator {
	/// Decodes `source` off the concurrency pool and returns the finished per-frame statistics.
	static func measure(_ source: AudioSource, samplesPerFrame: Double) async throws -> FrameStatsAccumulator {
		try await BlockingWork.run { cancellation in
			let reader = try source.makeReader()
			var accumulator = FrameStatsAccumulator(
				samplesPerFrame: samplesPerFrame,
				expectedSamples: Int(source.duration * source.sampleRate)
			)
			while let chunk = try reader.nextChunk() {
				try cancellation.check()
				accumulator.append(chunk)
			}
			accumulator.finish()
			return accumulator
		}
	}
}
