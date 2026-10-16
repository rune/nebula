import Foundation
import NebulaCore
import Testing

@testable import NebulaCaptions

@Suite("SRT writer")
struct SRTWriterTests {
	static func word(_ text: String, _ start: Double, _ end: Double) -> CaptionWord {
		CaptionWord(range: TimeRange(start: start, end: end), text: text)
	}

	/// 10 s recording: 2–4 s cut, 6–8 s at 2× speed.
	/// Output: 0–2 → 0–2, 4–6 → 2–4, 6–8 → 4–5, 8–10 → 5–7.
	static let timeMap = TimeMap(
		duration: 10,
		cuts: [CutItem(range: TimeRange(start: 2, end: 4))],
		speeds: [SpeedItem(range: TimeRange(start: 6, end: 8), rate: 2)]
	)

	@Test(arguments: [
		(0.0, "00:00:00,000"),
		(1.5, "00:00:01,500"),
		(61.001, "00:01:01,001"),
		(3_725.4567, "01:02:05,457"),
		(0.0004, "00:00:00,000"),
		(-3, "00:00:00,000"),
		(360_000, "100:00:00,000"),
	])
	func formatsTimestamps(seconds: Double, expected: String) {
		#expect(SRTWriter.timestamp(seconds) == expected)
	}

	@Test func writesNumberedCues() {
		let segments = [
			CaptionSegment(range: TimeRange(start: 0.5, end: 2.25), text: "Hello there."),
			CaptionSegment(range: TimeRange(start: 3, end: 4.1), text: "  General Kenobi!  "),
		]
		let expected = """
			1
			00:00:00,500 --> 00:00:02,250
			Hello there.

			2
			00:00:03,000 --> 00:00:04,100
			General Kenobi!

			"""
		#expect(SRTWriter.srt(segments, timeMap: nil) == expected)
	}

	@Test func emptyInputGivesEmptyOutput() {
		#expect(SRTWriter.srt([], timeMap: nil) == "")
		#expect(SRTWriter.srt([CaptionSegment(range: TimeRange(start: 0, end: 1), text: "   ")], timeMap: nil) == "")
	}

	@Test func sortsAndRemovesOverlaps() {
		let segments = [
			CaptionSegment(range: TimeRange(start: 2, end: 3), text: "Second"),
			CaptionSegment(range: TimeRange(start: 0, end: 2.5), text: "First"),
		]
		let srt = SRTWriter.srt(segments, timeMap: nil)
		#expect(srt.contains("1\n00:00:00,000 --> 00:00:02,000\nFirst\n"))
		#expect(srt.contains("2\n00:00:02,000 --> 00:00:03,000\nSecond\n"))
	}

	@Test func removesBlankLinesInsideText() {
		let segments = [CaptionSegment(range: TimeRange(start: 0, end: 1), text: "Line one\n\n\nLine two")]
		#expect(SRTWriter.srt(segments, timeMap: nil) == "1\n00:00:00,000 --> 00:00:01,000\nLine one\nLine two\n")
	}

	@Test func mapsTimesThroughCutsAndSpeed() {
		let segments = [
			CaptionSegment(range: TimeRange(start: 0.5, end: 1.5), text: "Before the cut"),
			CaptionSegment(range: TimeRange(start: 4.5, end: 5.5), text: "After the cut"),
			CaptionSegment(range: TimeRange(start: 6, end: 8), text: "Fast part"),
			CaptionSegment(range: TimeRange(start: 9, end: 10), text: "The end"),
		]
		let expected = """
			1
			00:00:00,500 --> 00:00:01,500
			Before the cut

			2
			00:00:02,500 --> 00:00:03,500
			After the cut

			3
			00:00:04,000 --> 00:00:05,000
			Fast part

			4
			00:00:06,000 --> 00:00:07,000
			The end

			"""
		#expect(SRTWriter.srt(segments, timeMap: Self.timeMap) == expected)
	}

	@Test func dropsSegmentsInsideCuts() {
		let segments = [
			CaptionSegment(range: TimeRange(start: 2.2, end: 3.8), text: "Cut away"),
			CaptionSegment(
				range: TimeRange(start: 2.1, end: 3.9),
				text: "Also cut",
				words: [Self.word("Also", 2.1, 2.5), Self.word("cut", 3.0, 3.9)]
			),
			CaptionSegment(range: TimeRange(start: 0, end: 1), text: "Kept"),
		]
		#expect(SRTWriter.srt(segments, timeMap: Self.timeMap) == "1\n00:00:00,000 --> 00:00:01,000\nKept\n")
	}

	@Test func dropsCutWordsAndRebuildsText() {
		// "um uh" sit inside the 2–4 s cut; the rest spans it.
		let segment = CaptionSegment(
			range: TimeRange(start: 1, end: 5),
			text: "So, um uh, let's go",
			words: [
				Self.word("So,", 1.0, 1.5),
				Self.word("um", 2.2, 2.6),
				Self.word("uh,", 3.0, 3.6),
				Self.word("let's", 4.2, 4.6),
				Self.word("go", 4.7, 5.0),
			]
		)
		let srt = SRTWriter.srt([segment], timeMap: Self.timeMap)
		// 1.0 → 1.0 and 5.0 → 3.0 in output time.
		#expect(srt == "1\n00:00:01,000 --> 00:00:03,000\nSo, let's go\n")
	}

	@Test func keepsTextWhenOnlyGapsAreCut() {
		// A cut between words shortens the cue but keeps every word and the original text.
		let segment = CaptionSegment(
			range: TimeRange(start: 1, end: 5),
			text: "Wait — then go",
			words: [Self.word("Wait", 1.0, 1.8), Self.word("—", 1.8, 1.9), Self.word("then", 4.1, 4.5), Self.word("go", 4.6, 5.0)]
		)
		#expect(SRTWriter.srt([segment], timeMap: Self.timeMap) == "1\n00:00:01,000 --> 00:00:03,000\nWait — then go\n")
	}

	@Test func wordPartlyInCutIsKeptByItsMiddle() {
		let segment = CaptionSegment(
			range: TimeRange(start: 1.5, end: 4.6),
			text: "almost gone",
			words: [Self.word("almost", 1.5, 2.1), Self.word("gone", 3.9, 4.6)]
		)
		// "almost" (middle 1.8, kept) and "gone" (middle 4.25, kept) survive; their cut parts are trimmed.
		#expect(SRTWriter.srt([segment], timeMap: Self.timeMap) == "1\n00:00:01,500 --> 00:00:02,600\nalmost gone\n")
	}

	@Test func speedChangesStretchWordTimes() {
		let segment = CaptionSegment(
			range: TimeRange(start: 7, end: 9),
			text: "quick slow",
			words: [Self.word("quick", 7, 7.9), Self.word("slow", 8.3, 9)]
		)
		let cut = TimeMap(duration: 10, cuts: [CutItem(range: TimeRange(start: 8.1, end: 8.6))], speeds: [SpeedItem(range: TimeRange(start: 6, end: 8), rate: 2)])
		// Both words are kept (the middle of "slow", 8.65, is after the cut).
		// 7 → 6.5 at 2×; 8 → 7; 9 → 7.1 + (9 − 8.6) = 7.5.
		#expect(SRTWriter.srt([segment], timeMap: cut) == "1\n00:00:06,500 --> 00:00:07,500\nquick slow\n")
	}
}
