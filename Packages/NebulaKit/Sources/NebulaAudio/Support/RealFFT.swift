import Accelerate

/// In-place real FFT of a power-of-two size, in vDSP's packed split-complex format.
///
/// After `forward`, `real[0]` holds the DC term and `imag[0]` the Nyquist term; bins `1..<size/2`
/// are `(real[k], imag[k])`. Values are scaled by 2 relative to the mathematical DFT, and
/// `inverse` scales by `size`, so a round trip multiplies the signal by `2 * size`.
final class RealFFT {
	let size: Int
	let halfSize: Int
	private let log2n: vDSP_Length
	private let setup: FFTSetup

	init?(size: Int) {
		guard size >= 4, size & (size - 1) == 0 else { return nil }
		let log2n = vDSP_Length(size.trailingZeroBitCount)
		guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
		self.size = size
		self.halfSize = size / 2
		self.log2n = log2n
		self.setup = setup
	}

	deinit {
		vDSP_destroy_fftsetup(setup)
	}

	/// Transforms `input` (`size` real samples) into `real` and `imag` (`size / 2` values each).
	func forward(_ input: [Float], real: inout [Float], imag: inout [Float]) {
		let half = halfSize
		input.withUnsafeBufferPointer { source in
			real.withUnsafeMutableBufferPointer { realBuffer in
				imag.withUnsafeMutableBufferPointer { imagBuffer in
					guard let src = source.baseAddress, let rp = realBuffer.baseAddress, let ip = imagBuffer.baseAddress else { return }
					var split = DSPSplitComplex(realp: rp, imagp: ip)
					src.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
						vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
					}
					vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
				}
			}
		}
	}

	/// Transforms packed `real` / `imag` back into `output` (`size` real samples, unnormalised).
	func inverse(real: inout [Float], imag: inout [Float], output: inout [Float]) {
		let half = halfSize
		real.withUnsafeMutableBufferPointer { realBuffer in
			imag.withUnsafeMutableBufferPointer { imagBuffer in
				output.withUnsafeMutableBufferPointer { destination in
					guard let rp = realBuffer.baseAddress, let ip = imagBuffer.baseAddress, let dst = destination.baseAddress else { return }
					var split = DSPSplitComplex(realp: rp, imagp: ip)
					vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
					dst.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
						vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(half))
					}
				}
			}
		}
	}

	/// Power per bin (`size / 2 + 1` values, DC to Nyquist) of a packed spectrum.
	func power(real: [Float], imag: [Float], into power: inout [Float]) {
		let half = halfSize
		real.withUnsafeBufferPointer { realBuffer in
			imag.withUnsafeBufferPointer { imagBuffer in
				power.withUnsafeMutableBufferPointer { destination in
					guard let rp = realBuffer.baseAddress, let ip = imagBuffer.baseAddress, let dst = destination.baseAddress else { return }
					var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp), imagp: UnsafeMutablePointer(mutating: ip))
					vDSP_zvmags(&split, 1, dst, 1, vDSP_Length(half))
					dst[0] = rp[0] * rp[0]
					dst[half] = ip[0] * ip[0]
				}
			}
		}
	}
}
