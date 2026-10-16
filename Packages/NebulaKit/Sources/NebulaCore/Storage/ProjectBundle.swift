import Foundation

/// A project on disk: a `.nebula` folder holding the edits and the media.
///
/// ```
/// Demo.nebula/
///   project.json      edits (Project)
///   input.json        cursor, clicks, keys (InputTrack)
///   recording.mov     video + system audio
///   microphone.mov    microphone audio (if recorded)
///   thumbnail.jpg
///   media/            imported music, images, denoised audio
/// ```
public struct ProjectBundle: Sendable, Hashable {
	public static let fileExtension = "nebula"
	public static let videoFileName = "recording.mov"
	public static let microphoneFileName = "microphone.mov"
	static let projectFileName = "project.json"
	static let inputFileName = "input.json"
	public static let thumbnailFileName = "thumbnail.jpg"
	public static let mediaFolderName = "media"

	public let url: URL

	public init(url: URL) {
		self.url = url
	}

	public var projectURL: URL { url.appending(path: Self.projectFileName) }
	public var inputURL: URL { url.appending(path: Self.inputFileName) }
	public var thumbnailURL: URL { url.appending(path: Self.thumbnailFileName) }
	public var mediaURL: URL { url.appending(path: Self.mediaFolderName, directoryHint: .isDirectory) }

	public func videoURL(for project: Project) -> URL { url.appending(path: project.media.videoFile) }

	public func microphoneURL(for project: Project) -> URL? {
		project.media.microphoneFile.map { url.appending(path: $0) }
	}

	/// Denoised microphone audio, written when noise reduction is turned on.
	public var denoisedMicrophoneURL: URL { mediaURL.appending(path: "microphone-denoised.m4a") }

	public var name: String { url.deletingPathExtension().lastPathComponent }

	// MARK: Reading and writing

	public func readProject() throws -> Project {
		do {
			let data = try Data(contentsOf: projectURL)
			let project = try Self.decoder.decode(Project.self, from: data)
			guard project.formatVersion <= Project.currentFormatVersion else {
				throw ProjectBundleError.newerFormat(project.formatVersion)
			}
			return project
		} catch let error as ProjectBundleError {
			throw error
		} catch {
			throw ProjectBundleError.unreadable(url, error.localizedDescription)
		}
	}

	public func readInput() -> InputTrack {
		guard let data = try? Data(contentsOf: inputURL) else { return .empty }
		return (try? Self.decoder.decode(InputTrack.self, from: data)) ?? .empty
	}

	public func write(_ project: Project) throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		try Self.encoder.encode(project).write(to: projectURL, options: .atomic)
	}

	public func write(_ input: InputTrack) throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		try Self.encoder.encode(input).write(to: inputURL, options: .atomic)
	}

	/// Copies a file into `media/`, returning the stored file name (deduplicated).
	public func importMedia(from source: URL) throws -> String {
		try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
		var name = source.lastPathComponent
		var counter = 1
		while FileManager.default.fileExists(atPath: mediaURL.appending(path: name).path) {
			name = "\(source.deletingPathExtension().lastPathComponent)-\(counter).\(source.pathExtension)"
			counter += 1
		}
		try FileManager.default.copyItem(at: source, to: mediaURL.appending(path: name))
		return name
	}

	public static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}()

	public static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()
}

public enum ProjectBundleError: LocalizedError, Equatable {
	case unreadable(URL, String)
	case newerFormat(Int)

	public var errorDescription: String? {
		switch self {
		case .unreadable(let url, let reason):
			"Couldn't open \(url.lastPathComponent): \(reason)"
		case .newerFormat(let version):
			"This project was made with a newer version of Nebula (format \(version)). Update Nebula to open it."
		}
	}
}
