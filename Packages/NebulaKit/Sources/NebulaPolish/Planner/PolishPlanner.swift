import Foundation
import NebulaCore
import os

/// Turns a recording's input track and signals into editable timeline items: smart zooms,
/// dead-air cuts, typing speed-ups. Pure and deterministic.
public enum PolishPlanner {
	public struct Plan: Sendable, Equatable {
		public var zooms: [ZoomItem]
		public var cuts: [CutItem]
		public var speeds: [SpeedItem]

		public var summary: String {
			var parts: [String] = []
			if !zooms.isEmpty { parts.append("\(zooms.count) zoom\(zooms.count == 1 ? "" : "s")") }
			if !cuts.isEmpty { parts.append("\(cuts.count) cut\(cuts.count == 1 ? "" : "s")") }
			if !speeds.isEmpty { parts.append("\(speeds.count) speed-up\(speeds.count == 1 ? "" : "s")") }
			return parts.isEmpty ? "nothing to change" : parts.joined(separator: ", ")
		}
	}

	private static let logger = Logger(subsystem: "app.nebula", category: "polish")

	public static func plan(project: Project, input: InputTrack, signals: PolishSignals, options: PolishOptions) -> Plan {
		let duration = project.media.duration
		guard duration > 0 else { return Plan(zooms: [], cuts: [], speeds: []) }
		let userCuts = project.cuts.filter { $0.source != .polish }.map(\.range)

		let cuts = options.cutDeadAir || options.trimEnds
			? planCuts(input: input, signals: signals, duration: duration, options: options, existing: userCuts)
			: []
		let allCuts = TimeRange.merge(userCuts + cuts.map(\.range))
		let speeds = options.speedUpTyping
			? planTypingSpeedUps(input: input, signals: signals, options: options, cuts: allCuts, existing: project.speeds.filter { $0.source != .polish })
			: []
		let zooms = options.autoZoom
			? planZooms(input: input, duration: duration, options: options, cuts: allCuts, userZooms: project.zooms.filter { $0.source != .polish })
			: []
		logger.info("Polish planned \(zooms.count) zooms, \(cuts.count) cuts, \(speeds.count) speed-ups")
		return Plan(zooms: zooms, cuts: cuts, speeds: speeds)
	}

	/// Replaces earlier Polish items (of the enabled kinds) with the plan. User items stay.
	public static func apply(_ plan: Plan, to project: inout Project, options: PolishOptions) {
		if options.autoZoom {
			project.zooms.removeAll { $0.source == .polish }
			project.zooms += plan.zooms
			project.zooms.sort { $0.range.start < $1.range.start }
		}
		if options.cutDeadAir || options.trimEnds {
			project.cuts.removeAll { $0.source == .polish }
			project.cuts += plan.cuts
			project.cuts.sort { $0.range.start < $1.range.start }
		}
		if options.speedUpTyping {
			project.speeds.removeAll { $0.source == .polish }
			project.speeds += plan.speeds
			project.speeds.sort { $0.range.start < $1.range.start }
		}
		if options.polishCursor {
			project.cursor.visible = true
			project.cursor.smoothing = max(project.cursor.smoothing, 0.55)
			project.cursor.hideWhenIdle = true
			if project.cursor.clickEffect == .none { project.cursor.clickEffect = .ripple }
		}
	}

	// MARK: - Activity

	/// Times where something happens on screen, in the audio or with the input devices.
	static func activeRanges(input: InputTrack, signals: PolishSignals, duration: Double) -> [TimeRange] {
		var active: [TimeRange] = []
		let samples = input.cursor.sorted { $0.t < $1.t }
		for (a, b) in zip(samples, samples.dropFirst()) where a.point.distance(to: b.point) > 0.0015 {
			// Samples are only written when the cursor moves, so a long gap means it sat still
			// until just before `b`.
			let start = b.t - a.t > 0.25 ? b.t - 0.3 : a.t - 0.3
			active.append(TimeRange(start: start, end: b.t + 0.3))
		}
		active += input.clicks.map { TimeRange(start: $0.t - 0.6, end: ($0.upT ?? $0.t) + 0.8) }
		active += input.keys.map { TimeRange(start: $0.t - 0.4, end: $0.t + 0.6) }
		active += input.scrolls.map { TimeRange(start: $0.t - 0.4, end: $0.t + 0.8) }
		if let speech = signals.speech {
			active += speech.map { TimeRange(start: $0.start - 0.3, end: $0.end + 0.4) }
		}
		if let activity = signals.frameActivity {
			active += activity.ranges(above: 0.012).map { TimeRange(start: $0.start - 0.2, end: $0.end + 0.3) }
		} else {
			// Without a picture signal we can't know the screen is static, so only trust
			// stretches the input track says are idle *and* that are long.
		}
		return TimeRange.merge(active.compactMap { $0.intersection(TimeRange(start: 0, end: duration)) })
	}

	static func planCuts(input: InputTrack, signals: PolishSignals, duration: Double, options: PolishOptions, existing: [TimeRange]) -> [CutItem] {
		let whole = TimeRange(start: 0, end: duration)
		let active = activeRanges(input: input, signals: signals, duration: duration)
		var cuts: [TimeRange] = []

		if options.trimEnds, let first = active.first {
			if first.start > 0.4 { cuts.append(TimeRange(start: 0, end: max(0, first.start - 0.15))) }
		}
		if options.trimEnds, let last = active.last, duration - last.end > 0.8 {
			cuts.append(TimeRange(start: last.end + 0.25, end: duration))
		}
		if options.cutDeadAir {
			// Without a frame-activity signal, demand a longer stillness before cutting.
			let minimum = signals.frameActivity == nil ? max(options.deadAirMinimum, 4) : options.deadAirMinimum
			let idle = TimeRange.subtract([whole], active)
			for gap in idle where gap.duration >= minimum && gap.start > 0 && gap.end < duration {
				let padded = TimeRange(start: gap.start + options.deadAirPadding, end: gap.end - options.deadAirPadding)
				if padded.duration >= 0.6 { cuts.append(padded) }
			}
		}
		let fresh = TimeRange.subtract(TimeRange.merge(cuts), existing)
		return fresh.filter { $0.duration >= 0.3 }.map { CutItem(range: $0, source: .polish) }
	}

	// MARK: - Typing

	static func typingBursts(input: InputTrack, maxGap: Double) -> [TimeRange] {
		let typing = input.keys.filter { $0.kind == .typing }.map(\.t).sorted()
		var bursts: [TimeRange] = []
		for t in typing {
			if let last = bursts.last, t - last.end <= maxGap {
				bursts[bursts.count - 1].end = t
			} else {
				bursts.append(TimeRange(start: t, end: t))
			}
		}
		return bursts.map { TimeRange(start: $0.start, end: $0.end + 0.25) }
	}

	static func planTypingSpeedUps(input: InputTrack, signals: PolishSignals, options: PolishOptions, cuts: [TimeRange], existing: [SpeedItem]) -> [SpeedItem] {
		let speech = signals.speech ?? []
		var items: [SpeedItem] = []
		for burst in typingBursts(input: input, maxGap: 1.1) where burst.duration >= options.typingMinimum {
			// Talking over typing would turn into chipmunk audio, so leave those alone.
			let talking = speech.compactMap { $0.intersection(burst) }.reduce(0) { $0 + $1.duration }
			guard talking < burst.duration * 0.25 else { continue }
			let rate = burst.duration > 6 ? options.typingSpeed * 1.4 : options.typingSpeed
			for piece in TimeRange.subtract([burst], cuts + existing.map(\.range)) where piece.duration >= 1 {
				items.append(SpeedItem(range: piece, rate: rate.clamped(to: 1.25...8), source: .polish))
			}
		}
		return items
	}

	// MARK: - Zooms

	struct Interest {
		var range: TimeRange
		var rect: NormRect
		var isTyping: Bool
	}

	static func interests(input: InputTrack, cuts: [TimeRange]) -> [Interest] {
		var events: [Interest] = []
		for click in input.clicks where click.button != .other {
			guard !cuts.contains(where: { $0.contains(click.t) }) else { continue }
			events.append(Interest(range: TimeRange(start: click.t, end: click.upT ?? click.t), rect: NormRect(x: click.x, y: click.y, width: 0, height: 0), isTyping: false))
		}
		let focus = input.focus.sorted { $0.t < $1.t }
		let cursor = input.cursor.sorted { $0.t < $1.t }
		for burst in typingBursts(input: input, maxGap: 1.2) where burst.duration >= 0.8 {
			guard !cuts.contains(where: { $0.contains(burst.start) }) else { continue }
			let field = focus.last { $0.t <= burst.start + 0.3 }?.rect
			let caret = cursor.last { $0.t <= burst.start }?.point ?? .center
			let rect = field.map { $0.clamped() } ?? NormRect(x: caret.x - 0.12, y: caret.y - 0.04, width: 0.24, height: 0.08).clamped()
			events.append(Interest(range: burst, rect: rect, isTyping: true))
		}
		return events.sorted { $0.range.start < $1.range.start }
	}

	static func planZooms(input: InputTrack, duration: Double, options: PolishOptions, cuts: [TimeRange], userZooms: [ZoomItem]) -> [ZoomItem] {
		let events = interests(input: input, cuts: cuts)
		guard !events.isEmpty else { return [] }
		let maxSpan = 0.62

		// 1. Group events that are close in time and fit in one view. Typing only groups with
		//    clicks on (or right next to) the field being typed into, so it stays tightly framed.
		func compatible(_ a: Interest, _ b: Interest) -> Bool {
			guard a.isTyping || b.isTyping else { return true }
			if a.isTyping && b.isTyping { return a.rect.center.distance(to: b.rect.center) < 0.1 }
			let field = a.isTyping ? a.rect : b.rect
			let other = a.isTyping ? b.rect.center : a.rect.center
			return field.insetBy(-0.08, -0.08).contains(other)
		}
		var groups: [[Interest]] = []
		for event in events {
			if var group = groups.last,
				let last = group.last,
				event.range.start - last.range.end <= options.groupGap,
				group.allSatisfy({ compatible($0, event) }) {
				let bounds = group.reduce(event.rect) { $0.union($1.rect) }
				if bounds.width <= maxSpan, bounds.height <= maxSpan {
					group.append(event)
					groups[groups.count - 1] = group
					continue
				}
			}
			groups.append([event])
		}

		// 2. One zoom per group, framed around everything in it.
		var zooms: [ZoomItem] = []
		for group in groups {
			guard let first = group.first, let last = group.last else { continue }
			var bounds = group.dropFirst().reduce(first.rect) { $0.union($1.rect) }
			let padX = max(0.09, (0.18 - bounds.width) / 2)
			let padY = max(0.09, (0.18 - bounds.height) / 2)
			bounds = NormRect(x: bounds.x - padX, y: bounds.y - padY, width: bounds.width + 2 * padX, height: bounds.height + 2 * padY)
			let fitScale = 0.95 / max(bounds.width, bounds.height)
			let scale = fitScale.clamped(to: 1.35...max(1.35, options.maxZoom))
			let start = max(0, first.range.start - options.zoomLead)
			var end = min(duration, last.range.end + options.zoomHold)
			if end - start < 1.4 { end = min(duration, start + 1.4) }
			let distinctSpots = Set(group.map { "\(Int($0.rect.center.x * 20))-\(Int($0.rect.center.y * 20))" }).count
			let target: ZoomItem.Target
			if group.count == 1, first.isTyping {
				target = .rect(bounds)
			} else if distinctSpots > 1 && max(bounds.width, bounds.height) > 1 / scale * 0.8 {
				target = .follow
			} else {
				target = .point(bounds.center.clamped())
			}
			zooms.append(ZoomItem(range: TimeRange(start: start, end: end), target: target, scale: (scale * 100).rounded() / 100, source: .polish))
		}

		// 3. Zooms that would zoom out and straight back in instead sit back to back, so the
		//    camera glides from one target to the next without pulling out. Zooms on the same
		//    spot merge.
		var joined: [ZoomItem] = []
		for zoom in zooms {
			guard var previous = joined.last, zoom.range.start - previous.range.end < 0.9 else {
				joined.append(zoom)
				continue
			}
			if case .point(let a) = previous.target, case .point(let b) = zoom.target, a.distance(to: b) < 0.08 {
				previous.range.end = max(previous.range.end, zoom.range.end)
				previous.scale = min(previous.scale, zoom.scale)
				joined[joined.count - 1] = previous
				continue
			}
			var next = zoom
			let boundary = previous.range.end > next.range.start
				? (previous.range.end + next.range.start) / 2
				: next.range.start
			previous.range.end = boundary
			next.range.start = boundary
			joined[joined.count - 1] = previous
			joined.append(next)
		}

		// 4. Keep clear of the user's own zooms and of footage that's cut anyway.
		return joined.compactMap { zoom in
			var zoom = zoom
			let free = TimeRange.subtract([zoom.range], userZooms.map(\.range))
			guard let longest = free.max(by: { $0.duration < $1.duration }), longest.duration >= 1 else { return nil }
			zoom.range = longest
			let cutPart = cuts.compactMap { $0.intersection(zoom.range) }.reduce(0) { $0 + $1.duration }
			return cutPart > zoom.range.duration * 0.7 ? nil : zoom
		}
	}
}
