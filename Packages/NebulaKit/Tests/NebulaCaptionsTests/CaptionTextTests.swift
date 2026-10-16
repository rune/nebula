import Foundation
import NebulaCore
import Testing

@testable import NebulaCaptions

@Suite("Caption text cleanup")
struct CaptionTextTests {
	@Test(arguments: [
		("<|startoftranscript|><|en|><|transcribe|> Hello there.<|endoftext|>", "Hello there."),
		("  Hello   world  ", "Hello world"),
		("[Music]", ""),
		("[ Music ]", ""),
		("(silence)", ""),
		("♪ ♪", ""),
		("*laughs* That was fun.", "That was fun."),
		("So [BLANK_AUDIO] we start here.", "So we start here."),
		("Hello [Music] , world", "Hello, world"),
		("[Music], okay then", "okay then"),
		("(upbeat music) Welcome back!", "Welcome back!"),
		(">> Next speaker here", "Next speaker here"),
		("...", ""),
		(" - ", ""),
		("We shipped 3.5 today.", "We shipped 3.5 today."),
	])
	func cleansText(input: String, expected: String) {
		#expect(CaptionText.clean(input) == expected)
	}

	@Test func stripperRemembersBracketsAcrossWords() {
		var stripper = CaptionText.Stripper()
		let words = [" [", "Music", "]", " Hello", " (", "applause", ")", " world"]
		let kept = words.map { CaptionText.normalize(stripper.strip($0)) }.filter { !$0.isEmpty }
		#expect(kept == ["Hello", "world"])
	}

	@Test func builderCleansWordsAndRebuildsText() throws {
		let raw = RawSegment(
			text: "<|0.00|> [Music] Hello, world!<|2.00|>",
			start: 0,
			end: 2,
			words: [
				.init(text: " [", start: 0.0, end: 0.1),
				.init(text: "Music", start: 0.1, end: 0.4),
				.init(text: "]", start: 0.4, end: 0.5),
				.init(text: " Hello,", start: 0.6, end: 1.0),
				.init(text: " world!", start: 1.1, end: 1.6),
			]
		)
		let segment = try #require(SegmentBuilder.segment(from: raw))
		#expect(segment.text == "Hello, world!")
		#expect(segment.words.map(\.text) == ["Hello,", "world!"])
		#expect(segment.range == TimeRange(start: 0.6, end: 1.6))
	}

	@Test func builderKeepsWordsWithoutSpacesTogether() throws {
		let raw = RawSegment(
			text: "こんにちは世界",
			start: 0,
			end: 1,
			words: [.init(text: "こんにちは", start: 0, end: 0.5), .init(text: "世界", start: 0.5, end: 1)]
		)
		let segment = try #require(SegmentBuilder.segment(from: raw))
		#expect(segment.text == "こんにちは世界")
	}

	@Test func builderMakesWordTimesMonotonic() throws {
		let raw = RawSegment(
			text: " one two",
			start: 0,
			end: 2,
			words: [.init(text: " one", start: 0.5, end: 1.2), .init(text: " two", start: 1.0, end: 0.9)]
		)
		let segment = try #require(SegmentBuilder.segment(from: raw))
		#expect(segment.words[1].range == TimeRange(start: 1.2, end: 1.2))
	}

	@Test func builderDropsNonSpeechSegmentsAndSorts() {
		let raw = [
			RawSegment(text: " Second.", start: 5, end: 6, words: []),
			RawSegment(text: " [Music]", start: 2, end: 4, words: []),
			RawSegment(text: " First.", start: 0, end: 1, words: []),
		]
		let segments = SegmentBuilder.captionSegments(from: raw)
		#expect(segments.map(\.text) == ["First.", "Second."])
	}

	@Test func languageCodesAreReduced() {
		#expect(CaptionTranscriber.recognizerLanguage("en-US") == "en")
		#expect(CaptionTranscriber.recognizerLanguage("pt_BR") == "pt")
		#expect(CaptionTranscriber.recognizerLanguage("DE") == "de")
		#expect(CaptionTranscriber.recognizerLanguage(nil) == nil)
	}

	@Test func modelMetadata() {
		#expect(CaptionModel.allCases.count == 3)
		#expect(CaptionModel.largeTurbo.rawValue == "openai_whisper-large-v3-v20240930_turbo")
		for model in CaptionModel.allCases {
			#expect(!model.title.isEmpty)
			#expect(!model.approximateSize.isEmpty)
		}
	}

	@Test func modelIsNotDownloadedInEmptyFolder() async {
		let folder = FileManager.default.temporaryDirectory.appending(path: "nebula-captions-\(UUID().uuidString)")
		let transcriber = CaptionTranscriber(modelsFolder: folder)
		#expect(await transcriber.isModelDownloaded(.base) == false)
		#expect(transcriber.folder(for: .base).path().hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-base/"))
	}
}
