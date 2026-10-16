import Foundation
import NebulaCore

/// Snapshot-based undo history. Projects are value types, so a snapshot is cheap and an undo is
/// exact. Consecutive edits with the same `coalescingKey` (e.g. one slider drag) merge into one step.
struct EditHistory {
	struct Entry {
		var project: Project
		var label: String
		var coalescingKey: String?
		var date: Date
	}

	private(set) var past: [Entry] = []
	private(set) var future: [Entry] = []
	private let limit = 150

	var canUndo: Bool { !past.isEmpty }
	var canRedo: Bool { !future.isEmpty }
	var undoLabel: String? { past.last?.label }
	var redoLabel: String? { future.first?.label }

	/// Records `previous` as the state to return to, unless this edit continues the last one.
	mutating func record(previous: Project, label: String, coalescingKey: String?) {
		let now = Date()
		if let key = coalescingKey, let last = past.last, last.coalescingKey == key, now.timeIntervalSince(last.date) < 1.2 {
			past[past.count - 1].date = now
		} else {
			past.append(Entry(project: previous, label: label, coalescingKey: coalescingKey, date: now))
			if past.count > limit { past.removeFirst(past.count - limit) }
		}
		future.removeAll()
	}

	mutating func undo(current: Project) -> Entry? {
		guard let entry = past.popLast() else { return nil }
		future.insert(Entry(project: current, label: entry.label, coalescingKey: nil, date: Date()), at: 0)
		return entry
	}

	mutating func redo(current: Project) -> Entry? {
		guard !future.isEmpty else { return nil }
		let entry = future.removeFirst()
		past.append(Entry(project: current, label: entry.label, coalescingKey: nil, date: Date()))
		return entry
	}
}
