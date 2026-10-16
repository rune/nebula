#if DEBUG
import AppKit
import AVFoundation
import NebulaRender

/// Debug builds only: writes a PNG of every visible Nebula window when another process posts
/// the distributed notification `app.nebula.debug.snapshot` with a folder path as its object.
/// Used to check the UI without screen-recording permission:
/// `swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("app.nebula.debug.snapshot"), object: "/tmp/shots", userInfo: nil, deliverImmediately: true)'`
@MainActor
enum DebugSnapshots {
	private static var observer: NSObjectProtocol?

	static func install() {
		observer = DistributedNotificationCenter.default().addObserver(forName: .init("app.nebula.debug.snapshot"), object: nil, queue: .main) { note in
			let folder = note.object as? String ?? NSTemporaryDirectory()
			MainActor.assumeIsolated { capture(to: URL(fileURLWithPath: folder)) }
		}
	}

	static func capture(to folder: URL) {
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try? playerReport().write(to: folder.appending(path: "players.txt"), atomically: true, encoding: .utf8)
		for (index, window) in NSApp.windows.enumerated() where window.isVisible {
			guard let view = window.contentView?.superview ?? window.contentView else { continue }
			let bounds = view.bounds
			guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
			view.cacheDisplay(in: bounds, to: rep)
			// AVPlayerLayer doesn't draw through cacheDisplay; paint the current frame on top.
			drawPlayers(in: view, root: view, into: rep)
			let name = "\(index)-\(window.title.isEmpty ? String(describing: type(of: window)) : window.title).png"
				.replacingOccurrences(of: "/", with: "-")
			try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name))
		}
	}

	/// Describes every player layer: whether it can display, its geometry and item state.
	static func playerReport() -> String {
		var lines: [String] = []
		func visit(_ layer: CALayer, depth: Int) {
			if let player = layer as? AVPlayerLayer {
				let item = player.player?.currentItem
				var chain: [String] = []
				var current: CALayer? = player
				while let l = current {
					chain.append("\(type(of: l)) hidden=\(l.isHidden) opacity=\(l.opacity) frame=\(l.frame) mask=\(l.mask != nil)")
					current = l.superlayer
				}
				lines.append("""
					AVPlayerLayer ready=\(player.isReadyForDisplay) videoRect=\(player.videoRect) gravity=\(player.videoGravity.rawValue)
					player=\(String(describing: player.player)) rate=\(player.player?.rate ?? -1) status=\(player.player?.status.rawValue ?? -1) error=\(String(describing: player.player?.error))
					item status=\(item?.status.rawValue ?? -1) error=\(String(describing: item?.error)) presentationSize=\(item?.presentationSize ?? .zero) composition=\(item?.videoComposition != nil) time=\(item?.currentTime().seconds ?? -1)
					tracks=\(item?.tracks.map { "\($0.assetTrack?.mediaType.rawValue ?? "?") enabled=\($0.isEnabled)" } ?? [])
					errorLog=\(item?.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? [])
					assetDuration=\(item?.asset.duration.seconds ?? -1) instructions=\(item?.videoComposition?.instructions.map { "\($0.timeRange.start.seconds)+\($0.timeRange.duration.seconds)" } ?? []) compositor=\(String(describing: item?.videoComposition?.customVideoCompositorClass)) frameDuration=\(item?.videoComposition?.frameDuration.seconds ?? -1) renderSize=\(item?.videoComposition?.renderSize ?? .zero)
					valid=\(item.flatMap { item in item.videoComposition.map { $0.isValid(for: item.asset, timeRange: CMTimeRange(start: .zero, duration: item.asset.duration), validationDelegate: ValidationLogger.shared) } } ?? false) problems=\(ValidationLogger.shared.problems)
					chain:
					  \(chain.joined(separator: "\n  "))
					""")
			}
			for sub in layer.sublayers ?? [] { visit(sub, depth: depth + 1) }
		}
		for window in NSApp.windows where window.isVisible {
			if let layer = window.contentView?.superview?.layer ?? window.contentView?.layer { visit(layer, depth: 0) }
		}
		lines.append("compositor requests: \(CompositorDiagnostics.counters.withLock { $0 })")
		return lines.joined(separator: "\n\n")
	}

	final class ValidationLogger: NSObject, AVVideoCompositionValidationHandling, @unchecked Sendable {
		static let shared = ValidationLogger()
		var problems: [String] = []

		func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
			problems.append("invalid \(key)")
			return true
		}

		func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
			problems.append("empty range \(timeRange.start.seconds)+\(timeRange.duration.seconds)")
			return true
		}

		func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn videoCompositionInstruction: any AVVideoCompositionInstructionProtocol) -> Bool {
			problems.append("invalid instruction range \(videoCompositionInstruction.timeRange.start.seconds)+\(videoCompositionInstruction.timeRange.duration.seconds)")
			return true
		}

		func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn videoCompositionInstruction: any AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
			problems.append("invalid track id")
			return true
		}
	}

	private static func drawPlayers(in view: NSView, root: NSView, into rep: NSBitmapImageRep) {
		if let layer = view.layer?.sublayers?.first(where: { $0 is AVPlayerLayer }) as? AVPlayerLayer,
		   let item = layer.player?.currentItem,
		   let image = frame(of: item) {
			let rect = view.convert(view.bounds, to: root)
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
			let flipped = root.isFlipped ? NSRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
			let target = AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height), insideRect: flipped)
			NSGraphicsContext.current?.cgContext.draw(image, in: target)
			NSGraphicsContext.restoreGraphicsState()
		}
		for subview in view.subviews { drawPlayers(in: subview, root: root, into: rep) }
	}

	private static func frame(of item: AVPlayerItem) -> CGImage? {
		let generator = AVAssetImageGenerator(asset: item.asset)
		generator.videoComposition = item.videoComposition
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		return try? generator.copyCGImage(at: item.currentTime(), actualTime: nil)
	}
}
#endif
