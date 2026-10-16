import AVFoundation
import CoreImage
import Foundation
import os

/// Carries the scene to the custom compositor for a time range of the composition.
final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
	let timeRange: CMTimeRange
	let enablePostProcessing = false
	let containsTweening = true
	let requiredSourceTrackIDs: [NSValue]?
	let passthroughTrackID = kCMPersistentTrackID_Invalid

	let scene: RenderScene
	let quality: RenderQuality
	let videoTrackID: CMPersistentTrackID

	init(timeRange: CMTimeRange, scene: RenderScene, quality: RenderQuality, videoTrackID: CMPersistentTrackID) {
		self.timeRange = timeRange
		self.scene = scene
		self.quality = quality
		self.videoTrackID = videoTrackID
		self.requiredSourceTrackIDs = [NSNumber(value: videoTrackID)]
	}
}

/// Shared GPU context for all Core Image rendering.
public enum RenderContext {
	public static let shared: CIContext = {
		let options: [CIContextOption: Any] = [
			.cacheIntermediates: false,
			.workingFormat: CIFormat.RGBAh,
			.name: "Nebula",
		]
		if let device = MTLCreateSystemDefaultDevice() {
			return CIContext(mtlDevice: device, options: options)
		}
		return CIContext(options: options)
	}()

	static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

/// Request counts, for diagnosing the preview.
public enum CompositorDiagnostics {
	public struct Counts: Sendable {
		public var started = 0, finished = 0, failed = 0, cancelled = 0
	}

	public static let counters = OSAllocatedUnfairLock(initialState: Counts())
}

/// AVFoundation's hook into Nebula's compositor: every frame AVPlayer, AVAssetReader or
/// AVAssetImageGenerator asks for is drawn by `Compositor`.
final class SceneVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
	private static let logger = Logger(subsystem: "app.nebula", category: "render")
	private let queue = DispatchQueue(label: "app.nebula.compositor", qos: .userInteractive, attributes: .concurrent)
	private let lock = OSAllocatedUnfairLock()
	private var cancelled = false

	static var counters: OSAllocatedUnfairLock<CompositorDiagnostics.Counts> { CompositorDiagnostics.counters }

	let sourcePixelBufferAttributes: [String: any Sendable]? = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		kCVPixelBufferMetalCompatibilityKey as String: true,
	]

	/// IOSurface backing is required for AVPlayerLayer to display the frames (readers and image
	/// generators work without it, so missing it only shows up as a blank preview).
	let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		kCVPixelBufferMetalCompatibilityKey as String: true,
		kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
	]

	func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

	func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		Self.counters.withLock { $0.started += 1 }
		lock.lock()
		cancelled = false
		lock.unlock()
		queue.async { [weak self] in
			guard let self else { return }
			self.lock.lock()
			let isCancelled = self.cancelled
			self.lock.unlock()
			if isCancelled {
				Self.counters.withLock { $0.cancelled += 1 }
				request.finishCancelledRequest()
				return
			}
			self.render(request)
		}
	}

	func cancelAllPendingVideoCompositionRequests() {
		lock.lock()
		cancelled = true
		lock.unlock()
		// Let in-flight renders finish; new ones start fresh.
		queue.async(flags: .barrier) { [weak self] in
			self?.lock.lock()
			self?.cancelled = false
			self?.lock.unlock()
		}
	}

	private func render(_ request: AVAsynchronousVideoCompositionRequest) {
		guard let instruction = request.videoCompositionInstruction as? SceneInstruction,
			let source = request.sourceFrame(byTrackID: instruction.videoTrackID),
			let output = request.renderContext.newPixelBuffer()
		else {
			Self.counters.withLock { $0.failed += 1 }
			Self.logger.error("Compositor couldn't get a source frame or output buffer at \(request.compositionTime.seconds, privacy: .public)s")
			request.finish(with: NSError(domain: "Nebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing frame"]))
			return
		}
		let canvas = request.renderContext.size
		let frame = Compositor.shared.compose(
			source: CIImage(cvPixelBuffer: source),
			outputTime: request.compositionTime.seconds,
			scene: instruction.scene,
			canvas: canvas,
			quality: instruction.quality
		)
		RenderContext.shared.render(frame, to: output, bounds: CGRect(origin: .zero, size: canvas), colorSpace: RenderContext.outputColorSpace)
		request.finish(withComposedVideoFrame: output)
		Self.counters.withLock { $0.finished += 1 }
	}
}
