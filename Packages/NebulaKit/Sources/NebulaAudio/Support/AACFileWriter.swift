import AVFoundation

/// Writes mono float samples to an AAC `.m4a` file.
final class AACFileWriter {
	private let file: AVAudioFile
	private let format: AVAudioFormat

	init(url: URL, sampleRate: Double) throws {
		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatMPEG4AAC,
			AVSampleRateKey: sampleRate,
			AVNumberOfChannelsKey: 1,
			AVEncoderBitRateKey: 128_000,
		]
		do {
			file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
		} catch {
			throw AudioProcessingError.encodingFailed(reason: error.localizedDescription)
		}
		format = file.processingFormat
	}

	func write(_ samples: [Float]) throws {
		guard !samples.isEmpty else { return }
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
			let channel = buffer.floatChannelData?[0]
		else {
			throw AudioProcessingError.encodingFailed(reason: "Could not allocate an audio buffer.")
		}
		samples.withUnsafeBufferPointer { source in
			guard let base = source.baseAddress else { return }
			channel.update(from: base, count: samples.count)
		}
		buffer.frameLength = AVAudioFrameCount(samples.count)
		do {
			try file.write(from: buffer)
		} catch {
			throw AudioProcessingError.encodingFailed(reason: error.localizedDescription)
		}
	}

	func close() {
		file.close()
	}
}
