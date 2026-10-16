import Accelerate

/// Estimates a noise power spectrum from the quietest frames of a recording in one pass.
///
/// Rather than storing every spectrum, frames are binned by loudness (1 dB buckets) and each
/// bucket keeps the sum of its power spectra. The profile is the mean spectrum of the quietest
/// buckets that together hold about `quietFraction` of the frames. Digitally silent frames are
/// ignored so leading or trailing zeros do not hide the real noise.
struct NoiseProfileEstimator {
	static let lowestDB: Float = -100
	static let bucketCount = 100

	let binCount: Int
	let quietFraction: Double
	private var sums: [[Double]]
	private var counts: [Int]

	init(binCount: Int, quietFraction: Double = 0.1) {
		self.binCount = binCount
		self.quietFraction = quietFraction
		self.sums = Array(repeating: [], count: Self.bucketCount)
		self.counts = Array(repeating: 0, count: Self.bucketCount)
	}

	var frameCount: Int { counts.reduce(0, +) }

	/// Adds one frame's power spectrum and its level in dBFS.
	mutating func add(power: [Float], levelDB: Float) {
		guard levelDB.isFinite, levelDB > Self.lowestDB else { return }
		let bucket = min(Self.bucketCount - 1, max(0, Int(levelDB - Self.lowestDB)))
		if sums[bucket].isEmpty {
			sums[bucket] = [Double](repeating: 0, count: binCount)
		}
		var converted = [Double](repeating: 0, count: binCount)
		vDSP_vspdp(power, 1, &converted, 1, vDSP_Length(binCount))
		sums[bucket].withUnsafeMutableBufferPointer { buffer in
			guard let base = buffer.baseAddress else { return }
			vDSP_vaddD(base, 1, converted, 1, base, 1, vDSP_Length(binCount))
		}
		counts[bucket] += 1
	}

	/// Mean power spectrum of the quietest frames, or `nil` if no usable frame was added.
	func profile() -> [Float]? {
		let total = frameCount
		guard total > 0 else { return nil }
		let target = max(1, Int((Double(total) * quietFraction).rounded()))
		var accumulated = [Double](repeating: 0, count: binCount)
		var used = 0
		for bucket in 0..<Self.bucketCount where counts[bucket] > 0 {
			for bin in 0..<binCount {
				accumulated[bin] += sums[bucket][bin]
			}
			used += counts[bucket]
			if used >= target { break }
		}
		return accumulated.map { Float($0 / Double(used)) }
	}
}
