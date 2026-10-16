import AVFoundation
import Accelerate

/// Decodes an `AudioSource` to mono Float32 PCM, one chunk at a time.
///
/// Multichannel audio is mixed down to mono by averaging the channels. If the track starts after
/// time zero, silence is emitted first so sample indices line up with the asset timeline.
/// `nextChunk()` blocks while AVFoundation decodes, so use it only inside `BlockingWork.run`,
/// never directly on the Swift concurrency pool. Not thread-safe: use it from one thread.
final class PCMStreamReader {
	let url: URL
	/// Sample rate of the decoded audio (the track's native rate).
	let sampleRate: Double
	/// Estimated duration of the audio track in seconds (used for progress and preallocation).
	let duration: Double

	private let reader: AVAssetReader
	private let output: AVAssetReaderTrackOutput
	private var isFirstBuffer = true

	init(source: AudioSource) throws {
		url = source.url
		sampleRate = source.sampleRate
		duration = source.duration
		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		]
		do {
			reader = try AVAssetReader(asset: source.asset)
		} catch {
			throw AudioProcessingError.unreadableFile(source.url, reason: error.localizedDescription)
		}
		output = AVAssetReaderTrackOutput(track: source.track, outputSettings: settings)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else {
			throw AudioProcessingError.unreadableFile(source.url, reason: "The audio format is not supported.")
		}
		reader.add(output)
		guard reader.startReading() else {
			throw AudioProcessingError.unreadableFile(
				source.url, reason: reader.error?.localizedDescription ?? "Reading could not start."
			)
		}
	}

	deinit {
		if reader.status == .reading {
			reader.cancelReading()
		}
	}

	/// Returns the next chunk of mono samples, or `nil` at the end of the track.
	func nextChunk() throws -> [Float]? {
		while true {
			guard let sampleBuffer = output.copyNextSampleBuffer() else {
				if reader.status == .failed {
					throw AudioProcessingError.decodingFailed(reason: reader.error?.localizedDescription ?? "Unknown error.")
				}
				return nil
			}
			guard var samples = Self.monoSamples(from: sampleBuffer) else { continue }
			if isFirstBuffer {
				isFirstBuffer = false
				let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
				if start.isFinite, start > 0.0005 {
					let lead = Int((start * sampleRate).rounded())
					samples = [Float](repeating: 0, count: lead) + samples
				}
			}
			if samples.isEmpty { continue }
			return samples
		}
	}

	/// Copies the interleaved float samples out of `sampleBuffer` and averages the channels.
	private static func monoSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
		guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
			let format = CMSampleBufferGetFormatDescription(sampleBuffer),
			let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
		else { return nil }
		let channels = max(1, Int(asbd.mChannelsPerFrame))
		let length = CMBlockBufferGetDataLength(block)
		let valueCount = length / MemoryLayout<Float>.size
		let frameCount = valueCount / channels
		guard frameCount > 0 else { return [] }

		var interleaved = [Float](repeating: 0, count: valueCount)
		let status = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
			guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
			return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: valueCount * MemoryLayout<Float>.size, destination: base)
		}
		guard status == kCMBlockBufferNoErr else { return nil }
		if channels == 1 { return interleaved }

		var mono = [Float](repeating: 0, count: frameCount)
		interleaved.withUnsafeBufferPointer { source in
			mono.withUnsafeMutableBufferPointer { destination in
				guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
				for channel in 0..<channels {
					vDSP_vadd(src + channel, vDSP_Stride(channels), dst, 1, dst, 1, vDSP_Length(frameCount))
				}
				var scale = 1 / Float(channels)
				vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
			}
		}
		return mono
	}
}
