import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// The three macOS permissions Nebula uses.
public enum Permissions {
	public enum Status: Sendable, Equatable {
		case granted
		case denied
		case notDetermined
	}

	/// Screen Recording. Required to record.
	public static var screenRecording: Status {
		CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
	}

	/// Shows the system prompt the first time; afterwards the user must use System Settings.
	@discardableResult
	public static func requestScreenRecording() -> Bool {
		CGRequestScreenCaptureAccess()
	}

	public static var microphone: Status {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized: .granted
		case .notDetermined: .notDetermined
		default: .denied
		}
	}

	public static func requestMicrophone() async -> Bool {
		await AVCaptureDevice.requestAccess(for: .audio)
	}

	/// Accessibility lets Nebula see key presses and the focused text field, used for the
	/// shortcut overlay and for zooming in on typing. Recording works without it.
	public static var accessibility: Status {
		AXIsProcessTrusted() ? .granted : .notDetermined
	}

	public static func requestAccessibility() {
		// The value of kAXTrustedCheckOptionPrompt; the global itself isn't concurrency-safe to read.
		let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
		_ = AXIsProcessTrustedWithOptions(options)
	}

	public static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
	public static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
	public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
