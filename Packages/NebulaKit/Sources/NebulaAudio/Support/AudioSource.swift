import AVFoundation

/// The first audio track of a media file, with its properties loaded.
///
/// Loading is async (AVFoundation's property loading); decoding is blocking and happens through
/// `makeReader()`, which must be called from `BlockingWork` rather than the Swift concurrency pool.
///
/// `@unchecked Sendable`: every stored property is immutable, and `AVAssetTrack` is an immutable
/// inspection object that AVFoundation allows to be used from any thread; the SDK just does not
/// annotate it as `Sendable`.
struct AudioSource: @unchecked Sendable {
	let url: URL
	let asset: AVURLAsset
	let track: AVAssetTrack
	/// Native sample rate of the track.
	let sampleRate: Double
	/// Estimated duration in seconds (end of the track's time range).
	let duration: Double

	/// Loads the first audio track of `url`. Returns `nil` when the file has no audio track.
	static func load(url: URL) async throws -> AudioSource? {
		guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
			throw AudioProcessingError.fileNotFound(url)
		}
		let asset = AVURLAsset(url: url)
		let track: AVAssetTrack
		let formats: [CMFormatDescription]
		let timeRange: CMTimeRange
		do {
			guard let first = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
			track = first
			(formats, timeRange) = try await track.load(.formatDescriptions, .timeRange)
		} catch {
			throw AudioProcessingError.unreadableFile(url, reason: error.localizedDescription)
		}

		var sampleRate = 48_000.0
		if let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
			asbd.mSampleRate > 0
		{
			sampleRate = asbd.mSampleRate
		}
		let end = timeRange.end.seconds
		return AudioSource(
			url: url, asset: asset, track: track, sampleRate: sampleRate, duration: end.isFinite ? max(0, end) : 0
		)
	}

	/// Starts decoding. Blocking work follows, so call this inside `BlockingWork.run`.
	func makeReader() throws -> PCMStreamReader {
		try PCMStreamReader(source: self)
	}
}
