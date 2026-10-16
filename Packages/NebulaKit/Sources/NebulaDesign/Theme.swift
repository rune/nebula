import AppKit
import CoreText
import SwiftUI

/// Nebula's design tokens. Mirrors `design/mockups/tokens.css` one to one.
///
/// Rules: surfaces get lighter as they rise; borders are hairlines; violet is only an accent
/// (selection, focus, primary action). No glows: depth comes from neutral shadows only.
public enum Theme {
	// MARK: Surfaces (darkest to lightest)
	public static let window = Color(hex: 0x040406)
	public static let canvas = Color(hex: 0x07070A)
	public static let surface1 = Color(hex: 0x0C0C11)
	public static let surface2 = Color(hex: 0x121218)
	public static let surface3 = Color(hex: 0x19191F)
	public static let hairline = Color.white.opacity(0.055)
	public static let hairlineStrong = Color.white.opacity(0.10)

	// MARK: Text
	public static let text1 = Color(hex: 0xF3F2F7)
	public static let text2 = Color(hex: 0xA09EAD)
	public static let text3 = Color(hex: 0x65636F)

	// MARK: Accent
	public static let violet = Color(hex: 0x8C28FF)
	public static let lavender = Color(hex: 0xB089F0)
	public static let violetSoft = Color(hex: 0x8C28FF).opacity(0.16)
	public static let violetLine = Color(hex: 0xA05FFF).opacity(0.55)
	public static let gradient = LinearGradient(colors: [Color(hex: 0xB22EFF), Color(hex: 0x6828FF)], startPoint: .top, endPoint: .bottom)
	public static let sliderGradient = LinearGradient(colors: [Color(hex: 0x6828FF), Color(hex: 0xB22EFF)], startPoint: .leading, endPoint: .trailing)
	public static let success = Color(hex: 0x3DDC97)
	public static let recording = Color(hex: 0xFF3B5C)

	// MARK: Timeline tracks
	public static let trackZoom = Color(hex: 0x8C28FF)
	public static let trackSpeed = Color(hex: 0x6E7BFF)
	public static let trackMask = Color(hex: 0xD14BFF)
	public static let trackNote = Color(hex: 0xE6E3F0)

	// MARK: Shape
	public static let radiusS: CGFloat = 7
	public static let radiusM: CGFloat = 10
	public static let radiusL: CGFloat = 14

	// MARK: Motion
	public static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
	public static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

// MARK: - Typography

public enum NebulaFont {
	private static let registered: Bool = {
		guard let url = Bundle.module.url(forResource: "Manrope-Variable", withExtension: "ttf") else { return false }
		return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
	}()

	/// Registers the bundled typeface for the whole process. Call once at launch.
	public static func register() {
		_ = registered
	}

	/// Manrope at an exact weight (100–800 on the variable axis); falls back to the system font.
	public static func nsFont(size: CGFloat, weight: CGFloat) -> NSFont {
		register()
		let variation = [NSNumber(value: 0x7767_6874): NSNumber(value: Double(weight))] // 'wght'
		let descriptor = NSFontDescriptor(fontAttributes: [
			.name: "Manrope",
			NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation,
		])
		return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight >= 650 ? .semibold : .regular)
	}
}

extension Font {
	/// The app typeface. Weights follow the mockups: 550 body, 650 labels, 750 headings.
	public static func nebula(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
		Font(NebulaFont.nsFont(size: size, weight: weight))
	}
}

// MARK: - Colour helpers

extension Color {
	public init(hex: UInt32, opacity: Double = 1) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255,
			opacity: opacity
		)
	}
}
