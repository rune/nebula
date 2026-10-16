import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import NebulaCore

/// Draws the canvas background at the exact output size and caches it (one per size + style).
public final class BackgroundRenderer: Sendable {
	private struct Key: Hashable, Sendable {
		var background: Background
		var blur: Double
		var width: Int
		var height: Int
		var bundlePath: String
	}

	private let cache = RenderCache<Key, CIImage>(limit: 8)

	public init() {}

	/// Background image covering `size`. `bundleURL` resolves relative image paths.
	public func image(for background: Background, blur: Double, size: CGSize, bundleURL: URL?) -> CIImage {
		let key = Key(background: background, blur: blur, width: Int(size.width), height: Int(size.height), bundlePath: bundleURL?.path ?? "")
		return cache.value(for: key) {
			Self.render(background, blur: blur, size: size, bundleURL: bundleURL)
		} ?? CIImage(color: CIColor.black).cropped(to: CGRect(origin: .zero, size: size))
	}

	static func render(_ background: Background, blur: Double, size: CGSize, bundleURL: URL?) -> CIImage {
		let rect = CGRect(origin: .zero, size: size)
		var image: CIImage
		switch background {
		case .color(let color):
			return CIImage(color: color.ciColor).cropped(to: rect)
		case .gradient(let fill):
			image = drawGradient(fill, size: size) ?? CIImage(color: .black).cropped(to: rect)
		case .image(let path):
			let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : bundleURL?.appending(path: path)
			// A missing image (e.g. a recording made without a desktop capture) falls back to near-black.
			image = url.flatMap { aspectFill(url: $0, size: size) }
				?? CIImage(color: CIColor(red: 0.043, green: 0.043, blue: 0.059)).cropped(to: rect)
		}
		if blur > 0.001 {
			let radius = blur * Double(min(size.width, size.height)) * 0.04
			image = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: rect)
		}
		return image
	}

	static func drawGradient(_ fill: GradientFill, size: CGSize) -> CIImage? {
		let colors = (fill.colors.isEmpty ? [.violet, .black] : fill.colors).map(\.cgColor) as CFArray
		guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return nil }
		let drawn = TextArtwork.draw(size: size) { context in
			let angle = fill.angle * .pi / 180
			let center = CGPoint(x: size.width / 2, y: size.height / 2)
			let reach = (abs(cos(angle)) * size.width + abs(sin(angle)) * size.height) / 2
			let dx = cos(angle) * reach
			let dy = -sin(angle) * reach
			context.drawLinearGradient(
				gradient,
				start: CGPoint(x: center.x - dx, y: center.y - dy),
				end: CGPoint(x: center.x + dx, y: center.y + dy),
				options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
			)
		}
		return drawn.map { addGrain(to: $0.image, size: size) }
	}

	static func aspectFill(url: URL, size: CGSize) -> CIImage? {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 1.2),
			kCGImageSourceCreateThumbnailWithTransform: true,
		]
		guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
		let image = CIImage(cgImage: cg)
		let scale = max(size.width / image.extent.width, size.height / image.extent.height)
		let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		let dx = (scaled.extent.width - size.width) / 2
		let dy = (scaled.extent.height - size.height) / 2
		return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: CGRect(origin: .zero, size: size))
	}

	private static func addGrain(to image: CIImage, size: CGSize) -> CIImage {
		let rect = CGRect(origin: .zero, size: size)
		let noise = CIFilter.randomGenerator().outputImage?
			.cropped(to: rect)
			.applyingFilter("CIColorMatrix", parameters: [
				"inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
				"inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
				"inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
				"inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.035),
				"inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
			])
		guard let noise else { return image }
		return noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: rect)
	}
}
