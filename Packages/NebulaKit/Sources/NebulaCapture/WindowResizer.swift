import ApplicationServices
import CoreGraphics
import Foundation

/// Resizes another app's window to an exact size before recording (needs Accessibility).
public enum WindowResizer {
	public static let presets: [(name: String, size: CGSize)] = [
		("1280 × 720", CGSize(width: 1280, height: 720)),
		("1440 × 900", CGSize(width: 1440, height: 900)),
		("1920 × 1080", CGSize(width: 1920, height: 1080)),
		("1080 × 1080", CGSize(width: 1080, height: 1080)),
		("1080 × 1350", CGSize(width: 1080, height: 1350)),
		("1080 × 1920", CGSize(width: 1080, height: 1920)),
	]

	public enum ResizeError: LocalizedError {
		case needsAccessibility
		case windowNotFound

		public var errorDescription: String? {
			switch self {
			case .needsAccessibility: "Resizing windows needs Accessibility permission (System Settings → Privacy & Security → Accessibility)."
			case .windowNotFound: "Couldn't find that window to resize it."
			}
		}
	}

	/// Resizes the window (sizes in points) and keeps it on screen.
	public static func resize(_ window: WindowInfo, to size: CGSize) throws {
		guard AXIsProcessTrusted() else { throw ResizeError.needsAccessibility }
		let app = AXUIElementCreateApplication(window.pid)
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
			let windows = value as? [AXUIElement] else { throw ResizeError.windowNotFound }
		let match = windows.first { element in
			var position: CFTypeRef?
			guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success, let position else { return false }
			var point = CGPoint.zero
			AXValueGetValue(position as! AXValue, .cgPoint, &point)
			return abs(point.x - window.frame.minX) < 4 && abs(point.y - window.frame.minY) < 4
		} ?? windows.first
		guard let element = match else { throw ResizeError.windowNotFound }
		var newSize = size
		if let sizeValue = AXValueCreate(.cgSize, &newSize) {
			AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
		}
	}
}
