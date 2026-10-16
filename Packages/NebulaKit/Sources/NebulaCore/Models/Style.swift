import Foundation

/// How the recording sits on the output frame.
public struct Style: Codable, Hashable, Sendable {
	public var background: Background
	/// Blur applied to image backgrounds, 0–1.
	public var backgroundBlur: Double
	/// Space around the recording as a fraction of the output's shorter side, 0–0.4.
	public var padding: Double
	/// Inner border width as a fraction of the shorter side, 0–0.05.
	public var inset: Double
	public var insetColor: ColorValue
	/// Corner radius as a fraction of the shorter side, 0–0.1.
	public var cornerRadius: Double
	public var shadow: ShadowStyle
	public var aspectRatio: AspectRatio
	/// Part of the recording to keep, in normalized video coordinates.
	public var crop: NormRect

	public init(
		background: Background = .wallpaper("aurora"),
		backgroundBlur: Double = 0,
		padding: Double = 0.07,
		inset: Double = 0,
		insetColor: ColorValue = ColorValue(hex: "#FFFFFF1A")!,
		cornerRadius: Double = 0.018,
		shadow: ShadowStyle = ShadowStyle(),
		aspectRatio: AspectRatio = .auto,
		crop: NormRect = .full
	) {
		self.background = background
		self.backgroundBlur = backgroundBlur
		self.padding = padding
		self.inset = inset
		self.insetColor = insetColor
		self.cornerRadius = cornerRadius
		self.shadow = shadow
		self.aspectRatio = aspectRatio
		self.crop = crop
	}
}

public enum Background: Codable, Hashable, Sendable {
	/// One of Nebula's built-in generated wallpapers, by id.
	case wallpaper(String)
	/// An image file: absolute path (macOS wallpapers) or a path inside the project bundle.
	case image(path: String)
	case gradient(GradientFill)
	case color(ColorValue)
}

public struct GradientFill: Codable, Hashable, Sendable {
	public var colors: [ColorValue]
	/// Degrees, 0 = left→right, 90 = top→bottom.
	public var angle: Double

	public init(colors: [ColorValue], angle: Double = 135) {
		self.colors = colors
		self.angle = angle
	}
}

public struct ShadowStyle: Codable, Hashable, Sendable {
	/// 0–1.
	public var opacity: Double
	/// Blur radius as a fraction of the shorter side.
	public var radius: Double
	/// Vertical offset as a fraction of the shorter side.
	public var offsetY: Double

	public init(opacity: Double = 0.55, radius: Double = 0.035, offsetY: Double = 0.012) {
		self.opacity = opacity
		self.radius = radius
		self.offsetY = offsetY
	}
}

public enum AspectRatio: String, Codable, Sendable, CaseIterable {
	/// Same as the (cropped) recording.
	case auto
	case wide = "16:9"
	case vertical = "9:16"
	case square = "1:1"
	case classic = "4:3"
	case portrait = "4:5"

	/// Width / height, or nil for `.auto`.
	public var value: Double? {
		switch self {
		case .auto: nil
		case .wide: 16.0 / 9.0
		case .vertical: 9.0 / 16.0
		case .square: 1
		case .classic: 4.0 / 3.0
		case .portrait: 4.0 / 5.0
		}
	}

	public var title: String {
		switch self {
		case .auto: "Auto"
		case .wide: "Wide 16:9"
		case .vertical: "Vertical 9:16"
		case .square: "Square 1:1"
		case .classic: "Classic 4:3"
		case .portrait: "Portrait 4:5"
		}
	}
}
