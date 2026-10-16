import Foundation

/// What Polish does and how aggressively. Every field has a sensible default; the MCP tool
/// and the Polish popover expose them.
public struct PolishOptions: Codable, Hashable, Sendable {
	public var autoZoom: Bool
	public var cutDeadAir: Bool
	public var speedUpTyping: Bool
	public var trimEnds: Bool
	public var polishCursor: Bool

	/// Largest zoom Polish will choose, 1.2–4.
	public var maxZoom: Double
	/// Events closer than this (seconds) share one zoom and the camera pans between them.
	public var groupGap: Double
	/// Seconds the camera starts moving before the first event of a zoom.
	public var zoomLead: Double
	/// Seconds the camera stays after the last event of a zoom.
	public var zoomHold: Double
	/// Shortest stretch of nothing happening that gets cut, in seconds.
	public var deadAirMinimum: Double
	/// Seconds of padding kept on each side of a dead-air cut.
	public var deadAirPadding: Double
	/// Shortest typing run that gets sped up, in seconds.
	public var typingMinimum: Double
	public var typingSpeed: Double

	public init(
		autoZoom: Bool = true,
		cutDeadAir: Bool = true,
		speedUpTyping: Bool = true,
		trimEnds: Bool = true,
		polishCursor: Bool = true,
		maxZoom: Double = 2.2,
		groupGap: Double = 2.6,
		zoomLead: Double = 0.55,
		zoomHold: Double = 1.6,
		deadAirMinimum: Double = 2.5,
		deadAirPadding: Double = 0.35,
		typingMinimum: Double = 2.2,
		typingSpeed: Double = 2.5
	) {
		self.autoZoom = autoZoom
		self.cutDeadAir = cutDeadAir
		self.speedUpTyping = speedUpTyping
		self.trimEnds = trimEnds
		self.polishCursor = polishCursor
		self.maxZoom = maxZoom
		self.groupGap = groupGap
		self.zoomLead = zoomLead
		self.zoomHold = zoomHold
		self.deadAirMinimum = deadAirMinimum
		self.deadAirPadding = deadAirPadding
		self.typingMinimum = typingMinimum
		self.typingSpeed = typingSpeed
	}
}

/// Measurements Polish uses besides the input track. Each is optional; missing signals are
/// treated as "unknown" (never as "nothing happening"), so Polish errs on keeping footage.
public struct PolishSignals: Sendable {
	/// How much the picture changes over time (0 = static).
	public var frameActivity: ActivitySeries?
	/// When someone is speaking (microphone), in source seconds.
	public var speech: [TimeRange]?

	public init(frameActivity: ActivitySeries? = nil, speech: [TimeRange]? = nil) {
		self.frameActivity = frameActivity
		self.speech = speech
	}
}

/// Evenly spaced measurements over the source timeline.
public struct ActivitySeries: Codable, Hashable, Sendable {
	public var interval: Double
	public var values: [Float]

	public init(interval: Double, values: [Float]) {
		self.interval = interval
		self.values = values
	}

	/// Ranges where the value stays above `threshold`.
	public func ranges(above threshold: Float) -> [TimeRange] {
		var ranges: [TimeRange] = []
		var start: Double?
		for (i, value) in values.enumerated() {
			let t = Double(i) * interval
			if value > threshold {
				if start == nil { start = t }
			} else if let s = start {
				ranges.append(TimeRange(start: s, end: t))
				start = nil
			}
		}
		if let s = start { ranges.append(TimeRange(start: s, end: Double(values.count) * interval)) }
		return ranges
	}
}

import NebulaCore
