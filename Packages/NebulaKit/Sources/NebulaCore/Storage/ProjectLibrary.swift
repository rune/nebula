import Foundation

/// The folder where Nebula keeps projects (`~/Movies/Nebula` by default).
public struct ProjectLibrary: Sendable {
	public struct Entry: Sendable, Hashable, Identifiable {
		public var id: URL { bundle.url }
		public var bundle: ProjectBundle
		public var name: String
		public var createdAt: Date
		public var modifiedAt: Date
		public var duration: Double
		public var width: Int
		public var height: Int
	}

	public let rootURL: URL

	public init(rootURL: URL = ProjectLibrary.defaultRoot) {
		self.rootURL = rootURL
	}

	/// `~/Movies/Nebula`, or `NEBULA_LIBRARY` when set (used to run against a separate library,
	/// e.g. for demo captures).
	public static var defaultRoot: URL {
		if let custom = ProcessInfo.processInfo.environment["NEBULA_LIBRARY"], !custom.isEmpty {
			return URL(fileURLWithPath: custom, isDirectory: true)
		}
		let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
			?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies")
		return movies.appending(path: "Nebula", directoryHint: .isDirectory)
	}

	/// Projects sorted newest first. Unreadable bundles are skipped.
	public func entries() -> [Entry] {
		let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
		let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: keys)) ?? []
		return urls
			.filter { $0.pathExtension == ProjectBundle.fileExtension }
			.compactMap { url -> Entry? in
				let bundle = ProjectBundle(url: url)
				guard let project = try? bundle.readProject() else { return nil }
				let modified = (try? bundle.projectURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
				return Entry(
					bundle: bundle,
					name: project.name,
					createdAt: project.createdAt,
					modifiedAt: modified ?? project.createdAt,
					duration: project.timeMap.outputDuration,
					width: project.media.width,
					height: project.media.height
				)
			}
			.sorted { $0.modifiedAt > $1.modifiedAt }
	}

	/// A new, unused bundle location such as `Recording 2026-10-16 at 19.42.nebula`.
	public func newBundle(named base: String? = nil, date: Date = Date()) throws -> ProjectBundle {
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
		let stem = base ?? "Recording \(formatter.string(from: date))"
		var url = rootURL.appending(path: "\(stem).\(ProjectBundle.fileExtension)", directoryHint: .isDirectory)
		var counter = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = rootURL.appending(path: "\(stem) \(counter).\(ProjectBundle.fileExtension)", directoryHint: .isDirectory)
			counter += 1
		}
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return ProjectBundle(url: url)
	}

	public func moveToTrash(_ bundle: ProjectBundle) throws {
		try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
	}
}
