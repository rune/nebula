import Foundation
import NebulaCore

/// Turns raw recognizer segments into clean caption segments.
enum SegmentBuilder {
	/// Cleans, orders and filters segments. Segments with nothing speakable are dropped.
	static func captionSegments(from raw: [RawSegment]) -> [CaptionSegment] {
		raw.sorted { $0.start < $1.start }.compactMap(segment(from:))
	}

	static func segment(from raw: RawSegment) -> CaptionSegment? {
		guard !raw.words.isEmpty else {
			let text = CaptionText.clean(raw.text)
			guard !text.isEmpty, raw.end > raw.start else { return nil }
			return CaptionSegment(range: TimeRange(start: raw.start, end: raw.end), text: text)
		}

		var stripper = CaptionText.Stripper()
		var words: [CaptionWord] = []
		var joined = ""
		var previousEnd = -Double.infinity
		for word in raw.words {
			let stripped = stripper.strip(word.text)
			let text = CaptionText.normalize(stripped)
			guard !text.isEmpty else { continue }
			let start = max(word.start, previousEnd)
			let end = max(start, word.end)
			if !joined.isEmpty, stripped.first?.isWhitespace ?? false {
				joined += " "
			}
			joined += text
			words.append(CaptionWord(range: TimeRange(start: start, end: end), text: text))
			previousEnd = end
		}

		let text = CaptionText.normalize(joined)
		guard let first = words.first, let last = words.last, !text.isEmpty else { return nil }
		let start = first.range.start
		var end = last.range.end
		if end <= start {
			end = raw.end > start ? raw.end : start + 0.2
		}
		return CaptionSegment(range: TimeRange(start: start, end: end), text: text, words: words)
	}
}
