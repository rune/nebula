import AppKit
import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// What to record.
public enum RecordingSource: Hashable, Sendable {
	case display(CGDirectDisplayID)
	case window(CGWindowID)
	/// A rectangle on a display, in that display's points (top-left origin).
	case area(CGDirectDisplayID, CGRect)
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
	public var id: CGDirectDisplayID
	public var name: String
	/// Global frame in points, top-left origin.
	public var frame: CGRect
	public var scale: Double
	public var isMain: Bool
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
	public var id: CGWindowID
	public var title: String
	public var appName: String
	public var bundleID: String?
	/// Global frame in points, top-left origin.
	public var frame: CGRect
	public var pid: pid_t
}

public struct MicrophoneInfo: Identifiable, Hashable, Sendable {
	public var id: String
	public var name: String
}

/// Lists what can be recorded.
public enum CaptureSources {
	public static func displays() async throws -> [DisplayInfo] {
		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
		return content.displays.map { display in
			let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
			return DisplayInfo(
				id: display.displayID,
				name: screen?.localizedName ?? "Display \(display.displayID)",
				frame: CGDisplayBounds(display.displayID),
				scale: Double(screen?.backingScaleFactor ?? 2),
				isMain: CGDisplayIsMain(display.displayID) != 0
			)
		}
		.sorted { $0.isMain && !$1.isMain }
	}

	/// Normal app windows worth recording (no menu bar items, no tiny or invisible windows, not Nebula).
	public static func windows() async throws -> [WindowInfo] {
		let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
		let ownPID = ProcessInfo.processInfo.processIdentifier
		return content.windows.compactMap { window -> WindowInfo? in
			guard window.windowLayer == 0, window.isOnScreen, window.frame.width > 120, window.frame.height > 80,
				let app = window.owningApplication, app.processID != ownPID else { return nil }
			return WindowInfo(
				id: window.windowID,
				title: window.title?.isEmpty == false ? window.title! : app.applicationName,
				appName: app.applicationName,
				bundleID: app.bundleIdentifier,
				frame: window.frame,
				pid: app.processID
			)
		}
	}

	public static func microphones() -> [MicrophoneInfo] {
		AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
			.devices
			.map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName) }
	}

	public static var defaultMicrophone: MicrophoneInfo? {
		AVCaptureDevice.default(for: .audio).map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName) }
	}

	/// A small preview image of a display or window for the source picker.
	public static func thumbnail(for source: RecordingSource, maxWidth: CGFloat = 480) async -> CGImage? {
		guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
		let filter: SCContentFilter
		var frame: CGRect
		switch source {
		case .display(let id), .area(let id, _):
			guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
			filter = SCContentFilter(display: display, excludingWindows: [])
			frame = display.frame
		case .window(let id):
			guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
			filter = SCContentFilter(desktopIndependentWindow: window)
			frame = window.frame
		}
		let config = SCStreamConfiguration()
		let scale = maxWidth / max(frame.width, 1)
		config.width = Int(frame.width * scale)
		config.height = Int(frame.height * scale)
		config.showsCursor = false
		return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
	}
}
