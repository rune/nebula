import AppKit
import NebulaDesign
import SwiftUI

/// ⌘K: every action, searchable. Lives in its own floating panel over the frontmost window.
@MainActor
public final class CommandPaletteController {
	public static let shared = CommandPaletteController()
	private var panel: NSPanel?

	public func toggle(app: AppModel) {
		if let panel, panel.isVisible {
			close()
			return
		}
		show(app: app)
	}

	func show(app: AppModel) {
		let panel = panel ?? makePanel()
		self.panel = panel
		let root = CommandPaletteView(app: app) { [weak self] in self?.close() }
			.environment(app)
			.environment(\.colorScheme, .dark)
		panel.contentView = NSHostingView(rootView: root)
		let anchor = NSApp.keyWindow ?? NSApp.mainWindow
		let screen = anchor?.screen ?? NSScreen.main
		let size = NSSize(width: 600, height: 420)
		if let frame = anchor?.frame ?? screen?.visibleFrame {
			panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 110, width: size.width, height: size.height), display: true)
		}
		panel.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}

	func close() {
		panel?.orderOut(nil)
	}

	private func makePanel() -> NSPanel {
		let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
		panel.isFloatingPanel = true
		panel.level = .floating
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = false
		panel.hidesOnDeactivate = true
		panel.isReleasedWhenClosed = false
		panel.onResignKey = { [weak self] in self?.close() }
		return panel
	}
}

/// A borderless panel that can take keyboard focus.
final class KeyablePanel: NSPanel {
	var onResignKey: (() -> Void)?
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }

	override func resignKey() {
		super.resignKey()
		onResignKey?()
	}
}

private struct CommandPaletteView: View {
	let app: AppModel
	let close: () -> Void
	@State private var query = ""
	@State private var index = 0
	@FocusState private var focused: Bool

	var body: some View {
		let results = ActionCenter.search(query, in: ActionCenter.actions(app: app))
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
				TextField("", text: $query, prompt: Text("Type a command…").foregroundStyle(Theme.text3))
					.textFieldStyle(.plain)
					.font(.nebula(16, 600))
					.foregroundStyle(Theme.text1)
					.focused($focused)
					.onSubmit { run(results) }
				KeyHint("esc")
			}
			.padding(.horizontal, 18)
			.frame(height: 56)
			Hairline()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 2) {
						ForEach(Array(results.enumerated()), id: \.element.id) { offset, action in
							CommandRow(action: action, selected: offset == index)
								.id(offset)
								.onTapGesture {
									index = offset
									run(results)
								}
								.onHover { if $0 { index = offset } }
						}
						if results.isEmpty {
							Text("No matching commands").font(.nebula(13, 600)).foregroundStyle(Theme.text3).padding(18)
						}
					}
					.padding(8)
				}
				.onChange(of: index) { proxy.scrollTo(index) }
			}
			Hairline()
			HStack(spacing: 14) {
				hint("↑↓", "Navigate")
				hint("↩", "Run")
				Spacer()
				Text(app.activeStore?.project.name ?? "Nebula").font(.nebula(11.5, 600)).foregroundStyle(Theme.text3)
			}
			.padding(.horizontal, 16)
			.frame(height: 36)
		}
		.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface1))
		.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairlineStrong))
		.clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
		.padding(1)
		.onAppear { focused = true }
		.onChange(of: query) { index = 0 }
		.onKeyPress(.downArrow) {
			index = min(index + 1, max(results.count - 1, 0))
			return .handled
		}
		.onKeyPress(.upArrow) {
			index = max(index - 1, 0)
			return .handled
		}
		.onKeyPress(.escape) {
			close()
			return .handled
		}
	}

	private func hint(_ keys: String, _ title: String) -> some View {
		HStack(spacing: 6) {
			KeyHint(keys)
			Text(title).font(.nebula(11.5, 600)).foregroundStyle(Theme.text3)
		}
	}

	private func run(_ results: [AppAction]) {
		guard results.indices.contains(index) else { return }
		let action = results[index]
		guard action.isEnabled else { return }
		close()
		action.perform()
	}
}

private struct CommandRow: View {
	let action: AppAction
	let selected: Bool

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: action.symbol)
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(selected ? Theme.lavender : Theme.text2)
				.frame(width: 28, height: 28)
				.background(RoundedRectangle(cornerRadius: Theme.radiusInner, style: .continuous).fill(selected ? Theme.violetSoft : Theme.surface2))
			Text(action.title).font(.nebula(13.5, 650)).foregroundStyle(action.isEnabled ? Theme.text1 : Theme.text3)
			Spacer()
			Text(action.group.rawValue).font(.nebula(11.5, 600)).foregroundStyle(Theme.text3)
			if let shortcut = action.shortcut { KeyHint(shortcut) }
		}
		.padding(.horizontal, 10)
		.frame(height: 42)
		.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(selected ? Theme.surface3 : .clear))
		.contentShape(Rectangle())
	}
}
