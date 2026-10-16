import Foundation

/// Errors thrown while generating captions. Messages are written for the user.
public enum CaptionError: LocalizedError, Sendable, Equatable {
	/// The model could not be downloaded (network, disk space, or server problems).
	case modelDownloadFailed(model: String, reason: String)
	/// The model is on disk but could not be loaded.
	case modelLoadFailed(model: String, reason: String)
	/// The media file could not be opened or decoded.
	case audioUnreadable(reason: String)
	/// The media file has no audio track.
	case noAudioTrack
	/// Transcription finished but found nothing to caption.
	case noSpeechFound
	/// The speech recognizer failed.
	case transcriptionFailed(reason: String)

	public var errorDescription: String? {
		switch self {
		case .modelDownloadFailed(let model, _): "Couldn’t download the \(model) caption model."
		case .modelLoadFailed(let model, _): "Couldn’t load the \(model) caption model."
		case .audioUnreadable: "Couldn’t read the audio in this recording."
		case .noAudioTrack: "This recording has no audio to caption."
		case .noSpeechFound: "No speech was found in this recording."
		case .transcriptionFailed: "Captions couldn’t be generated."
		}
	}

	public var failureReason: String? {
		switch self {
		case .modelDownloadFailed(_, let reason), .modelLoadFailed(_, let reason), .audioUnreadable(let reason),
			.transcriptionFailed(let reason):
			reason.isEmpty ? nil : reason
		case .noAudioTrack, .noSpeechFound:
			nil
		}
	}

	public var recoverySuggestion: String? {
		switch self {
		case .modelDownloadFailed: "Check your internet connection and free disk space, then try again."
		case .modelLoadFailed: "Try again. If it keeps failing, delete the model in Settings and download it again."
		case .audioUnreadable: "Make sure the file still exists and plays in other apps."
		case .noAudioTrack: "Record with the microphone or system audio turned on."
		case .noSpeechFound: "Check that the microphone was recording, or try a larger model."
		case .transcriptionFailed: "Try again, or choose a different model."
		}
	}
}
