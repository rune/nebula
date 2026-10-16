import AppKit
import NebulaCore
import NebulaDesign
import SwiftUI

/// The home window: every project, newest first.
public struct LibraryView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.openWindow) private var openWindow
	@State private var filter: Filter = .all
	@State private var query = ""
	@State private var dropTargeted = false

	enum Filter { case all, recent }

	public init() {}

	public var body: some View {
		HStack(spacing: 0) {
			sidebar
			Rectangle().fill(Theme.hairline).frame(width: 1)
			VStack(spacing: 0) {
				header
				Hairline()
				content
			}
			.background(Theme.window)
		}
		.background(Theme.surface1)
		.frame(minWidth: 900, minHeight: 600)
		.environment(\.colorScheme, .dark)
		.background(WindowAccessor { window in
			window.titlebarAppearsTransparent = true
			window.titleVisibility = .hidden
			window.backgroundColor = NSColor(Theme.window)
			window.tabbingMode = .disallowed
		})
		.onAppear {
			app.openEditorWindow = { url in openWindow(id: "editor", value: url) }
			app.openLibraryWindow = { openWindow(id: "library") }
			app.refreshLibrary()
		}
		.dropDestination(for: URL.self) { urls, _ in
			for url in urls { Task { await app.importFile(url) } }
			return !urls.isEmpty
		} isTargeted: { dropTargeted = $0 }
		.overlay {
			if dropTargeted {
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.strokeBorder(Theme.violetLine, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
					.padding(8)
					.allowsHitTesting(false)
			}
		}
	}

	private var visible: [ProjectLibrary.Entry] {
		var entries = app.entries
		if filter == .recent {
			let weekAgo = Date().addingTimeInterval(-7 * 86_400)
			entries = entries.filter { $0.modifiedAt > weekAgo }
		}
		let q = query.trimmingCharacters(in: .whitespaces)
		if !q.isEmpty { entries = entries.filter { $0.name.localizedCaseInsensitiveContains(q) } }
		return entries
	}

	// MARK: Sidebar

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: 4) {
			Color.clear.frame(height: 40)
			HStack(spacing: 10) {
				NebulaMark(size: 26)
				Text("Nebula").font(.nebula(16, 750)).foregroundStyle(Theme.text1)
			}
			.padding(.horizontal, 10)
			.padding(.bottom, 18)
			SidebarRow(title: "All recordings", symbol: "square.grid.2x2", count: app.entries.count, selected: filter == .all) { filter = .all }
			SidebarRow(title: "Recent", symbol: "clock", count: app.entries.filter { $0.modifiedAt > Date().addingTimeInterval(-7 * 86_400) }.count, selected: filter == .recent) { filter = .recent }
			SidebarRow(title: "Exports", symbol: "square.and.arrow.down", count: nil, selected: false) {
				try? FileManager.default.createDirectory(at: AppPaths.exports, withIntermediateDirectories: true)
				NSWorkspace.shared.open(AppPaths.exports)
			}
			SectionHeader("Style presets").padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
			ForEach(app.presets.all) { preset in
				HStack(spacing: 10) {
					PresetSwatch(preset: preset)
					Text(preset.name).font(.nebula(13, 600)).foregroundStyle(Theme.text2)
					Spacer()
					if app.settings.defaultPresetID == preset.id || (app.settings.defaultPresetID == nil && preset.id == StylePreset.builtIn[0].id) {
						Text("default").font(.nebula(11, 600)).foregroundStyle(Theme.text3)
					}
				}
				.padding(.horizontal, 10)
				.frame(height: 32)
				.contentShape(Rectangle())
				.contextMenu {
					Button("Use for new recordings") { app.settings.defaultPresetID = preset.id }
					if !StylePreset.builtIn.contains(where: { $0.id == preset.id }) {
						Button("Delete") { app.presets.delete(preset) }
					}
				}
			}
			Spacer()
			MCPStatusCard()
		}
		.padding(12)
		.frame(width: 240)
	}

	// MARK: Header

	private var header: some View {
		HStack(spacing: 14) {
			Text(filter == .all ? "All recordings" : "Recent").font(.nebula(20, 750)).foregroundStyle(Theme.text1)
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text3)
				TextField("", text: $query, prompt: Text("Search recordings").foregroundStyle(Theme.text3))
					.textFieldStyle(.plain)
					.font(.nebula(13, 600))
					.foregroundStyle(Theme.text1)
			}
			.padding(.horizontal, 12)
			.frame(width: 300, height: 32)
			.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface1))
			.overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairlineStrong))
			Spacer()
			Button {
				ImportPanel.run(app: app)
			} label: {
				Label("Import", systemImage: "square.and.arrow.up.on.square")
			}
			.buttonStyle(NebulaButtonStyle(.secondary, height: 32))
			Button {
				app.recorder.showPicker()
			} label: {
				HStack(spacing: 8) {
					Circle().fill(.white).frame(width: 7, height: 7)
					Text("New recording")
					Text("⌥⌘↩").font(.nebula(10.5, 700)).opacity(0.7)
				}
			}
			.buttonStyle(NebulaButtonStyle(.primary, height: 32))
		}
		.padding(.horizontal, 26)
		.frame(height: 76)
	}

	// MARK: Grid

	@ViewBuilder private var content: some View {
		if app.entries.isEmpty {
			EmptyLibrary()
		} else {
			ScrollView {
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 22)], spacing: 22) {
					ForEach(visible) { entry in
						ProjectCard(entry: entry)
					}
					NewRecordingTile()
				}
				.padding(26)
			}
		}
	}
}

/// The app mark: a violet orb. Flat, no glow.
struct NebulaMark: View {
	let size: CGFloat

	var body: some View {
		RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
			.fill(LinearGradient(colors: [Color(hex: 0xB22EFF), Color(hex: 0x6828FF)], startPoint: .topLeading, endPoint: .bottomTrailing))
			.overlay(
				Circle()
					.fill(LinearGradient(colors: [.white.opacity(0.95), Color(hex: 0xE6D6FF)], startPoint: .top, endPoint: .bottom))
					.frame(width: size * 0.36, height: size * 0.36)
					.offset(x: size * 0.1, y: -size * 0.1)
			)
			.frame(width: size, height: size)
	}
}

private struct SidebarRow: View {
	let title: String
	let symbol: String
	let count: Int?
	let selected: Bool
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: symbol).font(.system(size: 12.5)).frame(width: 16)
			Text(title).font(.nebula(13, 650))
			Spacer()
			if let count { Text("\(count)").font(.nebula(11.5, 600)).foregroundStyle(Theme.text3) }
		}
		.foregroundStyle(selected ? Theme.text1 : Theme.text2)
		.padding(.horizontal, 10)
		.frame(height: 34)
		.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.surface3 : hovering ? Theme.surface2 : .clear))
		.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.hairlineStrong : .clear))
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.onTapGesture(perform: action)
	}
}

private struct PresetSwatch: View {
	let preset: StylePreset

	var body: some View {
		RoundedRectangle(cornerRadius: 4, style: .continuous)
			.fill(fill)
			.frame(width: 14, height: 14)
			.overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairlineStrong))
	}

	private var fill: AnyShapeStyle {
		switch preset.style.background {
		case .color(let color): AnyShapeStyle(color.color)
		case .gradient(let gradient): AnyShapeStyle(LinearGradient(colors: gradient.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
		case .image: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x2E5BBA), Color(hex: 0xB8792E)], startPoint: .topLeading, endPoint: .bottomTrailing))
		}
	}
}

private struct ProjectCard: View {
	let entry: ProjectLibrary.Entry
	@Environment(AppModel.self) private var app
	@State private var hovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ZStack(alignment: .bottomTrailing) {
				AsyncFileImage(url: entry.bundle.thumbnailURL, maxPixel: 800)
					.frame(height: 170)
					.frame(maxWidth: .infinity)
					.clipped()
				if hovering {
					Image(systemName: "play.fill")
						.font(.system(size: 16))
						.foregroundStyle(Theme.window)
						.frame(width: 44, height: 44)
						.background(Circle().fill(.white))
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.transition(.opacity)
				}
				Text(Format.duration(entry.duration))
					.font(.nebula(11.5, 700))
					.monospacedDigit()
					.foregroundStyle(Theme.text1)
					.padding(.horizontal, 7)
					.padding(.vertical, 3)
					.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.7)))
					.padding(10)
			}
			.frame(height: 170)
			VStack(alignment: .leading, spacing: 4) {
				Text(entry.name).font(.nebula(13.5, 700)).foregroundStyle(Theme.text1).lineLimit(1)
				Text("\(Format.relative.localizedString(for: entry.modifiedAt, relativeTo: Date())) · \(entry.width) × \(entry.height)")
					.font(.nebula(12, 550)).foregroundStyle(Theme.text3)
			}
			.padding(14)
		}
		.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface1))
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Theme.violetLine : Theme.hairline, lineWidth: hovering ? 1.5 : 1))
		.contentShape(Rectangle())
		.onHover { value in withAnimation(Theme.snappy) { hovering = value } }
		.onTapGesture { app.open(entry.bundle.url) }
		.contextMenu {
			Button("Open") { app.open(entry.bundle.url) }
			Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.bundle.url]) }
			Divider()
			Button("Move to Trash") { app.delete(entry) }
		}
	}
}

private struct NewRecordingTile: View {
	@Environment(AppModel.self) private var app
	@State private var hovering = false

	var body: some View {
		VStack(spacing: 12) {
			Image(systemName: "plus")
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 48, height: 48)
				.background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.gradient))
			Text("New recording").font(.nebula(13.5, 700)).foregroundStyle(Theme.text1)
			Text("or drop a video / .openscreen project here").font(.nebula(12, 550)).foregroundStyle(Theme.text3)
		}
		.frame(maxWidth: .infinity)
		.frame(height: 240)
		.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.surface1 : .clear))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.onTapGesture { app.recorder.showPicker() }
	}
}

private struct EmptyLibrary: View {
	@Environment(AppModel.self) private var app

	var body: some View {
		VStack(spacing: 16) {
			NebulaMark(size: 64)
			Text("Record something worth watching").font(.nebula(22, 750)).foregroundStyle(Theme.text1)
			Text("Nebula records your screen, then zooms, cuts and smooths it for you.\nPress ⌥⌘↩ from anywhere to start.")
				.font(.nebula(13.5, 550)).foregroundStyle(Theme.text2)
				.multilineTextAlignment(.center)
			HStack(spacing: 10) {
				Button { app.recorder.showPicker() } label: { Label("New recording", systemImage: "record.circle") }
					.buttonStyle(NebulaButtonStyle(.primary, height: 38))
				Button { ImportPanel.run(app: app) } label: { Label("Import a video", systemImage: "square.and.arrow.down") }
					.buttonStyle(NebulaButtonStyle(.secondary, height: 38))
			}
			.padding(.top, 6)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// Sidebar card: is the MCP server up, and how to connect Claude.
private struct MCPStatusCard: View {
	@Environment(AppModel.self) private var app
	@State private var copied = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 7) {
				Circle().fill(app.mcp.isRunning ? Theme.success : Theme.text3).frame(width: 7, height: 7)
				Text(app.mcp.isRunning ? "MCP server running" : "MCP server off").font(.nebula(12.5, 700)).foregroundStyle(Theme.text1)
			}
			Text(app.mcp.isRunning ? "127.0.0.1:\(app.settings.mcpPort) · \(app.mcp.callCount) tool calls" : (app.mcp.error ?? "Turn it on in Settings"))
				.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
				.fixedSize(horizontal: false, vertical: true)
			if app.mcp.isRunning {
				Button(copied ? "Copied" : "Copy Claude Code setup") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(app.mcp.setupCommand, forType: .string)
					copied = true
				}
				.buttonStyle(NebulaButtonStyle(.ghost, height: 24))
				.help(app.mcp.setupCommand)
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
	}
}
