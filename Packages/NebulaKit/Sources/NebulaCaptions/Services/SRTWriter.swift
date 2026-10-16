import Foundation
import NebulaCore

/// Writes captions as SubRip (`.srt`) subtitles.
public enum SRTWriter {
	/// Builds SRT text for the given segments.
	///
	/// - Parameters:
	///   - segments: Caption segments in source time (usually from ``CaptionLayout/lines(for:maxCharacters:)``).
	///   - timeMap: When given, times are mapped to the exported video: words whose middle is cut
	///     are dropped (the segment text is rebuilt from the remaining words), segments that are
	///     entirely cut are dropped, and speed changes stretch or shrink the timings.
	/// - Returns: Numbered cues with `HH:MM:SS,mmm` times, or "" when nothing remains.
	public static func srt(_ segments: [CaptionSegment], timeMap: TimeMap?) -> String {
		var cues = segments.compactMap { cue(for: $0, timeMap: timeMap) }
		cues.sort { $0.range.start < $1.range.start }

		// Cues must not overlap: end each one no later than the next one starts.
		for index in cues.indices.dropLast() where cues[index].range.end > cues[index + 1].range.start {
			cues[index].range.end = cues[index + 1].range.start
		}

		return cues
			.filter { $0.range.end > $0.range.start }
			.enumerated()
			.map { index, cue in
				"\(index + 1)\n\(timestamp(cue.range.start)) --> \(timestamp(cue.range.end))\n\(cue.text)\n"
			}
			.joined(separator: "\n")
	}

	/// Formats seconds as an SRT timestamp, `HH:MM:SS,mmm` (hours grow past two digits if needed).
	public static func timestamp(_ seconds: Double) -> String {
		let total = Int((max(0, seconds) * 1000).rounded())
		let hours = total / 3_600_000
		let minutes = total / 60_000 % 60
		let secs = total / 1000 % 60
		let millis = total % 1000
		return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
	}

	private struct Cue {
		var range: TimeRange
		var text: String
	}

	private static func cue(for segment: CaptionSegment, timeMap: TimeMap?) -> Cue? {
		let text = cueText(segment.text)
		guard let timeMap else {
			return text.isEmpty ? nil : Cue(range: segment.range, text: text)
		}

		guard !segment.words.isEmpty else {
			guard !text.isEmpty, let range = timeMap.outputRange(forSource: segment.range) else { return nil }
			return Cue(range: range, text: text)
		}

		let kept = segment.words.filter { timeMap.keepsMiddle(of: $0.range) }
		guard !kept.isEmpty else { return nil }

		if kept.count == segment.words.count {
			guard !text.isEmpty, let range = timeMap.outputRange(forSource: segment.range) else { return nil }
			return Cue(range: range, text: text)
		}

		let ranges = kept.compactMap { timeMap.outputRange(forSource: $0.range) }
		guard let start = ranges.map(\.start).min(), let end = ranges.map(\.end).max() else { return nil }
		let separator = segment.text.contains(where: \.isWhitespace) ? " " : ""
		let keptText = cueText(kept.map(\.text).joined(separator: separator))
		guard !keptText.isEmpty else { return nil }
		return Cue(range: TimeRange(start: start, end: end), text: keptText)
	}

	/// Trims the text and removes blank lines, which would end an SRT cue early.
	private static func cueText(_ text: String) -> String {
		text
			.split(whereSeparator: \.isNewline)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
			.joined(separator: "\n")
	}
}
