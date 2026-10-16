import Foundation
import os

/// A small thread-safe cache with least-recently-inserted eviction, shared by artwork renderers.
final class RenderCache<Key: Hashable & Sendable, Value>: @unchecked Sendable {
	private let lock = OSAllocatedUnfairLock()
	private var storage: [Key: Value] = [:]
	private var order: [Key] = []
	private let limit: Int

	init(limit: Int) {
		self.limit = limit
	}

	func value(for key: Key, make: () -> Value?) -> Value? {
		lock.lock()
		if let cached = storage[key] {
			lock.unlock()
			return cached
		}
		lock.unlock()
		guard let value = make() else { return nil }
		lock.lock()
		defer { lock.unlock() }
		if storage[key] == nil {
			order.append(key)
			if order.count > limit {
				storage.removeValue(forKey: order.removeFirst())
			}
		}
		storage[key] = value
		return value
	}

	func removeAll() {
		lock.lock()
		storage.removeAll()
		order.removeAll()
		lock.unlock()
	}
}
