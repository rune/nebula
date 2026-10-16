import AVFoundation
import Foundation
import NebulaCore
import NebulaRender
import Observation
import os

/// Plays the edited project. Every frame is drawn by the same compositor as export.
///
/// Style-only edits swap the video composition in place (no flicker); timeline edits (cuts,
/// speed) rebuild the player item and keep the playhead where it was.
@MainActor
@Observable
public final class PreviewEngine {
	public let player = AVPlayer()
	public private(set) var currentTime: Double = 0
	public private(set) var duration: Double = 0
	public private(set) var isPlaying = false
	public private(set) var isReady = false
	public private(set) var playable: PlayableComposition?
	/// Playback speed in the editor (does not affect export).
	public var playbackRate: Float = 1 {
		didSet {
			player.defaultRate = playbackRate
			if isPlaying { player.rate = playbackRate }
		}
	}

	@ObservationIgnored private var timeObserver: Any?
	@ObservationIgnored private var buildTask: Task<Void, Never>?
	@ObservationIgnored private var pending: (scene: RenderScene, media: CompositionBuilder.Media, canvas: CGSize)?
	@ObservationIgnored private var lastTimeMap: TimeMap?
	@ObservationIgnored private var lastCanvas: CGSize = .zero
	@ObservationIgnored private var lastMediaKey = ""
	private static let logger = Logger(subsystem: "app.nebula", category: "preview")

	public init() {
		player.automaticallyWaitsToMinimizeStalling = false
		timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.currentTime = time.seconds.isFinite ? time.seconds : 0
				let playing = self.player.rate != 0
				if playing != self.isPlaying { self.isPlaying = playing }
				if playing, self.duration > 0, self.currentTime >= self.duration - 0.02 { self.player.pause() }
			}
		}
	}

	/// Rebuilds the preview for a new scene. Calls arriving mid-build coalesce into one more build.
	public func update(scene: RenderScene, media: CompositionBuilder.Media, canvas: CGSize) {
		pending = (scene, media, canvas)
		guard buildTask == nil else { return }
		buildTask = Task { [weak self] in
			while let self, let next = self.pending {
				self.pending = nil
				await self.build(next.scene, media: next.media, canvas: next.canvas)
			}
			self?.buildTask = nil
		}
	}

	private func build(_ scene: RenderScene, media: CompositionBuilder.Media, canvas: CGSize) async {
		do {
			let playable = try await CompositionBuilder.build(scene: scene, media: media, renderSize: canvas, frameRate: 60, quality: .preview)
			let mediaKey = "\(media.video.path)|\(media.microphone?.path ?? "")|\(media.music?.path ?? "")"
			let sameTimeline = lastTimeMap == scene.timeMap && lastCanvas == canvas && mediaKey == lastMediaKey
			if sameTimeline, let item = player.currentItem {
				item.videoComposition = playable.videoComposition
				item.audioMix = playable.audioMix
				if !isPlaying { refreshStillFrame() }
			} else {
				let time = player.currentTime()
				let item = AVPlayerItem(asset: playable.asset)
				item.videoComposition = playable.videoComposition
				item.audioMix = playable.audioMix
				item.audioTimePitchAlgorithm = .timeDomain
				item.seekingWaitsForVideoCompositionRendering = true
				player.replaceCurrentItem(with: item)
				let target = min(time.seconds.isFinite ? time.seconds : 0, scene.outputDuration)
				await player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
			}
			self.playable = playable
			duration = scene.outputDuration
			lastTimeMap = scene.timeMap
			lastCanvas = canvas
			lastMediaKey = mediaKey
			isReady = true
		} catch {
			Self.logger.error("Preview build failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Re-renders the paused frame after an in-place composition change.
	private func refreshStillFrame() {
		let time = player.currentTime()
		player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
	}

	// MARK: Transport

	public func togglePlay() {
		isPlaying ? pause() : play()
	}

	public func play() {
		if currentTime >= duration - 0.05 { seek(to: 0) }
		player.defaultRate = playbackRate
		player.play()
		isPlaying = true
	}

	public func pause() {
		player.pause()
		isPlaying = false
	}

	/// Seeks to an output time. `precise` for final positions; scrubbing uses a small tolerance.
	public func seek(to time: Double, precise: Bool = true) {
		let target = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 60_000)
		let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 30)
		player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
		currentTime = target.seconds
	}

	public func step(frames: Int) {
		pause()
		seek(to: currentTime + Double(frames) / 60)
	}
}
