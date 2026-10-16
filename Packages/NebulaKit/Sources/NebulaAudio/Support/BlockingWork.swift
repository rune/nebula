import Dispatch

/// Runs blocking work (AVFoundation decoding and encoding) on a dispatch queue instead of the
/// Swift concurrency pool.
///
/// `AVAssetReader.copyNextSampleBuffer()` blocks its thread while the decoder runs. Doing that on
/// the cooperative pool can starve it (and was seen to deadlock when many reads ran at once), so
/// all decode loops go through here. Task cancellation is forwarded through `CancellationFlag`.
enum BlockingWork {
	private static let queue = DispatchQueue(
		label: "app.nebula.audio.work", qos: .userInitiated, attributes: .concurrent
	)

	static func run<T: Sendable>(_ work: @escaping @Sendable (CancellationFlag) throws -> T) async throws -> T {
		let flag = CancellationFlag()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
				queue.async {
					continuation.resume(with: Result { try work(flag) })
				}
			}
		} onCancel: {
			flag.cancel()
		}
	}
}
