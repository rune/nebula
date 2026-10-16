import Foundation
import NebulaCore
import WhisperKit

/// The bridge to the speech recognition library. Every recognizer object is created and used
/// inside one call, so nothing non-sendable crosses an isolation boundary.
enum SpeechRecognizer {
	/// Repository the models are downloaded from.
	static let repository = "argmaxinc/whisperkit-coreml"
	/// Written into a model folder once its download (model and tokenizer) completed.
	static let readyMarker = ".nebula-ready"
	/// Model bundles a usable model folder contains.
	static let requiredBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

	/// Where a model lives under the models folder.
	static func folder(for model: CaptionModel, in modelsFolder: URL) -> URL {
		modelsFolder
			.appending(path: "models", directoryHint: .isDirectory)
			.appending(path: repository, directoryHint: .isDirectory)
			.appending(path: model.rawValue, directoryHint: .isDirectory)
	}

	/// True when the model folder is complete and was fully downloaded.
	static func isReady(_ folder: URL) -> Bool {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: folder.appending(path: readyMarker).path(percentEncoded: false)) else {
			return false
		}
		return requiredBundles.allSatisfy { name in
			fileManager.fileExists(atPath: folder.appending(path: "\(name).mlmodelc").path(percentEncoded: false))
		}
	}

	// MARK: - Download

	/// Downloads a model and its tokenizer into `modelsFolder` and returns the model folder.
	static func download(
		_ model: CaptionModel,
		into modelsFolder: URL,
		progress: @escaping @Sendable (Double) -> Void
	) async throws -> URL {
		Log.captions.info("Downloading caption model \(model.rawValue, privacy: .public)")
		let folder: URL
		do {
			try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
			folder = try await WhisperKit.download(
				variant: model.rawValue,
				downloadBase: modelsFolder,
				from: repository,
				progressCallback: { download in
					progress(download.fractionCompleted.clamped(to: 0...1))
				}
			)
			try Task.checkCancellation()
			// Fetch the tokenizer now too, so that later runs work offline.
			_ = try await ModelUtilities.loadTokenizer(for: model.variant, tokenizerFolder: modelsFolder)
		} catch {
			if error is CancellationError || Task.isCancelled { throw CancellationError() }
			Log.captions.error("Model download failed: \(String(describing: error), privacy: .public)")
			throw CaptionError.modelDownloadFailed(model: model.title, reason: error.localizedDescription)
		}

		let expected = Self.folder(for: model, in: modelsFolder)
		if folder.standardizedFileURL != expected.standardizedFileURL {
			Log.captions.warning("Model landed in \(folder.path(percentEncoded: false), privacy: .public), expected \(expected.path(percentEncoded: false), privacy: .public)")
		}
		let missing = requiredBundles.filter { name in
			!FileManager.default.fileExists(atPath: folder.appending(path: "\(name).mlmodelc").path(percentEncoded: false))
		}
		guard missing.isEmpty else {
			throw CaptionError.modelDownloadFailed(model: model.title, reason: "The download is incomplete.")
		}
		do {
			try Data().write(to: folder.appending(path: readyMarker))
		} catch {
			throw CaptionError.modelDownloadFailed(model: model.title, reason: error.localizedDescription)
		}
		progress(1)
		Log.captions.info("Caption model \(model.rawValue, privacy: .public) is ready")
		return folder
	}

	// MARK: - Transcription

	/// Loads the model from `modelFolder` and transcribes the audio of `audio`.
	static func transcribe(
		audio: URL,
		model: CaptionModel,
		modelFolder: URL,
		modelsFolder: URL,
		language: String?,
		progress: @escaping @Sendable (CaptionProgress) -> Void
	) async throws -> CaptionTranscript {
		progress(.loading)
		let samples = try await AudioSampleLoader.monoSamples(from: audio)
		Log.captions.info("Decoded \(samples.count / Int(AudioSampleLoader.sampleRate), privacy: .public)s of audio")
		// Less than half a second can't hold a word.
		guard samples.count >= Int(AudioSampleLoader.sampleRate / 2) else { throw CaptionError.noSpeechFound }
		try Task.checkCancellation()

		let recognizer: WhisperKit
		do {
			let config = WhisperKitConfig(
				model: model.rawValue,
				downloadBase: modelsFolder,
				modelRepo: repository,
				modelFolder: modelFolder.path(percentEncoded: false),
				tokenizerFolder: modelsFolder,
				verbose: false,
				logLevel: .none,
				prewarm: false,
				load: true,
				download: false
			)
			recognizer = try await WhisperKit(config)
		} catch {
			if error is CancellationError || Task.isCancelled { throw CancellationError() }
			Log.captions.error("Model load failed: \(String(describing: error), privacy: .public)")
			throw CaptionError.modelLoadFailed(model: model.title, reason: error.localizedDescription)
		}
		try Task.checkCancellation()

		let options = DecodingOptions(
			verbose: false,
			task: .transcribe,
			language: language,
			usePrefillPrompt: language != nil,
			detectLanguage: language == nil,
			skipSpecialTokens: true,
			withoutTimestamps: false,
			wordTimestamps: true,
			chunkingStrategy: .vad
		)

		progress(.transcribing(0))
		let poller = progressPoller(for: recognizer.progress, report: progress)
		defer { poller.cancel() }

		let results: [TranscriptionResult]
		do {
			results = try await recognizer.transcribe(audioArray: samples, decodeOptions: options)
		} catch {
			if error is CancellationError || Task.isCancelled { throw CancellationError() }
			Log.captions.error("Transcription failed: \(String(describing: error), privacy: .public)")
			throw CaptionError.transcriptionFailed(reason: error.localizedDescription)
		}
		try Task.checkCancellation()
		poller.cancel()
		progress(.transcribing(1))

		let raw = results.flatMap(\.segments).map(RawSegment.init)
		let segments = SegmentBuilder.captionSegments(from: raw)
		guard !segments.isEmpty else { throw CaptionError.noSpeechFound }
		let detected = results.first.map(\.language).flatMap { $0.isEmpty ? nil : $0 }
		Log.captions.info("Transcribed \(segments.count, privacy: .public) segments, language \(detected ?? "?", privacy: .public)")
		return CaptionTranscript(segments: segments, language: language ?? detected)
	}

	/// Reports the recognizer's progress a few times a second, never going backwards.
	private static func progressPoller(
		for tracker: Progress,
		report: @escaping @Sendable (CaptionProgress) -> Void
	) -> Task<Void, Never> {
		Task {
			var last = 0.0
			while !Task.isCancelled {
				let fraction = min(tracker.fractionCompleted, 0.99)
				if fraction > last + 0.005 {
					last = fraction
					report(.transcribing(fraction))
				}
				try? await Task.sleep(for: .milliseconds(250))
			}
		}
	}
}

extension RawSegment {
	fileprivate init(_ segment: TranscriptionSegment) {
		self.init(
			text: segment.text,
			start: Double(segment.start),
			end: Double(segment.end),
			words: (segment.words ?? []).map { Word(text: $0.word, start: Double($0.start), end: Double($0.end)) }
		)
	}
}

extension CaptionModel {
	/// The recognizer's family for this model, used to find its tokenizer.
	fileprivate var variant: ModelVariant {
		switch self {
		case .base: .base
		case .small: .small
		case .largeTurbo: .largev3
		}
	}
}
