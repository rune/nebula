import Foundation
import NebulaCore

/// Energy-based voice activity detection.
///
/// Each frame's level is compared with an adaptive noise floor: the minimum of the lightly
/// smoothed level over a sliding ~6 s window, ignoring digital silence, and never more than
/// 12 dB above the recording's overall quiet level (its 10th percentile), so long continuous
/// speech or sound cannot become its own noise floor. A segment starts when a
/// frame rises 10 dB above the floor (and above -50 dBFS) and continues while frames stay 6 dB
/// above it, with a 0.25 s hangover to bridge short dips. Segments get 0.05 s of padding on both
/// sides, gaps shorter than 0.35 s are merged and segments shorter than 0.2 s are dropped.
public enum SpeechActivityDetector {
	/// Frame length used when analysing files.
	static let analysisFrameDuration = 0.02

	static let onsetMarginDB: Float = 10
	static let offsetMarginDB: Float = 6
	static let absoluteOnsetDB: Float = -50
	static let absoluteOffsetDB: Float = -56
	/// Frames quieter than this are treated as digital silence and ignored by the noise floor.
	static let digitalSilenceDB: Float = -90
	static let minimumFloorDB: Float = -100
	static let floorWindow = 3.0
	/// The local floor may rise at most this far above the global quiet level.
	static let floorCeilingMarginDB: Float = 12
	static let quietPercentile = 0.1
	static let smoothingWindow = 0.05
	static let hangover = 0.25
	static let edgePadding = 0.05
	static let mergeGap = 0.35
	static let minimumSegment = 0.2

	/// Detects speech in the first audio track of `url`. Returns `[]` when the file has no audio.
	public static func detect(url: URL) async throws -> [TimeRange] {
		let levels = try await AudioLevels.rmsLevels(url: url, frameDuration: analysisFrameDuration)
		let ranges = detect(levels: levels, frameDuration: analysisFrameDuration)
		AudioLog.logger.debug(
			"Speech activity in \(url.lastPathComponent, privacy: .public): \(ranges.count) segments"
		)
		return ranges
	}

	/// Detects speech in a sequence of linear RMS levels (one per `frameDuration` seconds).
	///
	/// Pure and deterministic; returned ranges are sorted, non-overlapping and within
	/// `[0, levels.count * frameDuration]`.
	public static func detect(levels: [Float], frameDuration: Double) -> [TimeRange] {
		guard !levels.isEmpty, frameDuration > 0, frameDuration.isFinite else { return [] }
		let decibels = levels.map { 20 * log10(max($0.isFinite ? $0 : 0, 1e-6)) }
		let floor = noiseFloor(decibels: decibels, frameDuration: frameDuration)
		let total = Double(levels.count) * frameDuration
		let hangoverFrames = max(1, Int((hangover / frameDuration).rounded()))

		var raw: [TimeRange] = []
		var segmentStart: Int?
		var lastActive = 0

		func close(_ start: Int, _ end: Int) {
			raw.append(
				TimeRange(
					start: max(0, Double(start) * frameDuration - edgePadding),
					end: min(total, Double(end + 1) * frameDuration + edgePadding)
				)
			)
		}

		for index in decibels.indices {
			let level = decibels[index]
			if let start = segmentStart {
				if level >= max(floor[index] + offsetMarginDB, absoluteOffsetDB) {
					lastActive = index
				} else if index - lastActive > hangoverFrames {
					close(start, lastActive)
					segmentStart = nil
				}
			} else if level >= max(floor[index] + onsetMarginDB, absoluteOnsetDB) {
				segmentStart = index
				lastActive = index
			}
		}
		if let start = segmentStart {
			close(start, lastActive)
		}
		return clean(raw)
	}

	/// Merges segments separated by less than `mergeGap` and drops ones shorter than `minimumSegment`.
	static func clean(_ ranges: [TimeRange]) -> [TimeRange] {
		var merged: [TimeRange] = []
		for range in ranges.sorted(by: { $0.start < $1.start }) {
			if let last = merged.last, range.start - last.end < mergeGap {
				merged[merged.count - 1].end = max(last.end, range.end)
			} else {
				merged.append(range)
			}
		}
		return merged.filter { $0.duration >= minimumSegment }
	}

	/// Adaptive noise floor in dB per frame: sliding-window minimum of the smoothed level.
	static func noiseFloor(decibels: [Float], frameDuration: Double) -> [Float] {
		let count = decibels.count
		// Moving average (centered) to steady the per-frame level.
		let smoothHalf = max(1, Int((smoothingWindow / frameDuration).rounded()))
		var prefix = [Double](repeating: 0, count: count + 1)
		var validPrefix = [Int](repeating: 0, count: count + 1)
		for index in 0..<count {
			let valid = decibels[index] > digitalSilenceDB
			prefix[index + 1] = prefix[index] + (valid ? Double(decibels[index]) : 0)
			validPrefix[index + 1] = validPrefix[index] + (valid ? 1 : 0)
		}
		var smoothed = [Float](repeating: .infinity, count: count)
		for index in 0..<count {
			let low = max(0, index - smoothHalf)
			let high = min(count, index + smoothHalf + 1)
			let valid = validPrefix[high] - validPrefix[low]
			if valid > 0 {
				smoothed[index] = Float((prefix[high] - prefix[low]) / Double(valid))
			}
		}

		// Global quiet level: a low percentile of the usable smoothed levels.
		let usable = smoothed.filter(\.isFinite).sorted()
		let ceiling: Float
		if usable.isEmpty {
			ceiling = minimumFloorDB
		} else {
			let index = min(usable.count - 1, Int(Double(usable.count) * quietPercentile))
			ceiling = usable[index] + floorCeilingMarginDB
		}

		// Sliding minimum over a centered window with a monotonic deque.
		let half = max(1, Int((floorWindow / frameDuration).rounded()))
		var floor = [Float](repeating: minimumFloorDB, count: count)
		var deque: [Int] = []
		deque.reserveCapacity(2 * half + 2)
		var head = 0
		var pushed = 0
		for index in 0..<count {
			let windowEnd = min(count - 1, index + half)
			while pushed <= windowEnd {
				while deque.count > head, let back = deque.last, smoothed[back] >= smoothed[pushed] {
					deque.removeLast()
				}
				deque.append(pushed)
				pushed += 1
			}
			while head < deque.count, deque[head] < index - half {
				head += 1
			}
			if head < deque.count {
				let minimum = smoothed[deque[head]]
				floor[index] = minimum.isFinite ? max(min(minimum, ceiling), minimumFloorDB) : minimumFloorDB
			}
		}
		return floor
	}
}
