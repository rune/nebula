#if DEBUG
import AppKit
import AVFoundation

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
