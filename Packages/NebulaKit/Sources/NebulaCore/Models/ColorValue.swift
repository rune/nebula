import Foundation

/// An sRGB colour that survives Codable round-trips and crosses actors freely.
public struct ColorValue: Codable, Hashable, Sendable {
	public var red: Double
	public var green: Double
	public var blue: Double
	public var alpha: Double

	public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	/// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
	public init?(hex: String) {
		var value = hex.trimmingCharacters(in: .whitespaces)
		if value.hasPrefix("#") { value.removeFirst() }
		if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
		guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
		let hasAlpha = value.count == 8
		let r = (number >> (hasAlpha ? 24 : 16)) & 0xFF
		let g = (number >> (hasAlpha ? 16 : 8)) & 0xFF
		let b = (number >> (hasAlpha ? 8 : 0)) & 0xFF
		let a = hasAlpha ? number & 0xFF : 0xFF
		self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: Double(a) / 255)
	}

	public var hex: String {
		let components = [red, green, blue] + (alpha < 1 ? [alpha] : [])
		return "#" + components.map { String(format: "%02X", Int(($0 * 255).rounded()).clamped(to: 0...255)) }.joined()
	}

	public func withAlpha(_ alpha: Double) -> ColorValue {
		ColorValue(red: red, green: green, blue: blue, alpha: alpha)
	}

	public static let white = ColorValue(red: 1, green: 1, blue: 1)
	public static let black = ColorValue(red: 0, green: 0, blue: 0)
	public static let violet = ColorValue(hex: "#8C28FF")!
}
