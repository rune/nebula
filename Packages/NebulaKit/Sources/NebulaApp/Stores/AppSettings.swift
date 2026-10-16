import Foundation
import NebulaCore
import NebulaPolish
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
public final class AppSettings {
	public enum RecordingPermission: String, CaseIterable, Sendable {
		case ask, always, never

		public var title: String {
			switch self {
			case .ask: "Ask each time"
			case .always: "Always allow"
			case .never: "Never"
			}
		}
	}

	@ObservationIgnored private let defaults: UserDefaults

	public var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: "mcpEnabled") } }
	public var mcpPort: Int { didSet { defaults.set(mcpPort, forKey: "mcpPort") } }
	public var mcpRecording: RecordingPermission { didSet { defaults.set(mcpRecording.rawValue, forKey: "mcpRecording") } }
	public var countdown: Int { didSet { defaults.set(countdown, forKey: "countdown") } }
	public var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }
	public var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: "systemAudio") } }
	public var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
	public var frameRate: Int { didSet { defaults.set(frameRate, forKey: "frameRate") } }
	public var speakerNotes: Bool { didSet { defaults.set(speakerNotes, forKey: "speakerNotes") } }
	public var notesText: String { didSet { defaults.set(notesText, forKey: "notesText") } }
	public var defaultPresetID: UUID? { didSet { defaults.set(defaultPresetID?.uuidString, forKey: "defaultPresetID") } }
	public var polishOptions: PolishOptions { didSet { defaults.set(try? JSONEncoder().encode(polishOptions), forKey: "polishOptions") } }

	public init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		mcpEnabled = defaults.object(forKey: "mcpEnabled") as? Bool ?? true
		mcpPort = defaults.object(forKey: "mcpPort") as? Int ?? 39351
		mcpRecording = RecordingPermission(rawValue: defaults.string(forKey: "mcpRecording") ?? "") ?? .ask
		countdown = defaults.object(forKey: "countdown") as? Int ?? 3
		hideDesktopIcons = defaults.object(forKey: "hideDesktopIcons") as? Bool ?? true
		systemAudio = defaults.object(forKey: "systemAudio") as? Bool ?? true
		microphoneID = defaults.string(forKey: "microphoneID")
		frameRate = defaults.object(forKey: "frameRate") as? Int ?? 60
		speakerNotes = defaults.object(forKey: "speakerNotes") as? Bool ?? false
		notesText = defaults.string(forKey: "notesText") ?? ""
		defaultPresetID = defaults.string(forKey: "defaultPresetID").flatMap(UUID.init(uuidString:))
		polishOptions = defaults.data(forKey: "polishOptions").flatMap { try? JSONDecoder().decode(PolishOptions.self, from: $0) } ?? PolishOptions()
	}
}
