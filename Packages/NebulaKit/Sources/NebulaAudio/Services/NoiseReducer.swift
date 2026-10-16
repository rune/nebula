import Accelerate
import Foundation

/// Offline noise reduction by STFT spectral gating.
///
/// Two streaming passes over the input:
/// 1. Analysis: estimates the noise power spectrum from the quietest ~10 % of frames.
/// 2. Processing: applies a soft, time- and frequency-smoothed gain mask to every frame and
///    rebuilds the signal by Hann-windowed overlap-add.
///
/// Only a few frames are held in memory at a time, so long recordings are fine. The output is a
/// mono AAC `.m4a` at the input's sample rate with exactly the input's length (the decoded
/// duration may differ by a few milliseconds of encoder padding).
public enum NoiseReducer {
	/// Number of samples handed to the encoder per write.
	private static let writeChunk = 16_384
	/// Share of the progress range spent on the analysis pass.
	private static let analysisShare = 0.3

	/// Denoises the first audio track of `input` and writes the result to `output`.
	///
	/// Multichannel input is mixed to mono. `output` is replaced atomically: on failure or
	/// cancellation any existing file there is left untouched. Decoding and encoding run on a
	/// dedicated dispatch queue, not the Swift concurrency pool; cancelling the calling task stops
	/// the work within one decoded chunk.
	/// - Parameters:
	///   - strength: 0...1. 0 leaves the audio unchanged; 1 gates hardest and attenuates noise by up to 30 dB.
	///   - progress: called with increasing values from 0 to 1 as work advances, on a background thread.
	public static func process(
		input: URL,
		output: URL,
		strength: Double = 0.8,
		progress: (@Sendable (Double) -> Void)? = nil
	) async throws {
		guard strength.isFinite else { throw AudioProcessingError.invalidArgument("Strength must be a number.") }
		progress?(0)
		guard let source = try await AudioSource.load(url: input) else {
			throw AudioProcessingError.noAudioTrack(input)
		}
		try await BlockingWork.run { cancellation in
			try run(source: source, output: output, strength: strength, progress: progress, cancellation: cancellation)
		}
		progress?(1)
	}

	/// Both passes, synchronously. Runs inside `BlockingWork`.
	private static func run(
		source: AudioSource,
		output: URL,
		strength: Double,
		progress: (@Sendable (Double) -> Void)?,
		cancellation: CancellationFlag
	) throws {
		let started = Date()
		guard let gate = SpectralGate(sampleRate: source.sampleRate, strength: strength) else {
			throw AudioProcessingError.invalidArgument("Unsupported sample rate \(source.sampleRate) Hz.")
		}
		let totalSamples = try estimateNoise(
			source: source, gate: gate, cancellation: cancellation
		) { fraction in
			progress?(fraction * analysisShare)
		}

		let temporaryURL = output.deletingLastPathComponent()
			.appending(path: ".\(UUID().uuidString)-\(output.deletingPathExtension().lastPathComponent).m4a")
		do {
			let written = try render(
				source: source, gate: gate, to: temporaryURL, totalSamples: totalSamples, cancellation: cancellation
			) { fraction in
				progress?(analysisShare + (1 - analysisShare) * fraction)
			}
			try replaceItem(at: output, with: temporaryURL)
			let elapsed = Date().timeIntervalSince(started)
			AudioLog.logger.info(
				"Noise reduction: \(Double(written) / source.sampleRate, format: .fixed(precision: 2)) s of audio in \(elapsed, format: .fixed(precision: 2)) s"
			)
		} catch {
			try? FileManager.default.removeItem(at: temporaryURL)
			throw error
		}
	}

	/// Pass 1: feeds every full frame to the noise profile estimator and sets the gate's profile.
	/// Returns the number of input samples.
	private static func estimateNoise(
		source: AudioSource,
		gate: SpectralGate,
		cancellation: CancellationFlag,
		progress: (Double) -> Void
	) throws -> Int {
		let reader = try source.makeReader()
		let expectedSamples = max(1, source.duration * source.sampleRate)
		var estimator = NoiseProfileEstimator(binCount: gate.binCount)
		var frames = FrameBuffer(size: gate.size, hop: gate.hop)
		var frame = [Float](repeating: 0, count: gate.size)
		var samplesRead = 0
		while let chunk = try reader.nextChunk() {
			try cancellation.check()
			samplesRead += chunk.count
			frames.append(chunk)
			while frames.nextFrame(into: &frame) {
				let (power, level) = gate.analyse(frame)
				estimator.add(power: power, levelDB: level)
			}
			progress(min(1, Double(samplesRead) / expectedSamples))
		}
		if let profile = estimator.profile() {
			gate.setNoiseProfile(profile)
		} else {
			AudioLog.logger.info(
				"Noise reduction: no usable noise frames in \(source.url.lastPathComponent, privacy: .public)"
			)
		}
		return samplesRead
	}

	/// Pass 2: gates every frame, overlap-adds the result and writes it as AAC.
	/// Returns the number of samples written.
	private static func render(
		source: AudioSource,
		gate: SpectralGate,
		to url: URL,
		totalSamples: Int,
		cancellation: CancellationFlag,
		progress: (Double) -> Void
	) throws -> Int {
		let reader = try source.makeReader()
		let writer = try AACFileWriter(url: url, sampleRate: source.sampleRate)
		let size = gate.size
		let hop = gate.hop
		// Leading zeros give the first real samples full overlap; output is delayed by this much.
		let latency = size - hop
		var frames = FrameBuffer(size: size, hop: hop, leadingZeros: latency)
		var frame = [Float](repeating: 0, count: size)
		var overlap = [Float](repeating: 0, count: size)
		var pending: [Float] = []
		pending.reserveCapacity(writeChunk + size)
		var paddedPosition = 0
		var written = 0
		var consumed = 0

		func drainFrames() throws {
			while frames.nextFrame(into: &frame) {
				let processed = gate.process(frame)
				overlap.withUnsafeMutableBufferPointer { buffer in
					guard let base = buffer.baseAddress else { return }
					vDSP_vadd(base, 1, processed, 1, base, 1, vDSP_Length(size))
				}
				// The first `hop` samples are complete: no later frame overlaps them.
				let firstRealIndex = max(0, latency - paddedPosition)
				if firstRealIndex < hop {
					let take = min(hop - firstRealIndex, consumed - written)
					if take > 0 {
						pending.append(contentsOf: overlap[firstRealIndex..<(firstRealIndex + take)])
						written += take
					}
				}
				paddedPosition += hop
				overlap.removeFirst(hop)
				overlap.append(contentsOf: repeatElement(0, count: hop))
				if pending.count >= writeChunk {
					try writer.write(pending)
					pending.removeAll(keepingCapacity: true)
				}
			}
		}

		while let chunk = try reader.nextChunk() {
			try cancellation.check()
			consumed += chunk.count
			frames.append(chunk)
			try drainFrames()
			progress(min(1, Double(consumed) / Double(max(1, totalSamples))))
		}
		frames.appendZeros(size + hop)
		try drainFrames()
		if !pending.isEmpty {
			try writer.write(pending)
		}
		writer.close()
		return written
	}

	private static func replaceItem(at destination: URL, with source: URL) throws {
		let fileManager = FileManager.default
		do {
			if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
				_ = try fileManager.replaceItemAt(destination, withItemAt: source)
			} else {
				try fileManager.moveItem(at: source, to: destination)
			}
		} catch {
			throw AudioProcessingError.encodingFailed(reason: error.localizedDescription)
		}
	}
}
