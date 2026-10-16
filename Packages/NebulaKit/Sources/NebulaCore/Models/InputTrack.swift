import Foundation

/// Everything recorded alongside the pixels: cursor, clicks, keys and focus. Positions are
/// normalized to the recorded frame, times are seconds of the recording (pauses already removed).
public struct InputTrack: Codable, Hashable, Sendable {
	public var formatVersion: Int
	/// Recorded area in global screen points (origin top-left of the main display).
	public var captureRect: CaptureRect
	/// Pixels per point of the captured display.
	public var scale: Double
	public var cursor: [CursorSample]
	public var cursorShapes: [CursorShape]
	public var clicks: [ClickEvent]
	public var keys: [KeyEvent]
	public var scrolls: [ScrollEvent]
	/// Bounds of the focused text input while typing, when Accessibility allows reading it.
	public var focus: [FocusEvent]

	public init(
		captureRect: CaptureRect = CaptureRect(x: 0, y: 0, width: 1, height: 1),
		scale: Double = 2,
		cursor: [CursorSample] = [],
		cursorShapes: [CursorShape] = [],
		clicks: [ClickEvent] = [],
		keys: [KeyEvent] = [],
		scrolls: [ScrollEvent] = [],
		focus: [FocusEvent] = []
	) {
		self.formatVersion = 1
		self.captureRect = captureRect
		self.scale = scale
		self.cursor = cursor
		self.cursorShapes = cursorShapes
		self.clicks = clicks
		self.keys = keys
		self.scrolls = scrolls
		self.focus = focus
	}

	public static let empty = InputTrack()
}

public struct CaptureRect: Codable, Hashable, Sendable {
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

	/// Converts a global point (top-left origin) to normalized coordinates of this rect.
	public func normalize(x px: Double, y py: Double) -> NormPoint {
		NormPoint(x: (px - x) / max(width, 1), y: (py - y) / max(height, 1))
	}

	public func normalize(_ rect: CaptureRect) -> NormRect {
		let origin = normalize(x: rect.x, y: rect.y)
		return NormRect(x: origin.x, y: origin.y, width: rect.width / max(width, 1), height: rect.height / max(height, 1))
	}
}

public struct CursorSample: Codable, Hashable, Sendable {
	public var t: Double
	public var x: Double
	public var y: Double
	/// Index into `InputTrack.cursorShapes`, or -1 when the cursor is hidden.
	public var shape: Int

	public init(t: Double, x: Double, y: Double, shape: Int = 0) {
		self.t = t
		self.x = x
		self.y = y
		self.shape = shape
	}

	public var point: NormPoint { NormPoint(x: x, y: y) }
}

public struct CursorShape: Codable, Hashable, Sendable {
	public enum Kind: String, Codable, Sendable {
		case arrow, pointer, iBeam, crosshair, openHand, closedHand, resizeLeftRight, resizeUpDown, notAllowed, other
	}

	public var kind: Kind
	/// Hotspot in points from the image's top-left.
	public var hotspotX: Double
	public var hotspotY: Double
	/// Size in points.
	public var width: Double
	public var height: Double
	/// PNG of the system cursor, kept for shapes Nebula can't redraw (`.other`).
	public var png: Data?

	public init(kind: Kind, hotspotX: Double = 0, hotspotY: Double = 0, width: Double = 0, height: Double = 0, png: Data? = nil) {
		self.kind = kind
		self.hotspotX = hotspotX
		self.hotspotY = hotspotY
		self.width = width
		self.height = height
		self.png = png
	}
}

public struct ClickEvent: Codable, Hashable, Sendable {
	public enum Button: String, Codable, Sendable {
		case left, right, other
	}

	public var t: Double
	public var x: Double
	public var y: Double
	public var button: Button
	/// Time the button was released.
	public var upT: Double?

	public init(t: Double, x: Double, y: Double, button: Button = .left, upT: Double? = nil) {
		self.t = t
		self.x = x
		self.y = y
		self.button = button
		self.upT = upT
	}

	public var point: NormPoint { NormPoint(x: x, y: y) }
}

/// A key press. Typed characters are never stored: plain typing is recorded as `.typing`,
/// and only presses with ⌘/⌃/⌥ (or special keys) keep a label for the shortcut overlay.
public struct KeyEvent: Codable, Hashable, Sendable {
	public enum Kind: String, Codable, Sendable {
		case typing
		case shortcut
	}

	public var t: Double
	public var kind: Kind
	/// Keycap labels for shortcuts, e.g. ["⌘", "⇧", "4"].
	public var keys: [String]

	public init(t: Double, kind: Kind, keys: [String] = []) {
		self.t = t
		self.kind = kind
		self.keys = keys
	}
}

public struct ScrollEvent: Codable, Hashable, Sendable {
	public var t: Double
	public var x: Double
	public var y: Double
	public var dy: Double

	public init(t: Double, x: Double, y: Double, dy: Double) {
		self.t = t
		self.x = x
		self.y = y
		self.dy = dy
	}
}

public struct FocusEvent: Codable, Hashable, Sendable {
	public var t: Double
	/// Normalized bounds of the focused text input; nil when focus left a text input.
	public var rect: NormRect?

	public init(t: Double, rect: NormRect?) {
		self.t = t
		self.rect = rect
	}
}
