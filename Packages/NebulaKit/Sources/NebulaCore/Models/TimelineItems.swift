import Foundation

/// Any item that lives on the timeline. Times are source seconds.
public protocol TimelineItem: Identifiable, Codable, Hashable, Sendable where ID == ItemID {
	var id: ItemID { get }
	var range: TimeRange { get set }
}

// MARK: - Zoom

public struct ZoomItem: TimelineItem {
	public enum Target: Codable, Hashable, Sendable {
		/// Follow the cursor and clicks inside the range, panning smoothly.
		case follow
		/// Fixed focus point.
		case point(NormPoint)
		/// Frame this rect (e.g. a text field); the scale is derived to fit it.
		case rect(NormRect)
	}

	public enum Transition: String, Codable, Sendable {
		/// Spring-animated, using the project's camera settings.
		case spring
		/// Cut straight in and out.
		case instant
	}

	public var id: ItemID
	public var range: TimeRange
	public var target: Target
	/// Magnification, 1–5. For `.rect` targets this is the upper bound.
	public var scale: Double
	public var transition: Transition
	public var source: ItemSource

	public init(
		id: ItemID = .make("zoom"),
		range: TimeRange,
		target: Target = .follow,
		scale: Double = 1.8,
		transition: Transition = .spring,
		source: ItemSource = .user
	) {
		self.id = id
		self.range = range
		self.target = target
		self.scale = scale
		self.transition = transition
		self.source = source
	}

	public static let scaleRange: ClosedRange<Double> = 1...5
}

// MARK: - Clips

/// A section removed from the output.
public struct CutItem: TimelineItem {
	public var id: ItemID
	public var range: TimeRange
	public var source: ItemSource

	public init(id: ItemID = .make("cut"), range: TimeRange, source: ItemSource = .user) {
		self.id = id
		self.range = range
		self.source = source
	}
}

/// A section played faster or slower.
public struct SpeedItem: TimelineItem {
	public var id: ItemID
	public var range: TimeRange
	/// Playback rate, 0.25–16.
	public var rate: Double
	public var source: ItemSource

	public init(id: ItemID = .make("speed"), range: TimeRange, rate: Double, source: ItemSource = .user) {
		self.id = id
		self.range = range
		self.rate = rate
		self.source = source
	}

	public static let rateRange: ClosedRange<Double> = 0.25...16
}

// MARK: - Masks

public struct MaskItem: TimelineItem {
	public enum Kind: Codable, Hashable, Sendable {
		/// Gaussian blur; `amount` 0–1.
		case blur(amount: Double)
		/// Pixelate; `amount` 0–1 maps to block size.
		case pixelate(amount: Double)
		/// Dim everything outside the rect; `amount` is the dim opacity 0–1.
		case highlight(amount: Double)
	}

	public var id: ItemID
	public var range: TimeRange
	/// Rect in normalized video coordinates; masks move with the camera.
	public var rect: NormRect
	public var kind: Kind
	/// Corner radius as a fraction of the shorter side, 0–0.5.
	public var cornerRadius: Double
	public var source: ItemSource

	public init(
		id: ItemID = .make("mask"),
		range: TimeRange,
		rect: NormRect,
		kind: Kind = .blur(amount: 0.6),
		cornerRadius: Double = 0.08,
		source: ItemSource = .user
	) {
		self.id = id
		self.range = range
		self.rect = rect
		self.kind = kind
		self.cornerRadius = cornerRadius
		self.source = source
	}
}

// MARK: - Annotations

public struct AnnotationItem: TimelineItem {
	public enum Anchor: String, Codable, Sendable {
		/// Positioned on the recording, so it moves with zooms.
		case screen
		/// Positioned on the output frame, unaffected by zooms.
		case canvas
	}

	public enum Kind: Codable, Hashable, Sendable {
		case text(TextAnnotation)
		case arrow(ArrowAnnotation)
	}

	public var id: ItemID
	public var range: TimeRange
	public var kind: Kind
	public var anchor: Anchor
	public var source: ItemSource

	public init(
		id: ItemID = .make("note"),
		range: TimeRange,
		kind: Kind,
		anchor: Anchor = .screen,
		source: ItemSource = .user
	) {
		self.id = id
		self.range = range
		self.kind = kind
		self.anchor = anchor
		self.source = source
	}
}

public struct TextAnnotation: Codable, Hashable, Sendable {
	public var text: String
	/// Centre of the label.
	public var position: NormPoint
	/// Font size relative to output height (0.04 ≈ 43 px at 1080p).
	public var fontSize: Double
	public var color: ColorValue
	public var background: ColorValue?
	public var bold: Bool
	public var animation: TextAnimation

	public init(
		text: String,
		position: NormPoint,
		fontSize: Double = 0.04,
		color: ColorValue = .white,
		background: ColorValue? = ColorValue(hex: "#000000B3"),
		bold: Bool = true,
		animation: TextAnimation = .pop
	) {
		self.text = text
		self.position = position
		self.fontSize = fontSize
		self.color = color
		self.background = background
		self.bold = bold
		self.animation = animation
	}
}

public enum TextAnimation: String, Codable, Sendable, CaseIterable {
	case none, fade, pop, rise
}

public struct ArrowAnnotation: Codable, Hashable, Sendable {
	public var from: NormPoint
	public var to: NormPoint
	public var color: ColorValue
	/// Stroke width relative to output height.
	public var width: Double

	public init(from: NormPoint, to: NormPoint, color: ColorValue = ColorValue(hex: "#B089F0")!, width: Double = 0.006) {
		self.from = from
		self.to = to
		self.color = color
		self.width = width
	}
}

// MARK: - Audio

public struct VolumeItem: TimelineItem {
	public enum Channel: String, Codable, Sendable, CaseIterable {
		case all, microphone, system
	}

	public var id: ItemID
	public var range: TimeRange
	/// Linear gain, 0 (mute) – 2.
	public var gain: Double
	public var channel: Channel

	public init(id: ItemID = .make("vol"), range: TimeRange, gain: Double, channel: Channel = .all) {
		self.id = id
		self.range = range
		self.gain = gain
		self.channel = channel
	}
}
