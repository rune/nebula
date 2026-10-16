import AVFoundation
import Foundation
import NebulaAudio
import NebulaCore

/// A project turned into something AVFoundation can play, read or export: the edited
/// timeline (cuts and speed applied), the per-frame compositor and the audio mix.
public struct PlayableComposition: @unchecked Sendable {
	public let asset: AVComposition
	public let videoComposition: AVVideoComposition
	public let audioMix: AVAudioMix
	public let renderSize: CGSize
	public let scene: RenderScene
}

public enum CompositionBuilder {
	public enum BuildError: LocalizedError {
		case noVideo

		public var errorDescription: String? {
			switch self {
			case .noVideo: "The recording has no video track."
			}
		}
	}

	public struct Media: Sendable {
		public var video: URL
		public var microphone: URL?
		public var music: URL?
		/// Speech ranges in source time, for ducking music.
		public var speech: [TimeRange]

		public init(video: URL, microphone: URL? = nil, music: URL? = nil, speech: [TimeRange] = []) {
			self.video = video
			self.microphone = microphone
			self.music = music
			self.speech = speech
		}
	}

	static let timescale: CMTimeScale = 60_000

	static func time(_ seconds: Double) -> CMTime {
		CMTime(seconds: seconds, preferredTimescale: timescale)
	}

	public static func build(scene: RenderScene, media: Media, renderSize: CGSize, frameRate: Int = 60, quality: RenderQuality) async throws -> PlayableComposition {
		let composition = AVMutableComposition()
		let videoAsset = AVURLAsset(url: media.video)
		guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
			let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
		else { throw BuildError.noVideo }

		let systemSource = try await videoAsset.loadTracks(withMediaType: .audio).first
		let systemTrack = systemSource.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
		var micSource: AVAssetTrack?
		if let mic = media.microphone {
			micSource = try await AVURLAsset(url: mic).loadTracks(withMediaType: .audio).first
		}
		let micTrack = micSource.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }

		let videoRange = try await sourceVideo.load(.timeRange)
		let systemRange = try await systemSource?.load(.timeRange)
		let micRange = try await micSource?.load(.timeRange)

		// Lay out the kept segments back to back, then scale sped-up ones.
		var cursor = CMTime.zero
		for segment in scene.timeMap.segments {
			let range = CMTimeRange(start: time(segment.source.start), end: time(segment.source.end))
			let videoPart = range.intersection(videoRange)
			guard videoPart.duration > .zero else { continue }
			try videoTrack.insertTimeRange(videoPart, of: sourceVideo, at: cursor)
			if let systemTrack, let systemSource, let systemRange {
				let part = range.intersection(systemRange)
				if part.duration > .zero { try? systemTrack.insertTimeRange(part, of: systemSource, at: cursor + (part.start - range.start)) }
			}
			if let micTrack, let micSource, let micRange {
				let part = range.intersection(micRange)
				if part.duration > .zero { try? micTrack.insertTimeRange(part, of: micSource, at: cursor + (part.start - range.start)) }
			}
			let scaled = time(segment.source.duration / segment.rate)
			if segment.rate != 1 {
				composition.scaleTimeRange(CMTimeRange(start: cursor, duration: videoPart.duration), toDuration: scaled)
			}
			cursor = cursor + scaled
		}

		// Background music loops under the finished timeline.
		var musicTrack: AVMutableCompositionTrack?
		if let musicURL = media.music, let musicSettings = scene.project.audio.music,
			let musicSource = try await AVURLAsset(url: musicURL).loadTracks(withMediaType: .audio).first {
			let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
			let musicRange = try await musicSource.load(.timeRange)
			var position = CMTime.zero
			while (position < cursor) && (musicRange.duration > CMTime.zero) {
				let remaining = cursor - position
				let length = CMTimeMinimum(musicRange.duration, remaining)
				try track?.insertTimeRange(CMTimeRange(start: musicRange.start, duration: length), of: musicSource, at: position)
				position = position + length
				if !musicSettings.loop { break }
			}
			musicTrack = track
		}

		let mix = AVMutableAudioMix()
		var parameters: [AVMutableAudioMixInputParameters] = []
		let audio = scene.project.audio
		if let systemTrack {
			parameters.append(volumeParameters(track: systemTrack, base: audio.systemVolume, channel: .system, scene: scene))
		}
		if let micTrack {
			parameters.append(volumeParameters(track: micTrack, base: audio.microphoneVolume, channel: .microphone, scene: scene))
		}
		if let musicTrack, let music = audio.music {
			let p = AVMutableAudioMixInputParameters(track: musicTrack)
			let speech = media.speech.compactMap { range -> TimeRange? in
				guard let start = scene.timeMap.outputTime(forSource: scene.timeMap.nearestKeptSourceTime(to: range.start)),
					let end = scene.timeMap.outputTime(forSource: min(range.end, scene.project.media.duration)) else { return nil }
				return end > start ? TimeRange(start: start, end: end) : nil
			}
			let envelope = DuckingPlanner.envelope(speech: speech, duration: scene.outputDuration, duckTo: music.duckTo)
			applyEnvelope(envelope, base: music.volume, to: p)
			parameters.append(p)
		}
		mix.inputParameters = parameters

		let instruction = SceneInstruction(
			timeRange: CMTimeRange(start: .zero, duration: cursor),
			scene: scene,
			quality: quality,
			videoTrackID: videoTrack.trackID
		)
		let videoComposition = AVMutableVideoComposition()
		videoComposition.customVideoCompositorClass = SceneVideoCompositor.self
		videoComposition.instructions = [instruction]
		videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
		videoComposition.renderSize = renderSize
		videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
		videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
		videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

		return PlayableComposition(asset: composition, videoComposition: videoComposition, audioMix: mix, renderSize: renderSize, scene: scene)
	}

	/// Base volume with the project's volume items (in output time), using short ramps to avoid clicks.
	static func volumeParameters(track: AVCompositionTrack, base: Double, channel: VolumeItem.Channel, scene: RenderScene) -> AVMutableAudioMixInputParameters {
		let p = AVMutableAudioMixInputParameters(track: track)
		var points: [GainEnvelope.Point] = [GainEnvelope.Point(time: 0, gain: base)]
		let items = scene.project.audio.volumes.filter { $0.channel == .all || $0.channel == channel }
		for item in items {
			for segment in scene.timeMap.segments {
				guard let overlap = segment.source.intersection(item.range) else { continue }
				let start = segment.outputStart + (overlap.start - segment.source.start) / segment.rate
				let end = segment.outputStart + (overlap.end - segment.source.start) / segment.rate
				points.append(GainEnvelope.Point(time: start, gain: base))
				points.append(GainEnvelope.Point(time: start + 0.03, gain: base * item.gain))
				points.append(GainEnvelope.Point(time: max(start + 0.03, end - 0.03), gain: base * item.gain))
				points.append(GainEnvelope.Point(time: end, gain: base))
			}
		}
		applyEnvelope(GainEnvelope(points: points.sorted { $0.time < $1.time }), base: 1, to: p)
		return p
	}

	static func applyEnvelope(_ envelope: GainEnvelope, base: Double, to parameters: AVMutableAudioMixInputParameters) {
		let points = envelope.points
		guard let first = points.first else {
			parameters.setVolume(Float(base), at: .zero)
			return
		}
		parameters.setVolume(Float(base * first.gain), at: .zero)
		for (a, b) in zip(points, points.dropFirst()) where b.time > a.time {
			parameters.setVolumeRamp(
				fromStartVolume: Float(base * a.gain),
				toEndVolume: Float(base * b.gain),
				timeRange: CMTimeRange(start: time(a.time), end: time(b.time))
			)
		}
	}
}
