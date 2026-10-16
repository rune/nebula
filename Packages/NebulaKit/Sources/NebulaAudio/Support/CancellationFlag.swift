import Synchronization

/// A thread-safe cancellation flag for work running outside the task that started it.
final class CancellationFlag: Sendable {
	private let state = Atomic<Bool>(false)

	var isCancelled: Bool { state.load(ordering: .relaxed) }

	func cancel() {
		state.store(true, ordering: .relaxed)
	}

	/// Throws `CancellationError` once cancelled.
	func check() throws {
		if isCancelled { throw CancellationError() }
	}
}
