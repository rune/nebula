import Foundation

/// A point in normalized video coordinates: (0, 0) is the top-left of the recorded frame, (1, 1) the bottom-right.
public struct NormPoint: Codable, Hashable, Sendable {
	public var x: Double
	public var y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}

	public static let center = NormPoint(x: 0.5, y: 0.5)

	public func clamped() -> NormPoint {
		NormPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
	}

	public func distance(to other: NormPoint) -> Double {
		hypot(x - other.x, y - other.y)
	}
}

/// A rectangle in normalized video coordinates (origin top-left).
public struct NormRect: Codable, Hashable, Sendable {
	public var x: Double
	public var y: Double
	public var width: Double
	public var height: Double

	public init(x: Double, y: Double, width: Double, height: Double) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}

	public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)

	public var center: NormPoint { NormPoint(x: x + width / 2, y: y + height / 2) }
	public var maxX: Double { x + width }
	public var maxY: Double { y + height }

	public func contains(_ point: NormPoint) -> Bool {
		point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
	}

	public func union(_ other: NormRect) -> NormRect {
		let minX = min(x, other.x)
		let minY = min(y, other.y)
		return NormRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
	}

	public func insetBy(_ dx: Double, _ dy: Double) -> NormRect {
		NormRect(x: x + dx, y: y + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
	}

	/// Clamps the rect inside the unit square, shrinking it if needed.
	public func clamped() -> NormRect {
		let w = width.clamped(to: 0...1)
		let h = height.clamped(to: 0...1)
		return NormRect(x: x.clamped(to: 0...(1 - w)), y: y.clamped(to: 0...(1 - h)), width: w, height: h)
	}

	public static func around(_ points: [NormPoint]) -> NormRect? {
		guard let first = points.first else { return nil }
		var rect = NormRect(x: first.x, y: first.y, width: 0, height: 0)
		for point in points.dropFirst() {
			rect = rect.union(NormRect(x: point.x, y: point.y, width: 0, height: 0))
		}
		return rect
	}
}

/// A half-open time range in seconds, [start, end).
public struct TimeRange: Codable, Hashable, Sendable {
	public var start: Double
	public var end: Double

	public init(start: Double, end: Double) {
		self.start = start
		self.end = end
	}

	public var duration: Double { max(0, end - start) }
	public var isEmpty: Bool { end <= start }

	public func contains(_ time: Double) -> Bool { time >= start && time < end }

	public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

	public func intersection(_ other: TimeRange) -> TimeRange? {
		let range = TimeRange(start: max(start, other.start), end: min(end, other.end))
		return range.isEmpty ? nil : range
	}

	public func clamped(to bounds: TimeRange) -> TimeRange {
		TimeRange(start: start.clamped(to: bounds.start...bounds.end), end: end.clamped(to: bounds.start...bounds.end))
	}

	/// Merges overlapping or touching ranges.
	public static func merge(_ ranges: [TimeRange]) -> [TimeRange] {
		var merged: [TimeRange] = []
		for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.start < $1.start }) {
			if let last = merged.last, range.start <= last.end {
				merged[merged.count - 1].end = max(last.end, range.end)
			} else {
				merged.append(range)
			}
		}
		return merged
	}

	/// Parts of `ranges` that overlap every list in `others` (set intersection).
	public static func intersect(_ a: [TimeRange], _ b: [TimeRange]) -> [TimeRange] {
		var result: [TimeRange] = []
		for x in merge(a) {
			for y in merge(b) {
				if let both = x.intersection(y) { result.append(both) }
			}
		}
		return merge(result)
	}

	/// `from` minus every range in `remove`.
	public static func subtract(_ from: [TimeRange], _ remove: [TimeRange]) -> [TimeRange] {
		var result = merge(from)
		for cut in merge(remove) {
			result = result.flatMap { range -> [TimeRange] in
				guard range.overlaps(cut) else { return [range] }
				var pieces: [TimeRange] = []
				if cut.start > range.start { pieces.append(TimeRange(start: range.start, end: cut.start)) }
				if cut.end < range.end { pieces.append(TimeRange(start: cut.end, end: range.end)) }
				return pieces
			}
		}
		return result
	}
}

extension Comparable {
	public func clamped(to range: ClosedRange<Self>) -> Self {
		min(max(self, range.lowerBound), range.upperBound)
	}
}
