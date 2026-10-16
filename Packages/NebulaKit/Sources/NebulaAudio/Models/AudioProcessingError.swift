import Foundation

/// Errors thrown by the audio analysis and processing services.
public enum AudioProcessingError: LocalizedError, Hashable, Sendable {
	/// The file does not exist.
	case fileNotFound(URL)
	/// The file exists but could not be opened as media.
	case unreadableFile(URL, reason: String)
	/// The file has no audio track.
	case noAudioTrack(URL)
	/// Decoding the audio failed part-way through.
	case decodingFailed(reason: String)
	/// Writing the processed audio failed.
	case encodingFailed(reason: String)
	/// A parameter was out of its valid range.
	case invalidArgument(String)

	public var errorDescription: String? {
		switch self {
		case .fileNotFound(let url):
			"The audio file “\(url.lastPathComponent)” could not be found."
		case .unreadableFile(let url, let reason):
			"The file “\(url.lastPathComponent)” could not be opened. \(reason)"
		case .noAudioTrack(let url):
			"The file “\(url.lastPathComponent)” has no audio."
		case .decodingFailed(let reason):
			"The audio could not be read. \(reason)"
		case .encodingFailed(let reason):
			"The processed audio could not be saved. \(reason)"
		case .invalidArgument(let message):
			"Invalid audio setting: \(message)"
		}
	}
}
