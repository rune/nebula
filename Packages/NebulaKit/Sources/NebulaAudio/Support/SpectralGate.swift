import Accelerate
import Foundation

/// STFT spectral gate: analyses Hann-windowed frames and attenuates bins near the noise profile.
///
/// Frames use a periodic Hann window for both analysis and synthesis at 75 % overlap, so
/// overlap-adding the processed frames and dividing by 1.5 reconstructs the input exactly when
/// every gain is 1. Gains are a soft mask: a smoothstep from `threshold` to `threshold + width`
/// dB above the noise power, smoothed across neighbouring bins and over time (fast opening,
/// slower closing), and never lower than the strength-dependent floor.
final class SpectralGate {
	let size: Int
	let hop: Int
	let binCount: Int

	/// Sum of the squared window over overlapping frames (periodic Hann at hop = size / 4).
	static let overlapGain: Float = 1.5
	/// Frequency smoothing kernel for the gain mask.
	private static let frequencyKernel: [Float] = [1, 2, 3, 2, 1]

	private let fft: RealFFT
	private let window: [Float]
	private let thresholdDB: Float
	private let widthDB: Float = 6
	private let gainFloor: Float
	private let openCoefficient: Float
	private let closeCoefficient: Float

	private var windowed: [Float]
	private var real: [Float]
	private var imag: [Float]
	private var power: [Float]
	/// Noise power plus a tiny epsilon, per bin.
	private let noiseFloorPower: UnsafeMutablePointer<Float>
	/// Per-bin sum of the frequency kernel taps that fall inside the spectrum.
	private let kernelWeights: UnsafeMutablePointer<Float>
	/// Scratch space for mask computation (5 × binCount + 4 values).
	private let maskScratch: UnsafeMutablePointer<Float>
	private var smoothedMask: [Float]
	private var previousMask: [Float]
	private var output: [Float]

	/// FFT size giving ~40 ms frames at `sampleRate` (2048 at 44.1 / 48 kHz).
	static func frameSize(for sampleRate: Double) -> Int {
		let target = max(256, min(16_384, Int(sampleRate * 0.04)))
		var size = 256
		while size < target { size *= 2 }
		return size
	}

	/// - Parameters:
	///   - strength: 0...1. Higher values gate more and attenuate gated bins further (up to -30 dB).
	init?(sampleRate: Double, strength: Double) {
		let size = Self.frameSize(for: sampleRate)
		guard let fft = RealFFT(size: size) else { return nil }
		self.size = size
		self.hop = size / 4
		self.binCount = size / 2 + 1
		self.fft = fft
		self.window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
		let strength = Float(strength.clamped(to: 0...1))
		self.thresholdDB = 3 + 6 * strength
		self.gainFloor = powf(10, -30 * strength / 20)
		let hopSeconds = Double(size / 4) / sampleRate
		self.openCoefficient = Float(1 - exp(-hopSeconds / 0.005))
		self.closeCoefficient = Float(1 - exp(-hopSeconds / 0.06))
		self.windowed = [Float](repeating: 0, count: size)
		self.real = [Float](repeating: 0, count: size / 2)
		self.imag = [Float](repeating: 0, count: size / 2)
		self.power = [Float](repeating: 0, count: size / 2 + 1)
		let bins = size / 2 + 1
		self.noiseFloorPower = .allocate(capacity: bins)
		noiseFloorPower.initialize(repeating: 1e-20, count: bins)
		self.kernelWeights = .allocate(capacity: bins)
		for bin in 0..<bins {
			var weight: Float = 0
			for tap in 0..<5 where (0..<bins).contains(bin + tap - 2) {
				weight += Self.frequencyKernel[tap]
			}
			kernelWeights[bin] = weight
		}
		self.maskScratch = .allocate(capacity: 5 * bins + 4)
		maskScratch.initialize(repeating: 0, count: 5 * bins + 4)
		self.smoothedMask = [Float](repeating: 0, count: size / 2 + 1)
		self.previousMask = [Float](repeating: 0, count: size / 2 + 1)
		self.output = [Float](repeating: 0, count: size)
	}

	deinit {
		noiseFloorPower.deallocate()
		kernelWeights.deallocate()
		maskScratch.deallocate()
	}

	/// Sets the noise power spectrum (`binCount` values, same scale as `analyse`).
	func setNoiseProfile(_ profile: [Float]) {
		guard profile.count == binCount else { return }
		for bin in 0..<binCount {
			noiseFloorPower[bin] = profile[bin] + 1e-20
		}
	}

	/// Windows and transforms `frame`, returning its power spectrum and its level in dBFS (RMS of the raw frame).
	func analyse(_ frame: [Float]) -> (power: [Float], levelDB: Float) {
		transform(frame)
		var meanSquare: Float = 0
		vDSP_measqv(frame, 1, &meanSquare, vDSP_Length(size))
		return (power, 10 * log10(max(meanSquare, 1e-20)))
	}

	/// Gates `frame` and returns the synthesis-windowed result, already divided by the overlap gain.
	/// Overlap-add consecutive results at `hop` spacing to rebuild the signal.
	func process(_ frame: [Float]) -> [Float] {
		transform(frame)
		computeMask()
		let half = size / 2
		// Apply gains: bins 1..<half are (real, imag); real[0] is DC and imag[0] is Nyquist.
		let nyquistGain = smoothedMask[half]
		let nyquist = imag[0] * nyquistGain
		Self.multiply(&real, by: smoothedMask, count: half)
		Self.multiply(&imag, by: smoothedMask, count: half)
		imag[0] = nyquist
		fft.inverse(real: &real, imag: &imag, output: &output)
		Self.multiply(&output, by: window, count: size, scale: 1 / (2 * Float(size) * Self.overlapGain))
		return output
	}

	/// `values[i] *= factors[i] * scale` for the first `count` elements.
	private static func multiply(_ values: inout [Float], by factors: [Float], count: Int, scale: Float = 1) {
		values.withUnsafeMutableBufferPointer { buffer in
			guard let base = buffer.baseAddress else { return }
			vDSP_vmul(base, 1, factors, 1, base, 1, vDSP_Length(count))
			if scale != 1 {
				var scale = scale
				vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(count))
			}
		}
	}

	private func transform(_ frame: [Float]) {
		vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(size))
		fft.forward(windowed, real: &real, imag: &imag)
		fft.power(real: real, imag: imag, into: &power)
	}

	private func computeMask() {
		let count = binCount
		let length = vDSP_Length(count)
		let scratch = maskScratch
		let ratio = scratch
		let curve = scratch + count
		let delta = scratch + 2 * count
		let rising = scratch + 3 * count
		let padded = scratch + 4 * count
		power.withUnsafeBufferPointer { powerBuffer in
			smoothedMask.withUnsafeMutableBufferPointer { smoothedBuffer in
				previousMask.withUnsafeMutableBufferPointer { previousBuffer in
					guard let powerBase = powerBuffer.baseAddress, let smoothed = smoothedBuffer.baseAddress,
						let previous = previousBuffer.baseAddress
					else { return }
					// SNR in dB: 10 * log10((power + eps) / (noise + eps)).
					var epsilon: Float = 1e-20
					vDSP_vsadd(powerBase, 1, &epsilon, ratio, 1, length)
					vDSP_vdiv(noiseFloorPower, 1, ratio, 1, ratio, 1, length)
					var n = Int32(count)
					vvlog10f(curve, ratio, &n)
					// x = clamp((10 * log10(ratio) - threshold) / width, 0, 1), then smoothstep x²(3 - 2x).
					var slope = 10 / widthDB
					var offset = -thresholdDB / widthDB
					vDSP_vsmsa(curve, 1, &slope, &offset, curve, 1, length)
					var low: Float = 0
					var high: Float = 1
					vDSP_vclip(curve, 1, &low, &high, curve, 1, length)
					var minusTwo: Float = -2
					var three: Float = 3
					vDSP_vsmsa(curve, 1, &minusTwo, &three, delta, 1, length)
					vDSP_vsq(curve, 1, curve, 1, length)
					// Write the mask into the middle of a zero-padded buffer for the frequency kernel.
					vDSP_vclr(padded, 1, vDSP_Length(count + 4))
					vDSP_vmul(curve, 1, delta, 1, padded + 2, 1, length)
					// Smooth across frequency with a [1 2 3 2 1] kernel, renormalised at the edges.
					Self.frequencyKernel.withUnsafeBufferPointer { kernel in
						guard let kernelBase = kernel.baseAddress else { return }
						vDSP_conv(padded, 1, kernelBase, 1, curve, 1, length, 5)
					}
					vDSP_vdiv(kernelWeights, 1, curve, 1, curve, 1, length)
					// Smooth over time: open fast to keep onsets, close slowly to avoid chatter.
					vDSP_vsub(previous, 1, curve, 1, delta, 1, length)
					var zero: Float = 0
					vDSP_vthres(delta, 1, &zero, rising, 1, length)
					vDSP_vsub(rising, 1, delta, 1, delta, 1, length)
					var open = openCoefficient
					var close = closeCoefficient
					vDSP_vsma(rising, 1, &open, previous, 1, previous, 1, length)
					vDSP_vsma(delta, 1, &close, previous, 1, previous, 1, length)
					// Final gain never drops below the floor.
					var range = 1 - gainFloor
					var floor = gainFloor
					vDSP_vsmsa(previous, 1, &range, &floor, smoothed, 1, length)
				}
			}
		}
	}
}
