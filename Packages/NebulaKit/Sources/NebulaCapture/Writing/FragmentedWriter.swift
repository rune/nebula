import AVFoundation
import Foundation
import os
import VideoToolbox

/// One `.mov` file written in 2-second fragments, so a crash or power loss loses at most the
/// last couple of seconds. Samples are re-timed to start at zero and to skip paused time.
final class FragmentedWriter: @unchecked Sendable {
	struct VideoFormat {
		var width: Int
		var height: Int
		var fps: Int
		var bitrate: Int
	}

	private static let logger = Logger(subsystem: "app.nebula", category: "capture")
	private let writer: AVAssetWriter
	private let videoInput: AVAssetWriterInput?
	private let audioInput: AVAssetWriterInput?
	private var lastVideoSample: CMSampleBuffer?
	private var lastVideoTime: CMTime = .invalid
	private(set) var started = false

	init(url: URL, video: VideoFormat?, audioChannels: Int?) throws {
		try? FileManager.default.removeItem(at: url)
		writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
		writer.shouldOptimizeForNetworkUse = false

		if let video {
			let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
				AVVideoCodecKey: AVVideoCodecType.hevc,
				AVVideoWidthKey: video.width,
				AVVideoHeightKey: video.height,
				AVVideoColorPropertiesKey: [
					AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
					AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
					AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
				],
				AVVideoCompressionPropertiesKey: [
					AVVideoAverageBitRateKey: video.bitrate,
					AVVideoExpectedSourceFrameRateKey: video.fps,
					AVVideoMaxKeyFrameIntervalDurationKey: 2,
					AVVideoAllowFrameReorderingKey: false,
					AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
				],
			])
			input.expectsMediaDataInRealTime = true
			writer.add(input)
			videoInput = input
		} else {
			videoInput = nil
		}

		if let channels = audioChannels {
			let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
				AVFormatIDKey: kAudioFormatMPEG4AAC,
				AVSampleRateKey: 48_000,
				AVNumberOfChannelsKey: channels,
				AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
			])
			input.expectsMediaDataInRealTime = true
			writer.add(input)
			audioInput = input
		} else {
			audioInput = nil
		}
	}

	func start(at time: CMTime) {
		guard !started else { return }
		writer.startWriting()
		writer.startSession(atSourceTime: .zero)
		started = true
	}

	/// Appends a video frame at `time` (already relative to the recording start).
	func appendVideo(_ sample: CMSampleBuffer, at time: CMTime) {
		guard started, let input = videoInput, input.isReadyForMoreMediaData, time > lastVideoTime || !lastVideoTime.isValid,
			let retimed = sample.retimed(to: time) else { return }
		if input.append(retimed) {
			lastVideoSample = retimed
			lastVideoTime = time
		} else if let error = writer.error {
			Self.logger.error("Video append failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	func appendAudio(_ sample: CMSampleBuffer, at time: CMTime) {
		guard started, let input = audioInput, input.isReadyForMoreMediaData, let retimed = sample.retimed(to: time) else { return }
		input.append(retimed)
	}

	/// Repeats the last frame at `end` so the file lasts until the moment recording stopped,
	/// even if the screen didn't change at the end. Then closes the file.
	func finish(at end: CMTime) async {
		guard started else {
			writer.cancelWriting()
			return
		}
		if let last = lastVideoSample, let input = videoInput, end > lastVideoTime, input.isReadyForMoreMediaData,
			let held = last.retimed(to: end) {
			input.append(held)
		}
		videoInput?.markAsFinished()
		audioInput?.markAsFinished()
		writer.endSession(atSourceTime: end)
		await writer.finishWriting()
		if writer.status != .completed {
			Self.logger.error("Writer finished with status \(self.writer.status.rawValue): \(self.writer.error?.localizedDescription ?? "-", privacy: .public)")
		}
	}

	func cancel() {
		writer.cancelWriting()
	}

	var error: Error? { writer.error }
}

extension CMSampleBuffer {
	/// A copy presented at `time` (decode time cleared).
	func retimed(to time: CMTime) -> CMSampleBuffer? {
		var count: CMItemCount = 0
		CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
		guard count > 0 else { return nil }
		var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
		CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
		let offset = time - timings[0].presentationTimeStamp
		for i in timings.indices {
			timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + offset
			timings[i].decodeTimeStamp = .invalid
		}
		var copy: CMSampleBuffer?
		CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy)
		return copy
	}
}
