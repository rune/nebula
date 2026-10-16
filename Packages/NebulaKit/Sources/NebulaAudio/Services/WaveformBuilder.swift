import Foundation

/// Builds peak envelopes from media files.
public enum WaveformBuilder {
	/// Reads the first audio track of `url` (any audio or video file) and returns its peak envelope.
	///
	/// Multichannel audio is mixed to mono first. Returns an empty waveform when the file has no audio.
	/// The file is decoded in chunks, so memory use does not grow with its length (beyond the peaks).
	/// - Parameter samplesPerSecond: peak values per second; must be positive.
	public static func build(url: URL, samplesPerSecond: Double = 50) async throws -> Waveform {
		guard samplesPerSecond > 0, samplesPerSecond.isFinite else {
			throw AudioProcessingError.invalidArgument("Waveform resolution must be positive.")
		}
		guard let source = try await AudioSource.load(url: url) else {
			AudioLog.logger.debug("No audio track in \(url.lastPathComponent, privacy: .public); empty waveform")
			return .empty(samplesPerSecond: samplesPerSecond)
		}
		let stats = try await FrameStatsAccumulator.measure(source, samplesPerFrame: source.sampleRate / samplesPerSecond)
		return Waveform(samplesPerSecond: samplesPerSecond, peaks: stats.peaks)
	}
}
