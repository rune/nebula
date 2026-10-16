import Foundation
import NebulaCore
import Observation

/// Built-in and saved style presets (`~/Library/Application Support/Nebula/presets.json`).
@MainActor
@Observable
public final class PresetStore {
	public private(set) var custom: [StylePreset] = []
	@ObservationIgnored private let fileURL: URL

	public init(folder: URL = AppPaths.support) {
		fileURL = folder.appending(path: "presets.json")
		if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([StylePreset].self, from: data) {
			custom = decoded
		}
	}

	public var all: [StylePreset] { StylePreset.builtIn + custom }

	public func preset(id: UUID?) -> StylePreset? {
		id.flatMap { id in all.first { $0.id == id } }
	}

	public func save(_ preset: StylePreset) {
		if let index = custom.firstIndex(where: { $0.id == preset.id }) {
			custom[index] = preset
		} else {
			custom.append(preset)
		}
		persist()
	}

	public func delete(_ preset: StylePreset) {
		custom.removeAll { $0.id == preset.id }
		persist()
	}

	private func persist() {
		try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? JSONEncoder().encode(custom).write(to: fileURL, options: .atomic)
	}
}

public enum AppPaths {
	public static var support: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
		return base.appending(path: "Nebula", directoryHint: .isDirectory)
	}

	public static var models: URL { support.appending(path: "Models", directoryHint: .isDirectory) }

	public static var exports: URL {
		let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
			?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies")
		return movies.appending(path: "Nebula Exports", directoryHint: .isDirectory)
	}
}
