import Foundation
import NebulaCore

/// Transcribes recordings into captions on device.
///
/// Models are downloaded on first use into `modelsFolder` and reused afterwards (offline).
/// Transcriptions run one at a time, in call order, so that only one model is in memory;
/// concurrent requests for the same model download share one download. All heavy work runs
/// off the actor, so calls never block the caller's thread. Cancelling the calling task
/// cancels the download or transcription.
public actor CaptionTranscriber {
	/// Folder that holds downloaded models, for example `~/Library/Application Support/Nebula/Models`.
	public nonisolated let modelsFolder: URL

	private var downloads: [CaptionModel: Task<URL, any Error>] = [:]
	private var queueTail: Task<Void, Never>?

	/// Creates a transcriber that stores models in `modelsFolder` (created when needed).
	public init(modelsFolder: URL) {
		self.modelsFolder = modelsFolder
	}

	/// The folder a model is (or will be) stored in.
	public nonisolated func folder(for model: CaptionModel) -> URL {
		SpeechRecognizer.folder(for: model, in: modelsFolder)
	}

	/// True when the model is fully downloaded and can be used offline.
	public func isModelDownloaded(_ model: CaptionModel) -> Bool {
		SpeechRecognizer.isReady(folder(for: model))
	}

	/// Downloads a model ahead of time (for example from Settings). Returns at once when it is
	/// already downloaded.
	///
	/// - Parameter progress: Called with the completed fraction, 0–1, from a background thread.
	/// - Returns: The model folder.
	@discardableResult
	public func downloadModel(
		_ model: CaptionModel,
		progress: @escaping @Sendable (Double) -> Void = { _ in }
	) async throws -> URL {
		if isModelDownloaded(model) { return folder(for: model) }
		if let running = downloads[model] {
			return try await withTaskCancellationHandler {
				try await running.value
			} onCancel: {
				running.cancel()
			}
		}

		let modelsFolder = modelsFolder
		let task = Task<URL, any Error> {
			try await SpeechRecognizer.download(model, into: modelsFolder, progress: progress)
		}
		downloads[model] = task
		defer { downloads[model] = nil }
		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}

	/// Deletes a downloaded model to free disk space. Does nothing when it isn't downloaded.
	public func deleteModel(_ model: CaptionModel) throws {
		let folder = folder(for: model)
		guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
		try FileManager.default.removeItem(at: folder)
		Log.captions.info("Deleted caption model \(model.rawValue, privacy: .public)")
	}

	/// Transcribes the speech in an audio or video file.
	///
	/// Downloads the model first if needed. The returned segments are in the file's time, have
	/// word timings, and their text is cleaned of recognizer tokens and non-speech markers such
	/// as "[Music]". Pass them through ``CaptionLayout/lines(for:maxCharacters:)`` for display.
	///
	/// - Parameters:
	///   - audio: Any file with an audio track (for example `recording.mov`). All audio tracks are mixed.
	///   - model: The model to use.
	///   - language: A language code such as "en" or "de"; nil detects the language.
	///   - progress: Called from a background thread as the work advances.
	/// - Throws: ``CaptionError`` (for example ``CaptionError/noSpeechFound``) or `CancellationError`.
	public func transcribe(
		audio: URL,
		model: CaptionModel,
		language: String? = nil,
		progress: @escaping @Sendable (CaptionProgress) -> Void
	) async throws -> [CaptionSegment] {
		try await transcript(audio: audio, model: model, language: language, progress: progress).segments
	}

	/// Like ``transcribe(audio:model:language:progress:)``, but also returns the spoken language.
	public func transcript(
		audio: URL,
		model: CaptionModel,
		language: String? = nil,
		progress: @escaping @Sendable (CaptionProgress) -> Void
	) async throws -> CaptionTranscript {
		let modelFolder: URL
		if isModelDownloaded(model) {
			modelFolder = folder(for: model)
		} else {
			progress(.downloading(0))
			modelFolder = try await downloadModel(model) { progress(.downloading($0)) }
		}

		let modelsFolder = modelsFolder
		let language = Self.recognizerLanguage(language)
		Log.captions.info("Transcribing \(audio.lastPathComponent, privacy: .public) with \(model.rawValue, privacy: .public)")
		return try await serially {
			try await SpeechRecognizer.transcribe(
				audio: audio,
				model: model,
				modelFolder: modelFolder,
				modelsFolder: modelsFolder,
				language: language,
				progress: progress
			)
		}
	}

	/// Reduces a locale-style code ("en-US", "pt_BR") to the recognizer's form ("en", "pt").
	static func recognizerLanguage(_ language: String?) -> String? {
		guard let language else { return nil }
		let code = language.prefix { $0 != "-" && $0 != "_" }.lowercased()
		return code.isEmpty ? nil : code
	}

	/// Runs `work` after every previously queued job finished.
	private func serially<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
		let previous = queueTail
		let job = Task<T, any Error> {
			await previous?.value
			try Task.checkCancellation()
			return try await work()
		}
		queueTail = Task { _ = await job.result }
		return try await withTaskCancellationHandler {
			try await job.value
		} onCancel: {
			job.cancel()
		}
	}
}
