import AVFoundation
import Foundation
import NebulaCore
import os
import VideoToolbox

/// Renders a composition to an MP4 with the Mac's hardware encoder. Uses AVAssetReader →
/// AVAssetWriter so bitrate, codec and frame rate are fully under our control.
public enum VideoExporter {
	public enum ExportError: LocalizedError {
		case cannotRead(String)
		case cannotWrite(String)
		case cancelled

		public var errorDescription: String? {
			switch self {
			case .cannotRead(let reason): "Couldn't read the recording: \(reason)"
			case .cannotWrite(let reason): "Couldn't write the video: \(reason)"
			case .cancelled: "Export cancelled."
			}
		}
	}

	private static let logger = Logger(subsystem: "app.nebula", category: "export")

	/// Video bitrate for the settings and size (bits per second).
	public static func bitrate(for settings: ExportSettings, size: CGSize) -> Int {
		let pixels = Double(size.width * size.height)
		let factor = settings.codec == .hevc ? 0.65 : 1
		return Int(pixels * Double(settings.fps) * settings.quality.bitsPerPixel * factor)
	}

	public static func export(
		_ playable: PlayableComposition,
		settings: ExportSettings,
		to url: URL,
		progress: @escaping @Sendable (Double) -> Void
	) async throws {
		try? FileManager.default.removeItem(at: url)
		let asset = playable.asset
		let reader: AVAssetReader
		let writer: AVAssetWriter
		do {
			reader = try AVAssetReader(asset: asset)
			writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
		} catch {
			throw ExportError.cannotRead(error.localizedDescription)
		}
		writer.shouldOptimizeForNetworkUse = true

		let videoTracks = try await asset.loadTracks(withMediaType: .video)
		let audioTracks = try await asset.loadTracks(withMediaType: .audio)
		let duration = try await asset.load(.duration).seconds

		let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		])
		videoOutput.videoComposition = playable.videoComposition
		videoOutput.alwaysCopiesSampleData = false
		guard reader.canAdd(videoOutput) else { throw ExportError.cannotRead("video output") }
		reader.add(videoOutput)

		var audioOutput: AVAssetReaderAudioMixOutput?
		if !audioTracks.isEmpty {
			let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVSampleRateKey: 48_000,
				AVNumberOfChannelsKey: 2,
				AVLinearPCMBitDepthKey: 32,
				AVLinearPCMIsFloatKey: true,
				AVLinearPCMIsNonInterleaved: false,
			])
			output.audioMix = playable.audioMix
			output.audioTimePitchAlgorithm = .spectral
			if reader.canAdd(output) {
				reader.add(output)
				audioOutput = output
			}
		}

		let size = playable.renderSize
		let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
			AVVideoWidthKey: Int(size.width),
			AVVideoHeightKey: Int(size.height),
			AVVideoColorPropertiesKey: [
				AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
				AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
				AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
			],
			AVVideoCompressionPropertiesKey: [
				AVVideoAverageBitRateKey: bitrate(for: settings, size: size),
				AVVideoExpectedSourceFrameRateKey: settings.fps,
				AVVideoMaxKeyFrameIntervalDurationKey: 2,
				AVVideoProfileLevelKey: settings.codec == .hevc
					? kVTProfileLevel_HEVC_Main_AutoLevel as String
					: AVVideoProfileLevelH264HighAutoLevel,
				AVVideoAllowFrameReorderingKey: true,
			],
		])
		videoInput.expectsMediaDataInRealTime = false
		guard writer.canAdd(videoInput) else { throw ExportError.cannotWrite("video input") }
		writer.add(videoInput)

		var audioInput: AVAssetWriterInput?
		if audioOutput != nil {
			let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
				AVFormatIDKey: kAudioFormatMPEG4AAC,
				AVSampleRateKey: 48_000,
				AVNumberOfChannelsKey: 2,
				AVEncoderBitRateKey: 192_000,
			])
			input.expectsMediaDataInRealTime = false
			if writer.canAdd(input) {
				writer.add(input)
				audioInput = input
			}
		}

		guard reader.startReading() else { throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown") }
		guard writer.startWriting() else { throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown") }
		writer.startSession(atSourceTime: .zero)

		let pump = ExportPump(reader: reader, writer: writer)
		// Each output/input pair is only ever touched by its own pump task.
		let video = ExportPump.Pair(output: videoOutput, input: videoInput)
		let audio = audioOutput.flatMap { output in audioInput.map { ExportPump.Pair(output: output, input: $0) } }
		try await withTaskCancellationHandler {
			try await withThrowingTaskGroup(of: Void.self) { group in
				group.addTask {
					try await pump.pump(video, queueLabel: "video") { time in
						progress(duration > 0 ? min(1, time / duration) : 0)
					}
				}
				if let audio {
					group.addTask {
						try await pump.pump(audio, queueLabel: "audio") { _ in }
					}
				}
				try await group.waitForAll()
			}
		} onCancel: {
			pump.cancel()
		}

		if Task.isCancelled || pump.isCancelled {
			writer.cancelWriting()
			try? FileManager.default.removeItem(at: url)
			throw ExportError.cancelled
		}
		if reader.status == .failed {
			writer.cancelWriting()
			throw ExportError.cannotRead(reader.error?.localizedDescription ?? "unknown")
		}
		await writer.finishWriting()
		if writer.status != .completed {
			throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
		}
		progress(1)
		logger.info("Exported \(url.lastPathComponent, privacy: .public)")
	}
}

/// Moves samples from reader outputs to writer inputs on background queues.
final class ExportPump: @unchecked Sendable {
	private let reader: AVAssetReader
	private let writer: AVAssetWriter
	private let lock = OSAllocatedUnfairLock()
	private var cancelled = false

	init(reader: AVAssetReader, writer: AVAssetWriter) {
		self.reader = reader
		self.writer = writer
	}

	var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}

	func cancel() {
		lock.lock()
		cancelled = true
		lock.unlock()
		reader.cancelReading()
	}

	struct Pair: @unchecked Sendable {
		let output: AVAssetReaderOutput
		let input: AVAssetWriterInput
	}

	func pump(_ pair: Pair, queueLabel: String, onTime: @escaping @Sendable (Double) -> Void) async throws {
		let output = pair.output
		let input = pair.input
		let queue = DispatchQueue(label: "app.nebula.export.\(queueLabel)")
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let resumed = OSAllocatedUnfairLock(initialState: false)
			input.requestMediaDataWhenReady(on: queue) { [self] in
				while input.isReadyForMoreMediaData {
					if self.isCancelled || self.writer.status == .failed {
						input.markAsFinished()
						if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume() }
						return
					}
					guard let sample = output.copyNextSampleBuffer() else {
						input.markAsFinished()
						if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume() }
						return
					}
					onTime(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
					if !input.append(sample) {
						input.markAsFinished()
						if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume() }
						return
					}
				}
			}
		}
	}
}
