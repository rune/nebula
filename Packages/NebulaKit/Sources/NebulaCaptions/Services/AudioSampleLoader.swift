import AVFoundation
import CoreMedia
import Foundation

/// Decodes the audio of any audio or video file into 16 kHz mono `Float` samples, the input
/// the speech recognizer expects. All audio tracks are mixed together.
enum AudioSampleLoader {
	static let sampleRate = 16_000.0

	static func monoSamples(from url: URL) async throws -> [Float] {
		guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
			throw CaptionError.audioUnreadable(reason: "The file \(url.lastPathComponent) doesn’t exist.")
		}

		let asset = AVURLAsset(url: url)
		let tracks: [AVAssetTrack]
		do {
			tracks = try await asset.loadTracks(withMediaType: .audio)
		} catch {
			throw CaptionError.audioUnreadable(reason: error.localizedDescription)
		}
		guard !tracks.isEmpty else { throw CaptionError.noAudioTrack }

		let reader: AVAssetReader
		do {
			reader = try AVAssetReader(asset: asset)
		} catch {
			throw CaptionError.audioUnreadable(reason: error.localizedDescription)
		}

		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: sampleRate,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		]
		let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else {
			throw CaptionError.audioUnreadable(reason: "The audio format isn’t supported.")
		}
		reader.add(output)

		var samples: [Float] = []
		if let duration = try? await asset.load(.duration), duration.isNumeric {
			samples.reserveCapacity(Int(duration.seconds * sampleRate) + Int(sampleRate))
		}

		guard reader.startReading() else {
			throw CaptionError.audioUnreadable(reason: reader.error?.localizedDescription ?? "")
		}

		while let buffer = output.copyNextSampleBuffer() {
			if Task.isCancelled {
				reader.cancelReading()
				throw CancellationError()
			}
			guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
			let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
			guard count > 0 else { continue }
			let offset = samples.count
			samples.append(contentsOf: repeatElement(0, count: count))
			let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
				guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
				return CMBlockBufferCopyDataBytes(
					block,
					atOffset: 0,
					dataLength: count * MemoryLayout<Float>.size,
					destination: base + offset * MemoryLayout<Float>.size
				)
			}
			guard status == kCMBlockBufferNoErr else {
				reader.cancelReading()
				throw CaptionError.audioUnreadable(reason: "The audio couldn’t be decoded (error \(status)).")
			}
		}

		if reader.status == .failed {
			throw CaptionError.audioUnreadable(reason: reader.error?.localizedDescription ?? "")
		}
		return samples
	}
}
