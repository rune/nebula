import Foundation
import NebulaCore

/// Splits transcribed segments into caption-sized lines.
public enum CaptionLayout {
	/// Longest time one line stays on screen, in seconds (applies when word timings exist).
	static let maxLineDuration = 7.0
	/// A pause between words at least this long starts a new line when a segment is split.
	static let pauseBreak = 0.8

	/// Re-splits segments that are too long to read as one caption line.
	///
	/// Segments that fit are returned unchanged. Longer ones are split at sentence ends and
	/// pauses first, then into lines of balanced length, each at most `maxCharacters` long
	/// (a single word longer than that gets a line of its own). Line timings come from the
	/// word timings; segments without usable word timings get word times interpolated by
	/// character count. The first line keeps the segment's id.
	public static func lines(for segments: [CaptionSegment], maxCharacters: Int = 42) -> [CaptionSegment] {
		let limit = max(1, maxCharacters)
		return segments.flatMap { split($0, limit: limit) }
	}

	static func split(_ segment: CaptionSegment, limit: Int) -> [CaptionSegment] {
		let separator = segment.text.contains(where: \.isWhitespace) ? " " : ""
		let hasTimedWords = !segment.words.isEmpty && wordsMatchText(segment)
		let tooLong = segment.text.count > limit || (hasTimedWords && segment.range.duration > maxLineDuration)
		guard tooLong else { return [segment] }

		let words = hasTimedWords ? segment.words : interpolatedWords(for: segment, separator: separator)
		guard words.count > 1 else { return [segment] }

		let lines = runs(of: words).flatMap { pack($0, limit: limit, separator: separator) }
		guard lines.count > 1 else { return [segment] }

		return lines.enumerated().compactMap { index, lineWords in
			guard let first = lineWords.first, let last = lineWords.last else { return nil }
			return CaptionSegment(
				id: index == 0 ? segment.id : .make("cap"),
				range: TimeRange(start: first.range.start, end: max(first.range.start, last.range.end)),
				text: lineWords.map(\.text).joined(separator: separator),
				words: lineWords
			)
		}
	}

	/// True when the words still spell the segment text (it may have been edited since).
	static func wordsMatchText(_ segment: CaptionSegment) -> Bool {
		squashed(segment.words.map(\.text).joined()) == squashed(segment.text)
	}

	private static func squashed(_ text: String) -> String {
		String(text.lowercased().filter { $0.isLetter || $0.isNumber })
	}

	/// Words with times spread over the segment in proportion to their length.
	static func interpolatedWords(for segment: CaptionSegment, separator: String) -> [CaptionWord] {
		let tokens: [String] =
			separator.isEmpty
			? segment.text.map { String($0) }
			: segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
		let total = tokens.reduce(0) { $0 + $1.count } + separator.count * max(0, tokens.count - 1)
		guard total > 0 else { return [] }

		let range = segment.range
		var offset = 0
		var words: [CaptionWord] = []
		for token in tokens {
			let start = range.start + range.duration * Double(offset) / Double(total)
			offset += token.count
			let end = range.start + range.duration * Double(offset) / Double(total)
			offset += separator.count
			words.append(CaptionWord(range: TimeRange(start: start, end: end), text: token))
		}
		return words
	}

	/// Splits words into runs that must not share a line: after sentence ends and long pauses.
	static func runs(of words: [CaptionWord]) -> [[CaptionWord]] {
		var runs: [[CaptionWord]] = []
		var current: [CaptionWord] = []
		for (index, word) in words.enumerated() {
			current.append(word)
			guard index + 1 < words.count else { break }
			let next = words[index + 1]
			if endsSentence(word.text) || next.range.start - word.range.end >= pauseBreak {
				runs.append(current)
				current = []
			}
		}
		if !current.isEmpty { runs.append(current) }
		return runs
	}

	private static func endsSentence(_ word: String) -> Bool {
		guard let last = word.last else { return false }
		return ".?!…。？！".contains(last)
	}

	/// Packs a run into lines of at most `limit` characters, balancing line lengths.
	static func pack(_ run: [CaptionWord], limit: Int, separator: String) -> [[CaptionWord]] {
		var lines: [[CaptionWord]] = []
		var index = 0
		while index < run.count {
			let remaining = run[index...].reduce(0) { $0 + $1.text.count } + separator.count * (run.count - index - 1)
			let lineCount = Int((Double(remaining) / Double(limit)).rounded(.up))
			let target = lineCount > 1 ? Int((Double(remaining) / Double(lineCount)).rounded(.up)) : limit

			var line = [run[index]]
			var length = run[index].text.count
			index += 1
			while index < run.count {
				let word = run[index]
				let next = length + separator.count + word.text.count
				if next > limit { break }
				if next > target && next - target > target - length { break }
				if word.range.end - line[0].range.start > maxLineDuration { break }
				line.append(word)
				length = next
				index += 1
			}
			lines.append(line)
		}
		return lines
	}
}
