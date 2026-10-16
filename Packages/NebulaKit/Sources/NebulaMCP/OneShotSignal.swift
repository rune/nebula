import Foundation
import os

/// A value that is set once and can be waited for synchronously.
///
/// Used to turn the asynchronous listener state callbacks into blocking `start` and `stop` calls.
final class OneShotSignal<Value: Sendable>: Sendable {
	private let semaphore = DispatchSemaphore(value: 0)
	private let value = OSAllocatedUnfairLock<Value?>(initialState: nil)

	/// Records `newValue` if nothing has been recorded yet. Returns whether this call recorded it.
	@discardableResult
	func resolve(_ newValue: Value) -> Bool {
		let didResolve = value.withLock { current in
			guard current == nil else { return false }
			current = newValue
			return true
		}
		if didResolve {
			semaphore.signal()
		}
		return didResolve
	}

	/// Waits up to `timeout` for the value. Returns `nil` on timeout.
	///
	/// Must not be called on the queue that resolves the signal.
	func wait(timeout: DispatchTimeInterval) -> Value? {
		guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
		// Let other waiters through as well.
		semaphore.signal()
		return value.withLock { $0 }
	}
}
