import AVFoundation
import CoreImage
import Foundation
import ImageIO
import NebulaPolish
import UniformTypeIdentifiers

/// Single frames: the edited result at an output time, or the raw recording at a source time.
public enum FrameGrabber {
	/// The rendered output frame (what export would produce) at an output time.
	public static func renderedFrame(_ playable: PlayableComposition, at outputTime: Double) async throws -> CGImage {
		let generator = AVAssetImageGenerator(asset: playable.asset)
		generator.videoComposition = playable.videoComposition
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let time = CMTime(seconds: max(0, min(outputTime, playable.scene.outputDuration - 0.001)), preferredTimescale: 60_000)
		return try await generator.image(at: time).image
	}

	/// A raw frame of the recording at a source time, scaled down to `maxWidth`.
	public static func sourceFrame(video: URL, at sourceTime: Double, maxWidth: CGFloat) async throws -> CGImage {
		let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
		generator.appliesPreferredTrackTransform = true
		return try await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 60_000)).image
	}

	public static func jpegData(_ image: CGImage, quality: Double = 0.85, maxWidth: Int? = nil) -> Data? {
		var image = image
		if let maxWidth, image.width > maxWidth {
			let scale = CGFloat(maxWidth) / CGFloat(image.width)
			let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
			if let scaled = RenderContext.shared.createCGImage(ci, from: ci.extent) { image = scaled }
		}
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	public static func pngData(_ image: CGImage) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, nil)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}
}

/// GIF export through the same compositor.
public enum GIFExporter {
	public enum GIFError: LocalizedError {
		case cannotCreate

		public var errorDescription: String? { "Couldn't create the GIF file." }
	}

	public static func export(_ playable: PlayableComposition, fps: Int, loop: Bool, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
		try? FileManager.default.removeItem(at: url)
		let duration = playable.scene.outputDuration
		let count = max(1, Int(duration * Double(fps)))
		guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
			throw GIFError.cannotCreate
		}
		CGImageDestinationSetProperties(destination, [
			kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1],
		] as CFDictionary)
		let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary

		let generator = AVAssetImageGenerator(asset: playable.asset)
		generator.videoComposition = playable.videoComposition
		generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
		generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
		let times = (0..<count).map { CMTime(seconds: Double($0) / Double(fps), preferredTimescale: 60_000) }
		var done = 0
		for await result in generator.images(for: times) {
			try Task.checkCancellation()
			if let image = try? result.image {
				CGImageDestinationAddImage(destination, image, frameProperties)
			}
			done += 1
			progress(Double(done) / Double(count))
		}
		guard CGImageDestinationFinalize(destination) else { throw GIFError.cannotCreate }
	}
}

/// How much the picture changes over time, for Polish's dead-air detection.
public enum FrameActivityAnalyzer {
	public static func analyze(video: URL, interval: Double = 0.25) async throws -> ActivitySeries {
		let asset = AVURLAsset(url: video)
		let duration = try await asset.load(.duration).seconds
		guard duration.isFinite, duration > 0 else { return ActivitySeries(interval: interval, values: []) }
		let generator = AVAssetImageGenerator(asset: asset)
		generator.maximumSize = CGSize(width: 160, height: 160)
		generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
		generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)
		let count = Int(duration / interval)
		let times = (0..<count).map { CMTime(seconds: Double($0) * interval, preferredTimescale: 600) }
		var values: [Float] = []
		var previous: [UInt8]?
		for await result in generator.images(for: times) {
			guard let image = try? result.image, let pixels = grayscale(image) else {
				values.append(values.last ?? 0)
				continue
			}
			if let previous, previous.count == pixels.count {
				var total = 0
				for i in 0..<pixels.count { total += abs(Int(pixels[i]) - Int(previous[i])) }
				values.append(Float(total) / Float(pixels.count * 255))
			} else {
				values.append(0)
			}
			previous = pixels
		}
		return ActivitySeries(interval: interval, values: values)
	}

	static func grayscale(_ image: CGImage) -> [UInt8]? {
		let width = 96
		let height = max(1, Int(Double(width) * Double(image.height) / Double(max(image.width, 1))))
		var pixels = [UInt8](repeating: 0, count: width * height)
		let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = CGContext(
				data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
				space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
			) else { return false }
			context.interpolationQuality = .low
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			return true
		}
		return drawn ? pixels : nil
	}
}

/// Library thumbnails.
public enum Thumbnailer {
	public static func writeThumbnail(video: URL, to url: URL, at time: Double = 1) async throws {
		let image = try await FrameGrabber.sourceFrame(video: video, at: time, maxWidth: 960)
		if let data = FrameGrabber.jpegData(image, quality: 0.8) {
			try data.write(to: url, options: .atomic)
		}
	}
}
