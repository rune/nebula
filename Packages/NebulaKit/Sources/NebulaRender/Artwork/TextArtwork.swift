import CoreGraphics
import CoreImage
import CoreText
import Foundation
import NebulaCore

/// Text overlays (labels, keycaps, captions) and arrows, drawn with Core Text / Core Graphics
/// at output resolution and cached.
public final class TextArtwork: Sendable {
	public struct Image: @unchecked Sendable {
		public var image: CIImage
		public var size: CGSize
	}

	private let cache = RenderCache<String, Image>(limit: 96)

	public init() {}

	// MARK: - Fonts

	/// The UI typeface (registered by the app) with a weight axis value, falling back to the system font.
	static func font(size: CGFloat, weight: CGFloat) -> CTFont {
		let variation = [0x7767_6874 as NSNumber: NSNumber(value: Double(weight))] as CFDictionary // 'wght'
		let attributes = [kCTFontNameAttribute: "Manrope", kCTFontVariationAttribute: variation] as CFDictionary
		let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
		let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
		if (CTFontCopyFamilyName(font) as String).lowercased().contains("manrope") { return font }
		let system = CTFontCreateUIFontForLanguage(weight >= 650 ? .emphasizedSystem : .system, size, nil)
		return system ?? font
	}

	// MARK: - Labels

	public func label(_ text: String, fontSize: CGFloat, color: ColorValue, background: ColorValue?, bold: Bool, maxWidth: CGFloat) -> Image? {
		let key = "label|\(text)|\(Int(fontSize))|\(color.hex)|\(background?.hex ?? "-")|\(bold)|\(Int(maxWidth))"
		return cache.value(for: key) {
			let font = Self.font(size: fontSize, weight: bold ? 750 : 520)
			let padding = background == nil ? .zero : CGSize(width: fontSize * 0.55, height: fontSize * 0.32)
			return Self.drawText(
				Self.attributed(text, font: font, color: color),
				maxWidth: maxWidth - 2 * padding.width,
				padding: padding,
				background: background,
				cornerRadius: fontSize * 0.45
			)
		}
	}

	// MARK: - Keycaps

	public func keycaps(_ keys: [String], height: CGFloat) -> Image? {
		let key = "keys|\(keys.joined(separator: " "))|\(Int(height))"
		return cache.value(for: key) {
			let font = Self.font(size: height * 0.42, weight: 650)
			let gap = height * 0.16
			let caps: [(CFAttributedString, CGFloat)] = keys.map { label in
				let string = Self.attributed(label, font: font, color: .white)
				let line = CTLineCreateWithAttributedString(string)
				let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
				return (string, max(height, textWidth + height * 0.62))
			}
			let width = caps.reduce(0) { $0 + $1.1 } + gap * CGFloat(max(0, caps.count - 1))
			let size = CGSize(width: ceil(width), height: ceil(height * 1.08))
			return Self.draw(size: size) { context in
				var x: CGFloat = 0
				for (string, capWidth) in caps {
					let cap = CGRect(x: x, y: height * 0.08, width: capWidth, height: height)
					let base = CGPath(roundedRect: cap.offsetBy(dx: 0, dy: -height * 0.06), cornerWidth: height * 0.24, cornerHeight: height * 0.24, transform: nil)
					context.setFillColor(CGColor(gray: 0, alpha: 0.55))
					context.addPath(base)
					context.fillPath()
					let face = CGPath(roundedRect: cap, cornerWidth: height * 0.24, cornerHeight: height * 0.24, transform: nil)
					context.setFillColor(CGColor(red: 0.11, green: 0.10, blue: 0.14, alpha: 0.94))
					context.addPath(face)
					context.fillPath()
					context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
					context.setLineWidth(max(1, height * 0.025))
					context.addPath(face)
					context.strokePath()
					let line = CTLineCreateWithAttributedString(string)
					let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
					context.textPosition = CGPoint(x: cap.midX - bounds.width / 2 - bounds.minX, y: cap.midY - bounds.height / 2 - bounds.minY)
					CTLineDraw(line, context)
					x += capWidth + gap
				}
			}
		}
	}

	// MARK: - Captions

	/// A caption line with one word highlighted (`highlight` index into `words`, or nil).
	public func caption(words: [String], highlight: Int?, style: CaptionStyle, fontSize: CGFloat, maxWidth: CGFloat) -> Image? {
		let key = "cap|\(words.joined(separator: " "))|\(highlight ?? -1)|\(Int(fontSize))|\(style.color.hex)|\(style.highlight.hex)|\(style.background?.hex ?? "-")|\(Int(maxWidth))"
		return cache.value(for: key) {
			let font = Self.font(size: fontSize, weight: 700)
			let string = NSMutableAttributedString()
			for (index, word) in words.enumerated() {
				let color = index == highlight ? style.highlight : style.color
				string.append(Self.attributed(index == 0 ? word : " " + word, font: font, color: color) as NSAttributedString)
			}
			let padding = style.background == nil ? .zero : CGSize(width: fontSize * 0.6, height: fontSize * 0.34)
			return Self.drawText(
				string,
				maxWidth: maxWidth - 2 * padding.width,
				padding: padding,
				background: style.background,
				cornerRadius: fontSize * 0.42,
				centered: true
			)
		}
	}

	// MARK: - Arrows

	/// An arrow from `from` to `to` (canvas pixels, bottom-left origin), with the image's origin.
	public func arrow(from: CGPoint, to: CGPoint, color: ColorValue, width: CGFloat) -> (Image, CGPoint)? {
		let head = width * 4.2
		let margin = head + width * 2
		let minX = min(from.x, to.x) - margin
		let minY = min(from.y, to.y) - margin
		let size = CGSize(width: ceil(abs(to.x - from.x) + 2 * margin), height: ceil(abs(to.y - from.y) + 2 * margin))
		let key = "arrow|\(Int(from.x - minX))|\(Int(from.y - minY))|\(Int(to.x - minX))|\(Int(to.y - minY))|\(color.hex)|\(Int(width * 10))"
		let image = cache.value(for: key) {
			Self.draw(size: size) { context in
				let a = CGPoint(x: from.x - minX, y: from.y - minY)
				let b = CGPoint(x: to.x - minX, y: to.y - minY)
				let angle = atan2(b.y - a.y, b.x - a.x)
				let shaft = CGPoint(x: b.x - cos(angle) * head * 0.6, y: b.y - sin(angle) * head * 0.6)
				context.setShadow(offset: CGSize(width: 0, height: -width * 0.6), blur: width * 2, color: CGColor(gray: 0, alpha: 0.45))
				context.setStrokeColor(color.cgColor)
				context.setFillColor(color.cgColor)
				context.setLineWidth(width)
				context.setLineCap(.round)
				context.move(to: a)
				context.addLine(to: shaft)
				context.strokePath()
				context.move(to: b)
				context.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
				context.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
				context.closePath()
				context.fillPath()
			}
		}
		return image.map { ($0, CGPoint(x: minX, y: minY)) }
	}

	// MARK: - Drawing helpers

	static func attributed(_ text: String, font: CTFont, color: ColorValue) -> CFAttributedString {
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font,
			NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
		]
		return NSAttributedString(string: text, attributes: attributes) as CFAttributedString
	}

	private static func drawText(
		_ string: CFAttributedString,
		maxWidth: CGFloat,
		padding: CGSize,
		background: ColorValue?,
		cornerRadius: CGFloat,
		centered: Bool = true
	) -> Image? {
		let mutable = NSMutableAttributedString(attributedString: string as NSAttributedString)
		var alignment: CTTextAlignment = centered ? .center : .left
		var lineBreak: CTLineBreakMode = .byWordWrapping
		let paragraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
			withUnsafeBytes(of: &lineBreak) { breakBytes in
				let settings = [
					CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
					CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: breakBytes.baseAddress!),
				]
				return CTParagraphStyleCreate(settings, settings.count)
			}
		}
		mutable.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraph, range: NSRange(location: 0, length: mutable.length))
		let framesetter = CTFramesetterCreateWithAttributedString(mutable as CFAttributedString)
		let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: max(maxWidth, 10), height: .greatestFiniteMagnitude), nil)
		let textSize = CGSize(width: ceil(fit.width), height: ceil(fit.height))
		let size = CGSize(width: textSize.width + 2 * padding.width, height: textSize.height + 2 * padding.height)
		return draw(size: size) { context in
			if let background {
				context.setFillColor(background.cgColor)
				context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
				context.fillPath()
			}
			let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: CGPoint(x: padding.width, y: padding.height), size: textSize), transform: nil), nil)
			CTFrameDraw(frame, context)
		}
	}

	static func draw(size: CGSize, _ body: (CGContext) -> Void) -> Image? {
		let width = max(1, Int(size.width.rounded(.up)))
		let height = max(1, Int(size.height.rounded(.up)))
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		context.setShouldAntialias(true)
		context.setShouldSmoothFonts(true)
		body(context)
		guard let image = context.makeImage() else { return nil }
		return Image(image: CIImage(cgImage: image), size: CGSize(width: width, height: height))
	}
}

extension ColorValue {
	var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
	var ciColor: CIColor { CIColor(red: red, green: green, blue: blue, alpha: alpha, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? CIColor(red: red, green: green, blue: blue, alpha: alpha) }
}
