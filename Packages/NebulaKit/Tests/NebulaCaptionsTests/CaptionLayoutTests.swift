import Foundation
import NebulaCore
import Testing

@testable import NebulaCaptions

@Suite("Caption layout")
struct CaptionLayoutTests {
	/// A segment whose words are evenly spaced, `step` seconds apart, starting at `start`.
	static func segment(_ text: String, start: Double = 0, step: Double = 0.3) -> CaptionSegment {
		let tokens = text.split(separator: " ").map(String.init)
		let words = tokens.enumerated().map { index, token in
			CaptionWord(
				range: TimeRange(start: start + Double(index) * step, end: start + Double(index) * step + step * 0.8),
				text: token
			)
		}
		let end = words.last?.range.end ?? start
		return CaptionSegment(id: "cap-test", range: TimeRange(start: start, end: end), text: text, words: words)
	}

	@Test func shortSegmentIsUnchanged() {
		let input = Self.segment("Hello there, everyone.")
		#expect(CaptionLayout.lines(for: [input]) == [input])
	}

	@Test func longSegmentSplitsIntoBalancedLines() {
		let text = "The quick brown fox jumps over the lazy dog and then keeps running far away"
		let lines = CaptionLayout.lines(for: [Self.segment(text)], maxCharacters: 42)
		#expect(lines.count == 2)
		#expect(lines.allSatisfy { $0.text.count <= 42 })
		#expect(lines.map(\.text).joined(separator: " ") == text)
		// Balanced, not greedy: neither line is much shorter than the other.
		let lengths = lines.map(\.text.count)
		#expect(abs(lengths[0] - lengths[1]) <= 10)
	}

	@Test func linesUseWordTimingsAndKeepTheFirstID() {
		let text = "one two three four five six seven eight nine ten eleven twelve thirteen"
		let input = Self.segment(text, start: 10, step: 0.5)
		let lines = CaptionLayout.lines(for: [input], maxCharacters: 30)
		#expect(lines.count >= 3)
		#expect(lines[0].id == input.id)
		#expect(Set(lines.map(\.id)).count == lines.count)
		for line in lines {
			#expect(line.range.start == line.words.first?.range.start)
			#expect(line.range.end == line.words.last?.range.end)
			#expect(line.text.count <= 30)
		}
		#expect(lines.flatMap(\.words) == input.words)
		// Lines are in order and don't overlap.
		for (a, b) in zip(lines, lines.dropFirst()) {
			#expect(a.range.end <= b.range.start)
		}
	}

	@Test func splitsAtSentenceEndsFirst() {
		let text = "This is the first sentence here. And this one is the second sentence."
		let lines = CaptionLayout.lines(for: [Self.segment(text)], maxCharacters: 42)
		#expect(lines.map(\.text) == ["This is the first sentence here.", "And this one is the second sentence."])
	}

	@Test func splitsAtLongPauses() {
		var input = Self.segment("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")
		// Insert a two-second pause before "zeta".
		for index in 5..<input.words.count {
			input.words[index].range.start += 2
			input.words[index].range.end += 2
		}
		input.range.end = input.words[input.words.count - 1].range.end
		let lines = CaptionLayout.lines(for: [input], maxCharacters: 42)
		#expect(lines.first?.text == "alpha beta gamma delta epsilon")
	}

	@Test func longSlowSegmentSplitsByDuration() {
		let input = Self.segment("we speak very slowly here", step: 3)
		#expect(input.text.count < 42)
		let lines = CaptionLayout.lines(for: [input], maxCharacters: 42)
		#expect(lines.count > 1)
		#expect(lines.allSatisfy { $0.range.duration <= CaptionLayout.maxLineDuration })
	}

	@Test func overlongSingleWordGetsItsOwnLine() {
		let lines = CaptionLayout.lines(for: [Self.segment("a supercalifragilisticexpialidocious b")], maxCharacters: 10)
		#expect(lines.map(\.text) == ["a", "supercalifragilisticexpialidocious", "b"])
	}

	@Test func segmentWithoutWordsIsSplitWithInterpolatedTimes() {
		let text = "Captions without word timings still need to be split into readable lines"
		let input = CaptionSegment(range: TimeRange(start: 0, end: 10), text: text)
		let lines = CaptionLayout.lines(for: [input], maxCharacters: 42)
		#expect(lines.count == 2)
		#expect(lines.map(\.text).joined(separator: " ") == text)
		#expect(lines[0].range.start == 0)
		#expect(abs(lines[1].range.end - 10) < 0.000_1)
		#expect(lines[0].range.end <= lines[1].range.start)
	}

	@Test func editedTextIgnoresStaleWords() {
		var input = Self.segment("old words that no longer match the text at all here")
		input.text = "This caption was edited by hand and is now quite a bit longer than before"
		let lines = CaptionLayout.lines(for: [input], maxCharacters: 42)
		#expect(lines.map(\.text).joined(separator: " ") == input.text)
	}
}
