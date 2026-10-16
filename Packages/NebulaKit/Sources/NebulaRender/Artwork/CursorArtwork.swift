import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import NebulaCore

/// Cursor images rendered at exactly the size they're drawn, so they stay sharp at 4K and
/// when zoomed. The arrow is drawn from vector paths; other shapes use macOS's own vector
/// cursor artwork (PDF); unknown shapes use the bitmap captured while recording.
public final class CursorArtwork: Sendable {
	public struct Image: @unchecked Sendable {
		public var image: CIImage
		/// Hotspot from the image's bottom-left, in pixels.
		public var hotspot: CGPoint
	}

	private struct Key: Hashable, Sendable {
		var kind: CursorShape.Kind
		var pixelHeight: Int
		var custom: Int
	}

	private let cache = RenderCache<Key, Image>(limit: 64)

	public init() {}

	/// Artwork scaled so one cursor point is `pixelsPerPoint` output pixels.
	public func image(for shape: CursorShape, pixelsPerPoint: CGFloat) -> Image? {
		let template = Self.template(for: shape)
		let height = max(8, Int((template.size.height * pixelsPerPoint).rounded()))
		let key = Key(kind: shape.kind, pixelHeight: height, custom: shape.kind == .other ? shape.png?.hashValue ?? 0 : 0)
		return cache.value(for: key) {
			let scale = CGFloat(height) / template.size.height
			let pixelSize = CGSize(width: (template.size.width * scale).rounded(.up), height: CGFloat(height))
			guard let cgImage = Self.render(template: template, shape: shape, pixelSize: pixelSize) else { return nil }
			let hotspot = CGPoint(x: template.hotspot.x * scale, y: pixelSize.height - template.hotspot.y * scale)
			return Image(image: CIImage(cgImage: cgImage), hotspot: hotspot)
		}
	}

	// MARK: - Templates

	struct Template: @unchecked Sendable {
		var size: CGSize
		/// Hotspot from the top-left, in points.
		var hotspot: CGPoint
		var pdf: CGPDFPage?
		var shadowBlur: CGFloat = 2
		var shadowAlpha: CGFloat = 0.4
	}

	private static let systemCursorFolder = URL(fileURLWithPath:
		"/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors")

	private static let pdfTemplates: [CursorShape.Kind: Template] = {
		let folders: [CursorShape.Kind: String] = [
			.pointer: "pointinghand", .iBeam: "ibeamhorizontal", .crosshair: "cross", .openHand: "openhand",
			.closedHand: "closedhand", .resizeLeftRight: "resizeleftright", .resizeUpDown: "resizeupdown",
			.notAllowed: "notallowed",
		]
		var templates: [CursorShape.Kind: Template] = [:]
		for (kind, folder) in folders {
			let url = systemCursorFolder.appending(path: folder)
			guard let document = CGPDFDocument(url.appending(path: "cursor.pdf") as CFURL),
				let page = document.page(at: 1) else { continue }
			let info = NSDictionary(contentsOf: url.appending(path: "info.plist")) ?? [:]
			let box = page.getBoxRect(.mediaBox)
			let hotX = (info["hotx"] as? NSNumber)?.doubleValue ?? 0
			let hotY = (info["hoty"] as? NSNumber)?.doubleValue ?? 0
			let shadowColor = info["shadowcolor"] as? [NSNumber]
			templates[kind] = Template(
				size: box.size,
				hotspot: CGPoint(x: hotX, y: hotY),
				pdf: page,
				shadowBlur: CGFloat((info["blur"] as? NSNumber)?.doubleValue ?? 2),
				shadowAlpha: CGFloat(shadowColor?.last?.doubleValue ?? 0.4)
			)
		}
		return templates
	}()

	static func template(for shape: CursorShape) -> Template {
		switch shape.kind {
		case .arrow:
			return Template(size: CGSize(width: 17, height: 24), hotspot: CGPoint(x: 4, y: 3))
		case .other:
			let size = shape.width > 0 ? CGSize(width: shape.width, height: shape.height) : CGSize(width: 16, height: 16)
			return Template(size: size, hotspot: CGPoint(x: shape.hotspotX, y: shape.hotspotY))
		default:
			return pdfTemplates[shape.kind] ?? template(for: CursorShape(kind: .arrow))
		}
	}

	// MARK: - Drawing

	private static func render(template: Template, shape: CursorShape, pixelSize: CGSize) -> CGImage? {
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			let context = CGContext(
				data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
				space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return nil }
		context.interpolationQuality = .high
		let scale = pixelSize.height / template.size.height

		if let pdf = template.pdf {
			context.saveGState()
			context.setShadow(offset: CGSize(width: 0, height: -scale), blur: template.shadowBlur * scale, color: CGColor(gray: 0, alpha: template.shadowAlpha))
			context.scaleBy(x: scale, y: scale)
			context.drawPDFPage(pdf)
			context.restoreGState()
		} else if shape.kind == .other {
			guard let png = shape.png, let source = CGImageSourceCreateWithData(png as CFData, nil),
				let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
			context.draw(image, in: CGRect(origin: .zero, size: pixelSize))
		} else {
			context.scaleBy(x: scale, y: scale)
			context.translateBy(x: 0, y: template.size.height)
			context.scaleBy(x: 1, y: -1)
			drawArrow(in: context)
		}
		return context.makeImage()
	}

	/// The classic arrow: white body, black outline, soft shadow. 17×24 pt, hotspot (4, 3).
	private static func drawArrow(in context: CGContext) {
		let path = CGMutablePath()
		path.move(to: CGPoint(x: 4, y: 3))
		path.addLine(to: CGPoint(x: 4, y: 19.5))
		path.addLine(to: CGPoint(x: 7.8, y: 15.9))
		path.addLine(to: CGPoint(x: 10.4, y: 21.6))
		path.addLine(to: CGPoint(x: 13.1, y: 20.4))
		path.addLine(to: CGPoint(x: 10.5, y: 14.8))
		path.addLine(to: CGPoint(x: 15.6, y: 14.6))
		path.closeSubpath()

		context.saveGState()
		context.setShadow(offset: CGSize(width: 0, height: 0.9), blur: 2.2, color: CGColor(gray: 0, alpha: 0.42))
		context.addPath(path)
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fillPath()
		context.restoreGState()

		context.addPath(path)
		context.setStrokeColor(CGColor(gray: 0, alpha: 1))
		context.setLineWidth(1.25)
		context.setLineJoin(.round)
		context.strokePath()
	}
}
