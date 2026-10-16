import Foundation

public struct CaptionTrack: Codable, Hashable, Sendable {
	public var language: String
	public var segments: [CaptionSegment]
	public var style: CaptionStyle
	public var enabled: Bool

	public init(language: String = "en", segments: [CaptionSegment] = [], style: CaptionStyle = CaptionStyle(), enabled: Bool = true) {
		self.language = language
		self.segments = segments
		self.style = style
		self.enabled = enabled
	}
}

public struct CaptionSegment: Codable, Hashable, Sendable, Identifiable {
	public var id: ItemID
	public var range: TimeRange
	public var text: String
	public var words: [CaptionWord]

	public init(id: ItemID = .make("cap"), range: TimeRange, text: String, words: [CaptionWord] = []) {
		self.id = id
		self.range = range
		self.text = text
		self.words = words
	}
}

public struct CaptionWord: Codable, Hashable, Sendable {
	public var range: TimeRange
	public var text: String

	public init(range: TimeRange, text: String) {
		self.range = range
		self.text = text
	}
}

public struct CaptionStyle: Codable, Hashable, Sendable {
	public enum Mode: String, Codable, Sendable, CaseIterable {
		/// Whole lines, the current word highlighted.
		case line
		/// One word at a time, large.
		case word
	}

	public enum Position: String, Codable, Sendable, CaseIterable {
		case bottom, top
	}

	public var mode: Mode
	public var position: Position
	/// Relative to output height.
	public var fontSize: Double
	public var color: ColorValue
	public var highlight: ColorValue
	public var background: ColorValue?

	public init(
		mode: Mode = .line,
		position: Position = .bottom,
		fontSize: Double = 0.042,
		color: ColorValue = .white,
		highlight: ColorValue = ColorValue(hex: "#B089F0")!,
		background: ColorValue? = ColorValue(hex: "#000000A6")
	) {
		self.mode = mode
		self.position = position
		self.fontSize = fontSize
		self.color = color
		self.highlight = highlight
		self.background = background
	}
}
