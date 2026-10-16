import AVFoundation
import Foundation
import NebulaCore

/// Reads duration, pixel size and frame rate from recorded media.
public enum MediaProbe {
	public enum ProbeError: LocalizedError {
		case noVideo(URL)

		public var errorDescription: String? {
			switch self {
			case .noVideo(let url): "\(url.lastPathComponent) has no video track."
			}
		}
	}

	public static func mediaInfo(video: URL, videoFileName: String, microphone: URL?, microphoneFileName: String?) async throws -> MediaInfo {
		let asset = AVURLAsset(url: video)
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProbeError.noVideo(video) }
		let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
		let size = naturalSize.applying(transform)
		let duration = try await asset.load(.duration).seconds
		let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
		return MediaInfo(
			videoFile: videoFileName,
			microphoneFile: microphone == nil ? nil : microphoneFileName,
			duration: duration.isFinite ? duration : 0,
			width: Int(abs(size.width).rounded()),
			height: Int(abs(size.height).rounded()),
			frameRate: frameRate > 0 ? Double(frameRate) : 60,
			hasSystemAudio: hasAudio
		)
	}
}
