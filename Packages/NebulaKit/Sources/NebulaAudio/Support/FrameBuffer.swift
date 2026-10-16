/// Buffers a stream of samples and hands out overlapping frames of `size` samples every `hop` samples.
struct FrameBuffer {
	let size: Int
	let hop: Int
	private var buffer: [Float]
	private var readIndex = 0

	/// - Parameter leadingZeros: zeros to place before the first sample (for full overlap-add coverage).
	init(size: Int, hop: Int, leadingZeros: Int = 0) {
		self.size = size
		self.hop = hop
		self.buffer = [Float](repeating: 0, count: leadingZeros)
		buffer.reserveCapacity(size * 8)
	}

	mutating func append(_ samples: [Float]) {
		if readIndex > size * 4 {
			buffer.removeFirst(readIndex)
			readIndex = 0
		}
		buffer.append(contentsOf: samples)
	}

	/// Appends `count` zeros (trailing padding at the end of the stream).
	mutating func appendZeros(_ count: Int) {
		append([Float](repeating: 0, count: count))
	}

	/// Copies the next frame into `frame` and advances by `hop`. Returns `false` when not enough samples are buffered.
	mutating func nextFrame(into frame: inout [Float]) -> Bool {
		guard buffer.count - readIndex >= size else { return false }
		frame.withUnsafeMutableBufferPointer { destination in
			buffer.withUnsafeBufferPointer { source in
				guard let dst = destination.baseAddress, let src = source.baseAddress else { return }
				dst.update(from: src + readIndex, count: size)
			}
		}
		readIndex += hop
		return true
	}
}
