import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import NebulaCore
import os
@preconcurrency import ScreenCaptureKit

public struct RecordingOptions: Sendable, Hashable {
	public var source: RecordingSource
	/// `AVCaptureDevice.uniqueID` of the microphone, or nil for no microphone.
	public var microphoneID: String?
	public var systemAudio: Bool
	public var hideDesktopIcons: Bool
	public var frameRate: Int

	public init(source: RecordingSource, microphoneID: String?, systemAudio: Bool, hideDesktopIcons: Bool, frameRate: Int = 60) {
		self.source = source
		self.microphoneID = microphoneID
		self.systemAudio = systemAudio
		self.hideDesktopIcons = hideDesktopIcons
		self.frameRate = frameRate
	}
}

public struct RecordingResult: Sendable {
	public var videoURL: URL
	public var microphoneURL: URL?
	public var duration: Double
	public var pixelSize: CGSize
	public var input: InputTrack
	/// For window/area recordings: the screen and where the recording sat on it.
	public var screen: ScreenGeometry?
	/// JPEG of the desktop wallpaper (no icons, no windows) captured when recording started.
	public var desktopJPEG: Data?
}

public enum RecorderError: LocalizedError {
	case permissionDenied
	case sourceUnavailable
	case alreadyRecording
	case notRecording
	case streamFailed(String)

	public var errorDescription: String? {
		switch self {
		case .permissionDenied: "Nebula needs Screen Recording permission. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
		case .sourceUnavailable: "That display or window is no longer available."
		case .alreadyRecording: "A recording is already in progress."
		case .notRecording: "Nothing is being recorded."
		case .streamFailed(let reason): "Recording stopped unexpectedly: \(reason)"
		}
	}
}

/// Records the screen at native resolution with ScreenCaptureKit: video (+ system audio) to one
/// file, microphone to another, cursor and input to an `InputTrack`. The cursor is not baked in.
public final class ScreenRecorder: NSObject, @unchecked Sendable {
	public enum State: Sendable, Equatable {
		case idle
		case recording
		case paused
	}

	private static let logger = Logger(subsystem: "app.nebula", category: "capture")
	private let queue = DispatchQueue(label: "app.nebula.capture.samples", qos: .userInteractive)
	private let lock = OSAllocatedUnfairLock()

	private var stream: SCStream?
	private var videoWriter: FragmentedWriter?
	private var micWriter: FragmentedWriter?
	private var inputMonitor: InputMonitor?
	private var videoURL: URL?
	private var micURL: URL?
	private var pixelSize: CGSize = .zero
	private var screen: ScreenGeometry?
	private var desktopJPEG: Data?

	// Timing (host clock). Guarded by `lock`.
	private var startTime: CMTime = .invalid
	private var pausedAt: CMTime?
	private var pausedTotal: CMTime = .zero
	private var _state: State = .idle
	private var failure: Error?

	/// Called on the main actor when the stream dies on its own (display unplugged, permission revoked).
	public var onFailure: (@MainActor @Sendable (Error) -> Void)?

	public override init() {}

	public var state: State { lock.withLockUnchecked { _state } }

	/// Seconds recorded so far, excluding pauses.
	public var elapsed: Double {
		lock.withLockUnchecked {
			guard startTime.isValid else { return 0 }
			let now = pausedAt ?? CMClockGetTime(CMClockGetHostTimeClock())
			return max(0, (now - startTime - pausedTotal).seconds)
		}
	}

	// MARK: - Control

	@MainActor
	public func start(options: RecordingOptions, videoURL: URL, microphoneURL: URL) async throws {
		guard state == .idle else { throw RecorderError.alreadyRecording }
		guard Permissions.screenRecording == .granted || Permissions.requestScreenRecording() else { throw RecorderError.permissionDenied }

		let content: SCShareableContent
		do {
			content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
		} catch {
			throw RecorderError.permissionDenied
		}
		let (filter, captureRect) = try makeFilter(options: options, content: content)
		let display = displayContaining(captureRect, options: options, content: content)
		desktopJPEG = await Self.captureWallpaper(display: display, content: content)
		screen = nil
		if case .display = options.source {
			// A full-display recording is the whole screen; no geometry needed.
		} else if let display {
			let bounds = CGDisplayBounds(display.displayID)
			let scaleFactor = Double(SCShareableContent.info(for: SCContentFilter(display: display, excludingWindows: [])).pointPixelScale)
			screen = ScreenGeometry(
				width: Int(bounds.width * scaleFactor),
				height: Int(bounds.height * scaleFactor),
				captureRect: NormRect(
					x: (captureRect.minX - bounds.minX) / bounds.width,
					y: (captureRect.minY - bounds.minY) / bounds.height,
					width: captureRect.width / bounds.width,
					height: captureRect.height / bounds.height
				)
			)
		}
		let info = SCShareableContent.info(for: filter)
		let scale = Double(info.pointPixelScale)
		let pointSize = captureRect.size
		let width = Int((pointSize.width * scale / 2).rounded()) * 2
		let height = Int((pointSize.height * scale / 2).rounded()) * 2
		pixelSize = CGSize(width: width, height: height)

		let config = SCStreamConfiguration()
		config.width = width
		config.height = height
		config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
		config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		config.colorSpaceName = CGColorSpace.sRGB
		config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
		config.showsCursor = false
		config.queueDepth = 8
		config.capturesAudio = options.systemAudio
		config.excludesCurrentProcessAudio = true
		config.sampleRate = 48_000
		config.channelCount = 2
		if case .area(_, let rect) = options.source {
			config.sourceRect = rect
		}
		if let mic = options.microphoneID {
			config.captureMicrophone = true
			config.microphoneCaptureDeviceID = mic
		}

		// Screen recordings are mostly static, so ~0.08 bits per pixel per frame keeps text sharp.
		let bitrate = Int(Double(width * height * options.frameRate) * 0.08)
		videoWriter = try FragmentedWriter(
			url: videoURL,
			video: .init(width: width, height: height, fps: options.frameRate, bitrate: min(bitrate, 120_000_000)),
			audioChannels: options.systemAudio ? 2 : nil
		)
		micWriter = options.microphoneID == nil ? nil : try FragmentedWriter(url: microphoneURL, video: nil, audioChannels: 1)
		self.videoURL = videoURL
		self.micURL = options.microphoneID == nil ? nil : microphoneURL

		let stream = SCStream(filter: filter, configuration: config, delegate: self)
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
		if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
		if options.microphoneID != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }

		let monitor = InputMonitor(captureRect: captureRect, scale: scale)
		inputMonitor = monitor
		lock.withLockUnchecked {
			startTime = .invalid
			pausedAt = nil
			pausedTotal = .zero
			failure = nil
			_state = .recording
		}
		do {
			try await stream.startCapture()
		} catch {
			lock.withLockUnchecked { _state = .idle }
			videoWriter?.cancel()
			micWriter?.cancel()
			throw RecorderError.streamFailed(error.localizedDescription)
		}
		self.stream = stream
		monitor.start()
		Self.logger.info("Recording \(width)x\(height) @ \(options.frameRate) fps")
	}

	@MainActor
	public func pause() {
		lock.withLockUnchecked {
			guard _state == .recording else { return }
			pausedAt = CMClockGetTime(CMClockGetHostTimeClock())
			_state = .paused
		}
		inputMonitor?.pause()
	}

	@MainActor
	public func resume() {
		lock.withLockUnchecked {
			guard _state == .paused, let pausedAt else { return }
			pausedTotal = pausedTotal + (CMClockGetTime(CMClockGetHostTimeClock()) - pausedAt)
			self.pausedAt = nil
			_state = .recording
		}
		inputMonitor?.resume()
	}

	@MainActor
	public func stop() async throws -> RecordingResult {
		guard state != .idle, let videoURL else { throw RecorderError.notRecording }
		let end = lock.withLockUnchecked { () -> CMTime in
			if let pausedAt { pausedTotal = pausedTotal + (CMClockGetTime(CMClockGetHostTimeClock()) - pausedAt) }
			pausedAt = nil
			_state = .idle
			guard startTime.isValid else { return .zero }
			return CMClockGetTime(CMClockGetHostTimeClock()) - startTime - pausedTotal
		}
		try? await stream?.stopCapture()
		stream = nil
		var input = inputMonitor?.stop() ?? .empty
		inputMonitor = nil
		await videoWriter?.finish(at: end)
		await micWriter?.finish(at: end)
		videoWriter = nil
		micWriter = nil
		let duration = end.seconds
		input.cursor = input.cursor.filter { $0.t <= duration }
		return RecordingResult(
			videoURL: videoURL,
			microphoneURL: micURL,
			duration: duration,
			pixelSize: pixelSize,
			input: input,
			screen: screen,
			desktopJPEG: desktopJPEG
		)
	}

	/// Stops and throws the files away.
	@MainActor
	public func cancel() async {
		lock.withLockUnchecked { _state = .idle }
		try? await stream?.stopCapture()
		stream = nil
		_ = inputMonitor?.stop()
		inputMonitor = nil
		videoWriter?.cancel()
		micWriter?.cancel()
		videoWriter = nil
		micWriter = nil
		if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
		if let micURL { try? FileManager.default.removeItem(at: micURL) }
	}

	// MARK: - Filter

	private func makeFilter(options: RecordingOptions, content: SCShareableContent) throws -> (SCContentFilter, CGRect) {
		let ownPID = ProcessInfo.processInfo.processIdentifier
		let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
		let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
		let desktopIcons = options.hideDesktopIcons
			? content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == desktopIconLevel }
			: []

		switch options.source {
		case .display(let id):
			guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.sourceUnavailable }
			return (SCContentFilter(display: display, excludingWindows: ownWindows + desktopIcons), CGDisplayBounds(id))
		case .area(let id, let rect):
			guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.sourceUnavailable }
			let bounds = CGDisplayBounds(id)
			return (
				SCContentFilter(display: display, excludingWindows: ownWindows + desktopIcons),
				CGRect(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY, width: rect.width, height: rect.height)
			)
		case .window(let id):
			guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.sourceUnavailable }
			return (SCContentFilter(desktopIndependentWindow: window), window.frame)
		}
	}

	/// The display a recording happens on.
	private func displayContaining(_ rect: CGRect, options: RecordingOptions, content: SCShareableContent) -> SCDisplay? {
		switch options.source {
		case .display(let id), .area(let id, _):
			return content.displays.first { $0.displayID == id }
		case .window:
			let center = CGPoint(x: rect.midX, y: rect.midY)
			return content.displays.first { CGDisplayBounds($0.displayID).contains(center) } ?? content.displays.first
		}
	}

	/// The desktop picture as macOS draws it (dynamic wallpapers included), without icons or windows.
	private static func captureWallpaper(display: SCDisplay?, content: SCShareableContent) async -> Data? {
		guard let display else { return nil }
		let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
		let wallpaper = content.windows.filter { window in
			window.windowLayer == desktopLevel
				|| (window.owningApplication?.bundleIdentifier == "com.apple.dock" && (window.title ?? "").hasPrefix("Wallpaper"))
		}
		guard !wallpaper.isEmpty else { return nil }
		let filter = SCContentFilter(display: display, including: wallpaper)
		let config = SCStreamConfiguration()
		let scale = SCShareableContent.info(for: filter).pointPixelScale
		config.width = Int(display.frame.width * CGFloat(scale))
		config.height = Int(display.frame.height * CGFloat(scale))
		config.showsCursor = false
		guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	// MARK: - Samples

	fileprivate func handle(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
		guard sample.isValid else { return }
		let pts = sample.presentationTimeStamp
		switch type {
		case .screen:
			guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
				let statusValue = attachments.first?[.status] as? Int,
				SCFrameStatus(rawValue: statusValue) == .complete else { return }
			guard let time = relativeTime(for: pts, isVideo: true) else { return }
			if let writer = videoWriter, !writer.started {
				writer.start(at: .zero)
				micWriter?.start(at: .zero)
			}
			videoWriter?.appendVideo(sample, at: time)
		case .audio:
			guard let time = relativeTime(for: pts, isVideo: false) else { return }
			videoWriter?.appendAudio(sample, at: time)
		case .microphone:
			guard let time = relativeTime(for: pts, isVideo: false) else { return }
			micWriter?.appendAudio(sample, at: time)
		@unknown default:
			break
		}
	}

	/// Time since the start of recording minus pauses, or nil if the sample should be dropped.
	private func relativeTime(for pts: CMTime, isVideo: Bool) -> CMTime? {
		lock.withLockUnchecked {
			guard _state == .recording else { return nil }
			if !startTime.isValid {
				guard isVideo else { return nil }
				startTime = pts
				inputMonitor?.setStart(uptime: pts.seconds)
			}
			let time = pts - startTime - pausedTotal
			return time >= .zero ? time : nil
		}
	}
}

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate {
	public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
		handle(sampleBuffer, type: type)
	}

	public func stream(_ stream: SCStream, didStopWithError error: Error) {
		Self.logger.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
		lock.withLockUnchecked { failure = error }
		let handler = onFailure
		Task { @MainActor in handler?(RecorderError.streamFailed(error.localizedDescription)) }
	}
}
