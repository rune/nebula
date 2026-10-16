import Foundation

/// Lightweight loudness statistics (used by Polish and speech detection).
public enum AudioLevels {
	/// Linear RMS level (0...1) of each consecutive `frameDuration`-second frame of the first audio
	/// track of `url`, mixed to mono. Frame `i` covers `[i * frameDuration, (i + 1) * frameDuration)`;
	/// the last frame may be partial. Returns `[]` when the file has no audio.
	public static func rmsLevels(url: URL, frameDuration: Double = 0.02) async throws -> [Float] {
		guard frameDuration > 0, frameDuration.isFinite else {
			throw AudioProcessingError.invalidArgument("Frame duration must be positive.")
		}
		guard let source = try await AudioSource.load(url: url) else { return [] }
		return try await FrameStatsAccumulator.measure(source, samplesPerFrame: source.sampleRate * frameDuration).rms
	}
}
