import Foundation

/// Progress reported while captions are generated.
public enum CaptionProgress: Sendable, Hashable {
	/// The model is being downloaded; the value is the completed fraction, 0–1.
	case downloading(Double)
	/// The model is being loaded (and, on first use, optimized for this Mac) and the audio decoded.
	case loading
	/// Speech is being transcribed; the value is the completed fraction, 0–1.
	case transcribing(Double)

	/// Completed fraction of the current phase, or nil when it is indeterminate.
	public var fractionCompleted: Double? {
		switch self {
		case .downloading(let fraction), .transcribing(let fraction): fraction.clamped(to: 0...1)
		case .loading: nil
		}
	}

	/// Short user-facing status, for example "Downloading model… 42%".
	public var title: String {
		switch self {
		case .downloading(let fraction): "Downloading model… \(Self.percent(fraction))"
		case .loading: "Preparing…"
		case .transcribing(let fraction): "Transcribing… \(Self.percent(fraction))"
		}
	}

	private static func percent(_ fraction: Double) -> String {
		"\(Int((fraction.clamped(to: 0...1) * 100).rounded()))%"
	}
}
