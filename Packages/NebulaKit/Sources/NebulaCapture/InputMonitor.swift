import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import NebulaCore
import os

/// Records cursor, clicks, scrolls, keys and the focused text field while recording.
///
/// Typed characters are never stored: plain typing is a `.typing` event and only shortcut
/// presses keep keycap labels. Times share the host clock with the video samples.
final class InputMonitor: @unchecked Sendable {
	private let lock = OSAllocatedUnfairLock()
	private let captureRect: CaptureRect
	private let scale: Double

	// Guarded by `lock`.
	private var track: InputTrack
	private var startUptime: Double?
	private var pausedAt: Double?
	private var pausedTotal: Double = 0
	private var currentShape = 0
	private var lastPoint: CGPoint?
	private var lastSampleUptime: Double = 0
	private var lastFocusQuery: Double = 0

	// Main thread only.
	private var monitors: [Any] = []
	private var shapeTimer: Timer?
	private var shapeIndex: [String: Int] = [:]
	private var knownShapes: [String: CursorShape.Kind] = [:]
	private var pollTimer: DispatchSourceTimer?
	private let focusQueue = DispatchQueue(label: "app.nebula.capture.focus", qos: .utility)

	init(captureRect: CGRect, scale: Double) {
		self.captureRect = CaptureRect(x: captureRect.minX, y: captureRect.minY, width: captureRect.width, height: captureRect.height)
		self.scale = scale
		self.track = InputTrack(captureRect: self.captureRect, scale: scale, cursorShapes: [CursorShape(kind: .arrow)])
	}

	/// Called with the host-clock time of the first video frame.
	func setStart(uptime: Double) {
		lock.withLockUnchecked { if startUptime == nil { startUptime = uptime } }
	}

	/// Recording-relative time for an uptime, or nil before the first frame / while paused.
	private func time(_ uptime: Double) -> Double? {
		guard let startUptime, pausedAt == nil else { return nil }
		let t = uptime - startUptime - pausedTotal
		return t >= 0 ? t : nil
	}

	// MARK: Lifecycle

	@MainActor
	func start() {
		knownShapes = Self.systemCursorSignatures()
		installEventMonitors()
		let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.sampleCursorShape() }
		}
		RunLoop.main.add(timer, forMode: .common)
		shapeTimer = timer

		let poll = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.nebula.capture.cursor", qos: .userInteractive))
		poll.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
		// @Sendable: a closure written in a @MainActor method is otherwise main-actor isolated,
		// and Swift 6 traps when it runs on this queue.
		poll.setEventHandler { @Sendable [weak self] in self?.sampleCursorPosition() }
		poll.resume()
		pollTimer = poll
	}

	@MainActor
	func pause() {
		lock.withLockUnchecked { pausedAt = ProcessInfo.processInfo.systemUptime }
	}

	@MainActor
	func resume() {
		lock.withLockUnchecked {
			if let pausedAt { pausedTotal += ProcessInfo.processInfo.systemUptime - pausedAt }
			pausedAt = nil
		}
	}

	@MainActor
	func stop() -> InputTrack {
		pollTimer?.cancel()
		pollTimer = nil
		shapeTimer?.invalidate()
		shapeTimer = nil
		monitors.forEach(NSEvent.removeMonitor)
		monitors.removeAll()
		return lock.withLockUnchecked { track }
	}

	// MARK: Cursor

	private func sampleCursorPosition() {
		guard let location = CGEvent(source: nil)?.location else { return }
		let now = ProcessInfo.processInfo.systemUptime
		lock.withLockUnchecked {
			guard let t = time(now) else { return }
			let moved = lastPoint.map { hypot($0.x - location.x, $0.y - location.y) >= 0.25 } ?? true
			// Only store movement, plus a heartbeat once a second.
			guard moved || now - lastSampleUptime >= 1 else { return }
			lastPoint = location
			lastSampleUptime = now
			let point = captureRect.normalize(x: location.x, y: location.y)
			track.cursor.append(CursorSample(t: t, x: point.x, y: point.y, shape: currentShape))
		}
	}

	@MainActor
	private func sampleCursorShape() {
		let cursor = NSCursor.currentSystem ?? NSCursor.arrow
		let signature = Self.signature(cursor)
		let index: Int
		if let known = shapeIndex[signature] {
			index = known
		} else {
			let kind = knownShapes[signature] ?? .other
			let size = cursor.image.size
			var png: Data?
			if kind == .other, let tiff = cursor.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
				png = rep.representation(using: .png, properties: [:])
			}
			let shape = CursorShape(kind: kind, hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y, width: size.width, height: size.height, png: png)
			index = lock.withLockUnchecked {
				if kind == .arrow { return 0 }
				track.cursorShapes.append(shape)
				return track.cursorShapes.count - 1
			}
			shapeIndex[signature] = index
		}
		lock.withLockUnchecked { currentShape = index }
	}

	@MainActor
	static func signature(_ cursor: NSCursor) -> String {
		let size = cursor.image.size
		return "\(Int(size.width))x\(Int(size.height))@\(Int(cursor.hotSpot.x)),\(Int(cursor.hotSpot.y))"
	}

	@MainActor
	static func systemCursorSignatures() -> [String: CursorShape.Kind] {
		let known: [(NSCursor, CursorShape.Kind)] = [
			(.arrow, .arrow), (.pointingHand, .pointer), (.iBeam, .iBeam), (.crosshair, .crosshair),
			(.openHand, .openHand), (.closedHand, .closedHand), (.resizeLeftRight, .resizeLeftRight),
			(.resizeUpDown, .resizeUpDown), (.operationNotAllowed, .notAllowed),
		]
		var signatures: [String: CursorShape.Kind] = [:]
		for (cursor, kind) in known where signatures[signature(cursor)] == nil {
			signatures[signature(cursor)] = kind
		}
		return signatures
	}

	// MARK: Events

	@MainActor
	private func installEventMonitors() {
		let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel]
		if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] event in self?.handleMouse(event) }) {
			monitors.append(monitor)
		}
		if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in self?.handleKey(event) }) {
			monitors.append(monitor)
		}
	}

	private func handleMouse(_ event: NSEvent) {
		guard let location = event.cgEvent?.location else { return }
		let uptime = event.timestamp
		lock.withLockUnchecked {
			guard let t = time(uptime) else { return }
			let point = captureRect.normalize(x: location.x, y: location.y)
			switch event.type {
			case .leftMouseDown, .rightMouseDown, .otherMouseDown:
				let button: ClickEvent.Button = event.type == .leftMouseDown ? .left : event.type == .rightMouseDown ? .right : .other
				track.clicks.append(ClickEvent(t: t, x: point.x, y: point.y, button: button))
				track.cursor.append(CursorSample(t: t, x: point.x, y: point.y, shape: currentShape))
			case .leftMouseUp:
				if let index = track.clicks.lastIndex(where: { $0.upT == nil && $0.button == .left }) {
					track.clicks[index].upT = t
				}
			case .scrollWheel where abs(event.scrollingDeltaY) > 0.5:
				track.scrolls.append(ScrollEvent(t: t, x: point.x, y: point.y, dy: Double(event.scrollingDeltaY)))
			default:
				break
			}
		}
	}

	private func handleKey(_ event: NSEvent) {
		let uptime = event.timestamp
		let labels = Self.shortcutLabels(for: event)
		lock.withLockUnchecked {
			guard let t = time(uptime) else { return }
			track.keys.append(KeyEvent(t: t, kind: labels == nil ? .typing : .shortcut, keys: labels ?? []))
		}
		if labels == nil { queryFocusIfNeeded(uptime: uptime) }
	}

	/// Keycap labels when the press is a shortcut (has ⌘/⌃/⌥ or is a non-text key), nil for typing.
	static func shortcutLabels(for event: NSEvent) -> [String]? {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		let special: [Int: String] = [
			kVK_Escape: "esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
			kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
			kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
			kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Space: "Space", kVK_ForwardDelete: "⌦",
		]
		let hasCommandish = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
		let isSpecial = [kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].contains(Int(event.keyCode))
		guard hasCommandish || isSpecial else { return nil }
		var labels: [String] = []
		if flags.contains(.control) { labels.append("⌃") }
		if flags.contains(.option) { labels.append("⌥") }
		if flags.contains(.shift) { labels.append("⇧") }
		if flags.contains(.command) { labels.append("⌘") }
		if let name = special[Int(event.keyCode)] {
			labels.append(name)
		} else if let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty {
			labels.append(characters)
		}
		return labels
	}

	/// Reads the focused text field's frame via Accessibility (at most twice a second).
	private func queryFocusIfNeeded(uptime: Double) {
		let shouldQuery = lock.withLockUnchecked { () -> Bool in
			guard uptime - lastFocusQuery > 0.5 else { return false }
			lastFocusQuery = uptime
			return true
		}
		guard shouldQuery, AXIsProcessTrusted() else { return }
		focusQueue.async { [weak self] in
			guard let self else { return }
			let rect = Self.focusedElementFrame()
			self.lock.withLockUnchecked {
				guard let t = self.time(uptime) else { return }
				let normalized = rect.map { self.captureRect.normalize(CaptureRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)) }
				// Ignore huge "fields" (whole documents, web views): they aren't useful zoom targets.
				let useful = normalized.flatMap { $0.width < 0.9 && $0.height < 0.6 && $0.width > 0.01 ? $0 : nil }
				if self.track.focus.last?.rect != useful {
					self.track.focus.append(FocusEvent(t: t, rect: useful))
				}
			}
		}
	}

	static func focusedElementFrame() -> CGRect? {
		let system = AXUIElementCreateSystemWide()
		var focused: CFTypeRef?
		guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
			let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
		let axElement = element as! AXUIElement
		var positionValue: CFTypeRef?
		var sizeValue: CFTypeRef?
		guard AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue) == .success,
			AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
			let positionRef = positionValue, let sizeRef = sizeValue else { return nil }
		var position = CGPoint.zero
		var size = CGSize.zero
		AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
		AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
		return CGRect(origin: position, size: size)
	}
}
