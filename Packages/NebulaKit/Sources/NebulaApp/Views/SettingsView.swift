import AppKit
import NebulaCapture
import NebulaCore
import NebulaDesign
import SwiftUI

/// Nebula ▸ Settings.
public struct SettingsView: View {
	@Environment(AppModel.self) private var app
	@State private var tab: Tab = .recording

	enum Tab: String, CaseIterable {
		case recording = "Recording"
		case claude = "Claude"
		case permissions = "Permissions"
		case about = "About"

		var symbol: String {
			switch self {
			case .recording: "record.circle"
			case .claude: "sparkles"
			case .permissions: "lock.shield"
			case .about: "info.circle"
			}
		}
	}

	public init() {}

	public var body: some View {
		HStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Tab.allCases, id: \.self) { item in
					HStack(spacing: 10) {
						Image(systemName: item.symbol).frame(width: 16)
						Text(item.rawValue).font(.nebula(13, 650))
						Spacer()
					}
					.foregroundStyle(tab == item ? Theme.text1 : Theme.text2)
					.padding(.horizontal, 10)
					.frame(height: 32)
					.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(tab == item ? Theme.surface3 : .clear))
					.contentShape(Rectangle())
					.onTapGesture { tab = item }
				}
				Spacer()
			}
			.padding(12)
			.padding(.top, 40)
			.frame(width: 180)
			.background(Theme.surface1)
			Rectangle().fill(Theme.hairline).frame(width: 1)
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					switch tab {
					case .recording: RecordingSettings()
					case .claude: ClaudeSettings()
					case .permissions: PermissionSettings()
					case .about: AboutView()
					}
				}
				.padding(26)
				.padding(.top, 14)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.background(Theme.window)
		}
		.frame(width: 680, height: 500)
		.onDebugCommand { command in
			if command.hasPrefix("settings:"), let value = Tab(rawValue: String(command.dropFirst(9)).capitalized) { tab = value }
		}
		.environment(\.colorScheme, .dark)
		.ignoresSafeArea(.container, edges: .top)
		.background(WindowAccessor { window in
			window.titlebarAppearsTransparent = true
			window.titleVisibility = .hidden
			window.styleMask.insert(.fullSizeContentView)
			window.backgroundColor = NSColor(Theme.window)
		})
	}
}

private struct RecordingSettings: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		@Bindable var settings = app.settings
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "Recording") {
				InspectorRow(title: "Countdown") {
					SegmentedPicker(selection: $settings.countdown, options: [(0, "Off"), (3, "3 s"), (5, "5 s")]).frame(width: 180)
				}
				InspectorRow(title: "Frame rate") {
					SegmentedPicker(selection: $settings.frameRate, options: [(30, "30 fps"), (60, "60 fps")]).frame(width: 180)
				}
				InspectorToggle("Record system audio", isOn: $settings.systemAudio)
				InspectorToggle("Hide desktop icons", isOn: $settings.hideDesktopIcons)
				InspectorToggle("Show speaker notes", isOn: $settings.speakerNotes)
			}
			InspectorSection(title: "New recordings") {
				InspectorRow(title: "Look") {
					MenuChip(title: app.presets.preset(id: settings.defaultPresetID)?.name ?? StylePreset.builtIn[0].name) {
						ForEach(app.presets.all) { preset in
							Button(preset.name) { settings.defaultPresetID = preset.id }
						}
					}
				}
				InspectorRow(title: "Shortcut") { KeyHint("⌥⌘↩") }
				InspectorRow(title: "Projects folder") {
					Button("Show in Finder") {
						try? FileManager.default.createDirectory(at: app.library.rootURL, withIntermediateDirectories: true)
						NSWorkspace.shared.open(app.library.rootURL)
					}
					.buttonStyle(NebulaButtonStyle(.ghost, height: 26))
				}
			}
		}
	}
}

private struct ClaudeSettings: View {
	@Environment(AppModel.self) private var app
	@State private var port = ""
	@State private var copied = false

	var body: some View {
		@Bindable var settings = app.settings
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "MCP server") {
				Text("Claude and other MCP clients on this Mac can read and edit your projects, run Polish, record and export. Every edit shows up live and can be undone.")
					.font(.nebula(12.5, 550)).foregroundStyle(Theme.text2)
					.fixedSize(horizontal: false, vertical: true)
				InspectorToggle("Enable MCP server", isOn: Binding(
					get: { settings.mcpEnabled },
					set: { value in
						settings.mcpEnabled = value
						app.mcp.applySettings()
					}
				))
				HStack(spacing: 8) {
					Circle().fill(app.mcp.isRunning ? Theme.success : Theme.text3).frame(width: 7, height: 7)
					Text(app.mcp.isRunning ? "Running at \(app.mcp.url)" : (app.mcp.error ?? "Stopped"))
						.font(.nebula(12, 600)).foregroundStyle(Theme.text2)
						.textSelection(.enabled)
				}
				InspectorRow(title: "Port") {
					NebulaTextField(placeholder: "39351", text: $port) {
						if let value = Int(port), (1024...65535).contains(value) {
							settings.mcpPort = value
							app.mcp.applySettings()
						} else {
							port = "\(settings.mcpPort)"
						}
					}
					.frame(width: 100)
				}
				InspectorRow(title: "Starting recordings") {
					MenuChip(title: settings.mcpRecording.title) {
						ForEach(AppSettings.RecordingPermission.allCases, id: \.self) { option in
							Button(option.title) { settings.mcpRecording = option }
						}
					}
				}
			}
			InspectorSection(title: "Connect Claude Code") {
				Text(app.mcp.setupCommand)
					.font(.system(size: 12, design: .monospaced))
					.foregroundStyle(Theme.text1)
					.textSelection(.enabled)
					.padding(12)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface2))
				Button(copied ? "Copied" : "Copy command") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(app.mcp.setupCommand, forType: .string)
					copied = true
				}
				.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
				Text("The server only listens on 127.0.0.1 and rejects requests from web pages.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
			}
		}
		.onAppear { port = "\(settings.mcpPort)" }
	}
}

private struct PermissionSettings: View {
	@State private var refresh = 0

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "Permissions") {
				PermissionRow(
					title: "Screen Recording",
					detail: "Required to record your screen and system audio.",
					status: Permissions.screenRecording,
					request: { _ = Permissions.requestScreenRecording() },
					settingsURL: Permissions.screenRecordingSettingsURL
				)
				PermissionRow(
					title: "Microphone",
					detail: "To record your voice.",
					status: Permissions.microphone,
					request: { Task { _ = await Permissions.requestMicrophone() } },
					settingsURL: Permissions.microphoneSettingsURL
				)
				PermissionRow(
					title: "Accessibility",
					detail: "Lets Polish see clicks, shortcuts and text fields. Typed characters are never recorded.",
					status: Permissions.accessibility,
					request: { Permissions.requestAccessibility() },
					settingsURL: Permissions.accessibilitySettingsURL
				)
			}
			.id(refresh)
			Button("Check again") { refresh += 1 }.buttonStyle(NebulaButtonStyle(.ghost, height: 28))
		}
	}
}

private struct PermissionRow: View {
	let title: String
	let detail: String
	let status: Permissions.Status
	let request: () -> Void
	let settingsURL: URL

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle.dashed")
				.font(.system(size: 16))
				.foregroundStyle(status == .granted ? Theme.success : Theme.text3)
			VStack(alignment: .leading, spacing: 3) {
				Text(title).font(.nebula(13, 700)).foregroundStyle(Theme.text1)
				Text(detail).font(.nebula(12, 550)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
			}
			Spacer()
			if status != .granted {
				Button(status == .notDetermined ? "Allow" : "Open Settings") {
					if status == .notDetermined { request() } else { NSWorkspace.shared.open(settingsURL) }
				}
				.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
			}
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface1))
		.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
	}
}

private struct AboutView: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 14) {
				NebulaMark(size: 52)
				VStack(alignment: .leading, spacing: 3) {
					Text("Nebula").font(.nebula(20, 800)).foregroundStyle(Theme.text1)
					Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
						.font(.nebula(12.5, 600)).foregroundStyle(Theme.text3)
				}
			}
			Text("Screen recordings that edit themselves. Built in Swift, rendered on the GPU, and scriptable from Claude through MCP.")
				.font(.nebula(13, 550)).foregroundStyle(Theme.text2)
				.fixedSize(horizontal: false, vertical: true)
			Text("Open source under the MIT license. Typeface: Manrope (SIL Open Font License).")
				.font(.nebula(12, 550)).foregroundStyle(Theme.text3)
			Link("github.com/rune/nebula", destination: URL(string: "https://github.com/rune/nebula")!)
				.font(.nebula(12.5, 650))
				.foregroundStyle(Theme.lavender)
		}
	}
}
