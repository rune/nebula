import Foundation

/// A speech recognition model that can transcribe captions on device.
///
/// The raw value is the model's folder name in the remote model repository.
public enum CaptionModel: String, CaseIterable, Sendable, Identifiable {
	/// Smallest and fastest; good for clear speech.
	case base = "openai_whisper-base"
	/// A balance of speed and accuracy.
	case small = "openai_whisper-small"
	/// Most accurate; needs the most disk space and memory.
	case largeTurbo = "openai_whisper-large-v3-v20240930_turbo"

	public var id: String { rawValue }

	/// Display name for pickers and settings.
	public var title: String {
		switch self {
		case .base: "Base"
		case .small: "Small"
		case .largeTurbo: "Large Turbo"
		}
	}

	/// One-line description of the trade-off.
	public var subtitle: String {
		switch self {
		case .base: "Fastest, good for clear speech"
		case .small: "Balanced speed and accuracy"
		case .largeTurbo: "Most accurate, slower and larger"
		}
	}

	/// Approximate download size, for display (for example "145 MB").
	public var approximateSize: String {
		ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
	}

	/// Approximate download size in bytes.
	public var approximateBytes: Int64 {
		switch self {
		case .base: 145_000_000
		case .small: 485_000_000
		case .largeTurbo: 1_600_000_000
		}
	}
}
