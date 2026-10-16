import AppKit
import NebulaCaptions
import NebulaCore
import NebulaDesign
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Camera

struct CameraInspector: View {
	let store: ProjectStore

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "Camera motion") {
				SegmentedPicker(selection: store.binding("Camera feel", \.camera.preset), options: CameraSettings.Preset.allCases.map { ($0, $0.title) })
				if store.project.camera.preset == .custom {
					NebulaSlider("Stiffness", value: store.binding("Camera stiffness", \.camera.tension), in: 20...400) { "\(Int($0))" }
					NebulaSlider("Damping", value: store.binding("Camera damping", \.camera.friction), in: 5...60) { "\(Int($0))" }
				}
				NebulaSlider("Motion blur", value: store.binding("Motion blur", \.camera.motionBlur), in: 0...1, format: Format.percent)
				NebulaSlider("Follow slack", value: store.binding("Follow slack", \.camera.followDeadzone), in: 0.2...0.9, format: Format.percent)
				Text("How far the cursor can move inside a following zoom before the camera pans.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
					.fixedSize(horizontal: false, vertical: true)
			}

			InspectorSection(title: "Zooms", trailing: "\(store.project.zooms.count)") {
				if store.project.zooms.isEmpty {
					Text("No zooms yet. Polish adds them from your clicks and typing, or press Z to add one at the playhead.")
						.font(.nebula(12, 550)).foregroundStyle(Theme.text3)
						.fixedSize(horizontal: false, vertical: true)
				} else {
					VStack(spacing: 2) {
						ForEach(store.project.zooms.sorted { $0.range.start < $1.range.start }) { zoom in
							ItemListRow(
								symbol: zoom.source == .polish ? "sparkles" : "plus.magnifyingglass",
								title: "\(Format.rate(zoom.scale)) · \(zoom.target.title)",
								detail: Format.time(zoom.range.start)
							) {
								store.selection = [zoom.id]
								seekToSource(store, zoom.range.start)
							}
						}
					}
				}
				HStack {
					Button { store.addZoom() } label: { Label("Add zoom", systemImage: "plus") }
						.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
					if store.project.zooms.contains(where: { $0.source == .polish }) {
						Button("Remove Polish zooms") {
							store.delete(Set(store.project.zooms.filter { $0.source == .polish }.map(\.id)))
						}
						.buttonStyle(NebulaButtonStyle(.ghost, height: 28))
					}
				}
			}
		}
	}
}

// MARK: - Cursor

struct CursorInspector: View {
	let store: ProjectStore

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "Cursor") {
				InspectorToggle("Show cursor", isOn: store.binding("Show cursor", \.cursor.visible))
				if store.project.cursor.visible {
					NebulaSlider("Size", value: store.binding("Cursor size", \.cursor.size), in: 0.5...4) { String(format: "%.1f×", $0) }
					NebulaSlider("Smoothing", value: store.binding("Cursor smoothing", \.cursor.smoothing), in: 0...1, format: Format.percent)
					InspectorToggle("Hide when idle", isOn: store.binding("Hide idle cursor", \.cursor.hideWhenIdle))
					if store.project.cursor.hideWhenIdle {
						NebulaSlider("Idle after", value: store.binding("Idle delay", \.cursor.idleDelay), in: 1...8) { String(format: "%.1f s", $0) }
					}
				}
			}
			InspectorSection(title: "Clicks") {
				SegmentedPicker(selection: store.binding("Click effect", \.cursor.clickEffect), options: [(.none, "None"), (.circle, "Circle"), (.ripple, "Ripple")])
				InspectorToggle("Press bounce", isOn: store.binding("Click bounce", \.cursor.clickBounce))
				InspectorRow(title: "Color") {
					ColorPicker("", selection: Binding(
						get: { store.project.cursor.clickColor.color },
						set: { color in store.apply("Click color", coalescing: "click-color") { $0.cursor.clickColor = ColorValue(color) } }
					), supportsOpacity: false)
					.labelsHidden()
				}
			}
			InspectorSection(title: "Keyboard shortcuts") {
				InspectorToggle("Show shortcuts", isOn: store.binding("Show shortcuts", \.shortcutOverlay.enabled))
				if store.project.shortcutOverlay.enabled {
					ChipPicker(selection: store.binding("Shortcut position", \.shortcutOverlay.position), options: [
						(.bottomCenter, "Bottom"), (.bottomLeft, "Bottom left"), (.bottomRight, "Bottom right"), (.topCenter, "Top"),
					])
					NebulaSlider("Size", value: store.binding("Shortcut size", \.shortcutOverlay.size), in: 0.03...0.09) { String(format: "%.0f", $0 * 1000) }
				}
				Text("Only shortcuts like ⌘C are shown. What you type is never recorded.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

// MARK: - Captions

struct CaptionsInspector: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app
	@State private var model: CaptionModel = .base
	@State private var progress: String?
	@State private var error: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let captions = store.project.captions, !captions.segments.isEmpty {
				InspectorSection(title: "Captions", trailing: "\(captions.segments.count) lines") {
					InspectorToggle("Show captions", isOn: Binding(
						get: { store.project.captions?.enabled ?? false },
						set: { value in store.apply(value ? "Show captions" : "Hide captions") { $0.captions?.enabled = value } }
					))
					SegmentedPicker(selection: captionBinding("Caption style", \.mode), options: [(.line, "Lines"), (.word, "Word by word")])
					SegmentedPicker(selection: captionBinding("Caption position", \.position), options: [(.bottom, "Bottom"), (.top, "Top")])
					NebulaSlider("Size", value: captionBinding("Caption size", \.fontSize), in: 0.025...0.08) { String(format: "%.0f", $0 * 1000) }
					InspectorRow(title: "Highlight") {
						ColorPicker("", selection: Binding(
							get: { store.project.captions?.style.highlight.color ?? .purple },
							set: { color in store.apply("Caption highlight", coalescing: "caption-highlight") { $0.captions?.style.highlight = ColorValue(color) } }
						), supportsOpacity: false)
						.labelsHidden()
					}
				}
				InspectorSection(title: "Text") {
					VStack(spacing: 6) {
						ForEach(captions.segments) { segment in
							CaptionLineEditor(store: store, segment: segment)
						}
					}
				}
				HStack {
					Button { exportSRT() } label: { Label("Export .srt", systemImage: "square.and.arrow.up") }
						.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
					Spacer()
					Button("Remove") { store.apply("Remove captions") { $0.captions = nil } }
						.buttonStyle(NebulaButtonStyle(.destructive, height: 28))
				}
			} else {
				InspectorSection(title: "Captions") {
					Text("Transcribe your voice on this Mac with Whisper. Nothing leaves your computer.")
						.font(.nebula(12, 550)).foregroundStyle(Theme.text2)
						.fixedSize(horizontal: false, vertical: true)
					VStack(spacing: 6) {
						ForEach(CaptionModel.allCases) { option in
							ModelRow(model: option, selected: option == model) { model = option }
						}
					}
					if let progress {
						HStack(spacing: 8) {
							ProgressView().controlSize(.small).tint(Theme.lavender)
							Text(progress).font(.nebula(12, 600)).foregroundStyle(Theme.text2)
						}
					} else {
						Button {
							generate()
						} label: {
							Label("Generate captions", systemImage: "captions.bubble").frame(maxWidth: .infinity)
						}
						.buttonStyle(NebulaButtonStyle(.primary, height: 34))
						.disabled(!store.project.media.hasMicrophone && !store.project.media.hasSystemAudio)
					}
					if let error {
						Text(error).font(.nebula(11.5, 600)).foregroundStyle(Color(hex: 0xFF8FA3))
					}
				}
			}
		}
	}

	private func captionBinding<Value: Equatable>(_ label: String, _ keyPath: WritableKeyPath<CaptionStyle, Value>) -> Binding<Value> {
		Binding(
			get: { (store.project.captions?.style ?? CaptionStyle())[keyPath: keyPath] },
			set: { value in store.apply(label, coalescing: label) { $0.captions?.style[keyPath: keyPath] = value } }
		)
	}

	private func generate() {
		error = nil
		progress = "Preparing…"
		Task {
			do {
				try await app.generateCaptions(for: store, model: model) { progress = $0 }
			} catch {
				self.error = error.localizedDescription
			}
			progress = nil
		}
	}

	private func exportSRT() {
		guard let captions = store.project.captions else { return }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
		panel.nameFieldStringValue = "\(store.project.name).srt"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let text = SRTWriter.srt(captions.segments, timeMap: store.timeMap)
		do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
	}
}

private struct ModelRow: View {
	let model: CaptionModel
	let selected: Bool
	let action: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: selected ? "largecircle.fill.circle" : "circle")
				.foregroundStyle(selected ? Theme.violet : Theme.text3)
			VStack(alignment: .leading, spacing: 2) {
				Text(model.title).font(.nebula(12.5, 650)).foregroundStyle(Theme.text1)
				Text(model.subtitle).font(.nebula(11, 550)).foregroundStyle(Theme.text3)
			}
			Spacer()
			Text(model.approximateSize).font(.nebula(11, 600)).foregroundStyle(Theme.text3)
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(selected ? Theme.violetSoft : Theme.surface2))
		.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(selected ? Theme.violetLine : Theme.hairline))
		.contentShape(Rectangle())
		.onTapGesture(perform: action)
	}
}

private struct CaptionLineEditor: View {
	let store: ProjectStore
	let segment: CaptionSegment
	@State private var text = ""

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Text(Format.time(segment.range.start, tenths: false))
				.font(.nebula(11, 650)).monospacedDigit().foregroundStyle(Theme.text3)
				.frame(width: 34, alignment: .leading)
				.padding(.top, 8)
				.onTapGesture { seekToSource(store, segment.range.start) }
			TextField("", text: $text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(.nebula(12.5, 550))
				.foregroundStyle(Theme.text1)
				.padding(7)
				.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface2))
				.onSubmit(commit)
				.onChange(of: text) { commitIfIdle() }
		}
		.onAppear { text = segment.text }
		.onChange(of: segment.text) { if text != segment.text { text = segment.text } }
	}

	private func commitIfIdle() {
		guard text != segment.text else { return }
		commit()
	}

	private func commit() {
		let value = text
		let id = segment.id
		store.apply("Edit caption", coalescing: "caption-\(id)") { project in
			guard let i = project.captions?.segments.firstIndex(where: { $0.id == id }) else { return }
			project.captions?.segments[i].text = value
			// Edited lines lose word timing; the line is shown whole.
			project.captions?.segments[i].words = []
		}
	}
}

// MARK: - Audio

struct AudioInspector: View {
	let store: ProjectStore
	@Environment(AppModel.self) private var app

	var body: some View {
		let media = store.project.media
		VStack(alignment: .leading, spacing: 0) {
			InspectorSection(title: "Levels") {
				if media.hasMicrophone {
					NebulaSlider("Microphone", value: store.binding("Microphone volume", \.audio.microphoneVolume), in: 0...2, format: Format.percent)
				}
				if media.hasSystemAudio {
					NebulaSlider("System audio", value: store.binding("System volume", \.audio.systemVolume), in: 0...2, format: Format.percent)
				}
				if !media.hasMicrophone && !media.hasSystemAudio {
					Text("This recording has no audio.").font(.nebula(12, 550)).foregroundStyle(Theme.text3)
				}
				if media.hasMicrophone {
					InspectorToggle("Reduce background noise", isOn: Binding(
						get: { store.project.audio.noiseReduction },
						set: { value in Task { await store.setNoiseReduction(value) } }
					))
				}
			}

			InspectorSection(title: "Volume changes", trailing: store.project.audio.volumes.isEmpty ? nil : "\(store.project.audio.volumes.count)") {
				Text("Lower, raise or mute a section. Select it on the timeline to adjust.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
					.fixedSize(horizontal: false, vertical: true)
				Button {
					let item = VolumeItem(range: store.rangeAtPlayhead(length: 3), gain: 0.5)
					store.apply("Add volume change") { $0.audio.volumes.append(item) }
					store.selection = [item.id]
				} label: { Label("Add at playhead", systemImage: "speaker.wave.1") }
				.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
			}

			InspectorSection(title: "Music") {
				if let music = store.project.audio.music {
					HStack(spacing: 8) {
						Image(systemName: "music.note").foregroundStyle(Theme.lavender)
						Text(music.file).font(.nebula(12.5, 650)).foregroundStyle(Theme.text1).lineLimit(1).truncationMode(.middle)
						Spacer()
						Button("Remove") { try? store.setMusic(from: nil) }.buttonStyle(NebulaButtonStyle(.ghost, height: 26))
					}
					NebulaSlider("Volume", value: musicBinding("Music volume", \.volume), in: 0...1, format: Format.percent)
					NebulaSlider("While speaking", value: musicBinding("Music ducking", \.duckTo), in: 0...1, format: Format.percent)
					InspectorToggle("Loop", isOn: musicBinding("Loop music", \.loop))
				} else {
					Button {
						let panel = NSOpenPanel()
						panel.allowedContentTypes = [.audio]
						panel.message = "Choose a music track."
						guard panel.runModal() == .OK, let url = panel.url else { return }
						do { try store.setMusic(from: url) } catch { app.toasts.show("Couldn't add music", detail: error.localizedDescription) }
					} label: {
						Label("Add music…", systemImage: "music.note").frame(maxWidth: .infinity)
					}
					.buttonStyle(NebulaButtonStyle(.secondary, height: 32))
					Text("Music gets quieter automatically while you talk.")
						.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
				}
			}
		}
	}

	private func musicBinding<Value: Equatable>(_ label: String, _ keyPath: WritableKeyPath<MusicTrack, Value>) -> Binding<Value> {
		Binding(
			get: { store.project.audio.music.map { $0[keyPath: keyPath] } ?? MusicTrack(file: "")[keyPath: keyPath] },
			set: { value in store.apply(label, coalescing: label) { $0.audio.music?[keyPath: keyPath] = value } }
		)
	}
}

// MARK: - Shared

struct ItemListRow: View {
	let symbol: String
	let title: String
	let detail: String
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 9) {
			Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.lavender).frame(width: 14)
			Text(title).font(.nebula(12.5, 600)).foregroundStyle(Theme.text1)
			Spacer()
			Text(detail).font(.nebula(11.5, 600)).monospacedDigit().foregroundStyle(Theme.text3)
		}
		.padding(.horizontal, 8)
		.frame(height: 30)
		.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hovering ? Theme.surface2 : .clear))
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.onTapGesture(perform: action)
	}
}

@MainActor
func seekToSource(_ store: ProjectStore, _ time: Double) {
	let map = store.timeMap
	store.preview.seek(to: map.outputTime(forSource: map.nearestKeptSourceTime(to: time)) ?? 0)
}
