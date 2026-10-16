import NebulaCore

/// Peak envelope of an audio track, for drawing waveforms.
///
/// `peaks[i]` is the largest absolute sample value (0...1, not normalised) in the time slice
/// `[i / samplesPerSecond, (i + 1) / samplesPerSecond)`.
public struct Waveform: Sendable, Hashable {
	/// Number of peak values per second of audio.
	public var samplesPerSecond: Double
	/// Absolute peak per slice, 0...1.
	public var peaks: [Float]

	public init(samplesPerSecond: Double, peaks: [Float]) {
		self.samplesPerSecond = samplesPerSecond
		self.peaks = peaks
	}

	/// An empty waveform (no audio).
	public static func empty(samplesPerSecond: Double = 50) -> Waveform {
		Waveform(samplesPerSecond: samplesPerSecond, peaks: [])
	}

	/// Whether the waveform has no peaks.
	public var isEmpty: Bool { peaks.isEmpty }

	/// Length covered by the peaks, in seconds.
	public var duration: Double {
		samplesPerSecond > 0 ? Double(peaks.count) / samplesPerSecond : 0
	}

	/// Largest peak among the slices that overlap `range` (seconds). Returns 0 outside the audio.
	///
	/// An empty range returns the peak of the slice containing `range.start`.
	public func peak(in range: TimeRange) -> Float {
		guard samplesPerSecond > 0, !peaks.isEmpty else { return 0 }
		let first = Int((range.start * samplesPerSecond).rounded(.down))
		var last = Int((range.end * samplesPerSecond).rounded(.up))
		if last <= first { last = first + 1 }
		let lower = max(0, first)
		let upper = min(peaks.count, last)
		guard lower < upper else { return 0 }
		return peaks[lower..<upper].max() ?? 0
	}
}
