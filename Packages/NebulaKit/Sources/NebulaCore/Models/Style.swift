import Foundation

/// How the recording sits on the output frame.
///
/// The default is the "real desktop" look: window and area recordings keep their true size on
/// a screen-shaped frame over the wallpaper that was on screen while recording; full-display
/// recordings fill the frame with no background at all.
public struct Style: Codable, Hashable, Sendable {
	public enum Placement: String, Codable, Sendable, CaseIterable {
		/// Window/area recordings keep the size they had on screen, centred on a screen-shaped frame.
		case original
		/// The recording is fitted inside the frame, with `padding` around it.
		case fit

		public var title: String {
			switch self {
			case .original: "As on screen"
			case .fit: "Fit with padding"
			}
		}
	}

	public var background: Background
	/// Blur applied to image backgrounds, 0–1.
	public var backgroundBlur: Double
	public var placement: Placement
	/// Extra space around the recording as a fraction of the output's shorter side, 0–0.4.
	/// With `.original`, shrinks the recording further by that amount.
	public var padding: Double
	/// Inner border width as a fraction of the shorter side, 0–0.05.
	public var inset: Double
	public var insetColor: ColorValue
	/// Corner radius as a fraction of the shorter side, 0–0.1. Ignored when the recording fills the frame.
	public var cornerRadius: Double
	/// Ignored when the recording fills the frame.
	public var shadow: ShadowStyle
	public var aspectRatio: AspectRatio
	/// Part of the recording to keep, in normalized video coordinates.
	public var crop: NormRect

	public init(
		background: Background = .color(ColorValue(hex: "#0B0B0F")!),
		backgroundBlur: Double = 0,
		placement: Placement = .original,
		padding: Double = 0,
		inset: Double = 0,
		insetColor: ColorValue = ColorValue(hex: "#FFFFFF1A")!,
		cornerRadius: Double = 0.012,
		shadow: ShadowStyle = ShadowStyle(),
		aspectRatio: AspectRatio = .auto,
		crop: NormRect = .full
	) {
		self.background = background
		self.backgroundBlur = backgroundBlur
		self.placement = placement
		self.padding = padding
		self.inset = inset
		self.insetColor = insetColor
		self.cornerRadius = cornerRadius
		self.shadow = shadow
		self.aspectRatio = aspectRatio
		self.crop = crop
	}

	private enum CodingKeys: String, CodingKey {
		case background, backgroundBlur, placement, padding, inset, insetColor, cornerRadius, shadow, aspectRatio, crop
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let defaults = Style()
		background = (try? c.decode(Background.self, forKey: .background)) ?? defaults.background
		backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? defaults.backgroundBlur
		placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? defaults.placement
		padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? defaults.padding
		inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? defaults.inset
		insetColor = try c.decodeIfPresent(ColorValue.self, forKey: .insetColor) ?? defaults.insetColor
		cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? defaults.cornerRadius
		shadow = try c.decodeIfPresent(ShadowStyle.self, forKey: .shadow) ?? defaults.shadow
		aspectRatio = try c.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio) ?? defaults.aspectRatio
		crop = try c.decodeIfPresent(NormRect.self, forKey: .crop) ?? defaults.crop
	}
}

public enum Background: Codable, Hashable, Sendable {
	/// An image file: an absolute path (macOS wallpapers, your own images) or a path inside the
	/// project bundle (the desktop wallpaper captured while recording is `media/desktop.jpg`).
	case image(path: String)
	case gradient(GradientFill)
	case color(ColorValue)

	/// The wallpaper captured with a recording.
	public static let desktop = Background.image(path: "\(ProjectBundle.mediaFolderName)/\(ProjectBundle.desktopFileName)")
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

	public init(opacity: Double = 0.5, radius: Double = 0.03, offsetY: Double = 0.01) {
		self.opacity = opacity
		self.radius = radius
		self.offsetY = offsetY
	}
}

public enum AspectRatio: String, Codable, Sendable, CaseIterable {
	/// The screen's shape for window/area recordings; otherwise the recording's.
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
		case .wide: "16:9"
		case .vertical: "9:16"
		case .square: "1:1"
		case .classic: "4:3"
		case .portrait: "4:5"
		}
	}
}
