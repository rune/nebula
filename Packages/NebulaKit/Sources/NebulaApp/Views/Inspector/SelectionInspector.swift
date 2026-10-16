import NebulaCore
import NebulaDesign
import NebulaRender
import SwiftUI

/// Settings for the selected timeline item(s).
struct SelectionInspector: View {
	let store: ProjectStore

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(title).font(.nebula(13.5, 750)).foregroundStyle(Theme.text1)
				Spacer()
				Button("Done") { store.selection = [] }
					.buttonStyle(NebulaButtonStyle(.ghost, height: 26))
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 18)
			.frame(height: 52)
			Hairline()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					if store.selection.count == 1, let id = store.selection.first, let ref = store.item(id) {
						timing(ref.range)
						switch ref {
						case .zoom(let zoom): ZoomSettings(store: store, zoom: zoom)
						case .cut: cutNote
						case .speed(let speed): SpeedSettings(store: store, speed: speed)
						case .mask(let mask): MaskSettings(store: store, mask: mask)
						case .annotation(let note): AnnotationSettings(store: store, note: note)
						case .volume(let volume): VolumeSettings(store: store, volume: volume)
						}
					} else {
						Text("\(store.selection.count) items selected.")
							.font(.nebula(12.5, 550)).foregroundStyle(Theme.text2)
							.padding(.bottom, 16)
					}
					Button(role: .destructive) {
						store.delete(store.selection)
					} label: {
						Label(store.selection.count > 1 ? "Delete \(store.selection.count) items" : deleteTitle, systemImage: "trash").frame(maxWidth: .infinity)
					}
					.buttonStyle(NebulaButtonStyle(.destructive, height: 32))
				}
				.padding(18)
			}
			.scrollIndicators(.never)
		}
	}

	private var title: String {
		guard store.selection.count == 1, let id = store.selection.first, let ref = store.item(id) else { return "Selection" }
		switch ref {
		case .zoom(let zoom): return zoom.source == .polish ? "Zoom · from Polish" : "Zoom"
		case .cut: return "Cut"
		case .speed: return "Speed"
		case .mask(let mask): return mask.kind.title
		case .annotation(let note): if case .text = note.kind { return "Text" } else { return "Arrow" }
		case .volume: return "Volume"
		}
	}

	private var deleteTitle: String {
		guard let id = store.selection.first, case .cut = store.item(id) else { return "Delete" }
		return "Restore this section"
	}

	private var cutNote: some View {
		Text("This part of the recording is left out of the video. Drag the edges on the timeline to adjust it.")
			.font(.nebula(12, 550)).foregroundStyle(Theme.text2)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.bottom, 18)
	}

	private func timing(_ range: TimeRange) -> some View {
		HStack(spacing: 10) {
			TimeField(title: "Start", value: range.start)
			TimeField(title: "Length", value: range.duration)
			Spacer()
			IconButton("arrow.right.to.line", help: "Go to start") { seekToSource(store, range.start) }
		}
		.padding(.bottom, 20)
	}
}

private struct TimeField: View {
	let title: String
	let value: Double

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title.uppercased()).font(.nebula(10, 750)).tracking(0.6).foregroundStyle(Theme.text3)
			Text(Format.time(value)).font(.nebula(13, 700)).monospacedDigit().foregroundStyle(Theme.text1)
		}
	}
}

// MARK: - Zoom

private struct ZoomSettings: View {
	let store: ProjectStore
	let zoom: ZoomItem

	private enum TargetKind: String, CaseIterable { case follow, point, rect }

	var body: some View {
		InspectorSection(title: "Zoom") {
			NebulaSlider("Scale", value: Binding(
				get: { zoom.scale },
				set: { value in update("Zoom scale") { $0.scale = value } }
			), in: ZoomItem.scaleRange) { String(format: "%.1f×", $0) }
			SegmentedPicker(selection: Binding(
				get: { kind },
				set: { setKind($0) }
			), options: [(.follow, "Follow cursor"), (.point, "Point"), (.rect, "Area")])
			if kind != .follow {
				FocusPicker(store: store, zoom: zoom) { target in update("Zoom focus") { $0.target = target } }
			} else {
				Text("The camera follows your cursor and clicks during this zoom.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
			}
			InspectorToggle("Animate in and out", isOn: Binding(
				get: { zoom.transition == .spring },
				set: { value in update("Zoom transition") { $0.transition = value ? .spring : .instant } }
			))
		}
	}

	private var kind: TargetKind {
		switch zoom.target {
		case .follow: .follow
		case .point: .point
		case .rect: .rect
		}
	}

	private func setKind(_ kind: TargetKind) {
		let center: NormPoint
		switch zoom.target {
		case .follow: center = .center
		case .point(let p): center = p
		case .rect(let r): center = r.center
		}
		update("Zoom target") { item in
			switch kind {
			case .follow: item.target = .follow
			case .point: item.target = .point(center)
			case .rect:
				let size = 1 / max(item.scale, 1.2)
				item.target = .rect(NormRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size).clamped())
			}
		}
	}

	private func update(_ label: String, _ change: @escaping (inout ZoomItem) -> Void) {
		let id = zoom.id
		store.apply(label, coalescing: "\(label)-\(id)") { project in
			guard let i = project.zooms.firstIndex(where: { $0.id == id }) else { return }
			change(&project.zooms[i])
			project.zooms[i].source = .user
		}
	}
}

/// A still of the recording; click or drag to choose where the zoom looks.
private struct FocusPicker: View {
	let store: ProjectStore
	let zoom: ZoomItem
	let onChange: (ZoomItem.Target) -> Void
	@State private var frame: CGImage?
	@State private var dragStart: NormRect?

	var body: some View {
		let aspect = store.project.media.aspect
		GeometryReader { proxy in
			let size = proxy.size
			ZStack(alignment: .topLeading) {
				Group {
					if let frame { Image(decorative: frame, scale: 1).resizable() } else { Theme.surface2 }
				}
				.frame(width: size.width, height: size.height)
				let view = viewRect
				let rect = CGRect(x: view.x * size.width, y: view.y * size.height, width: view.width * size.width, height: view.height * size.height)
				Path { path in
					path.addRect(CGRect(origin: .zero, size: size))
					path.addRect(rect)
				}
				.fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
				RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.lavender, lineWidth: 1.5)
					.frame(width: rect.width, height: rect.height)
					.offset(x: rect.minX, y: rect.minY)
			}
			.contentShape(Rectangle())
			.gesture(DragGesture(minimumDistance: 0).onChanged { drag in
				let p = NormPoint(x: (drag.location.x / size.width).clamped(to: 0...1), y: (drag.location.y / size.height).clamped(to: 0...1))
				switch zoom.target {
				case .rect(let r):
					var moved = r
					moved.x = p.x - r.width / 2
					moved.y = p.y - r.height / 2
					onChange(.rect(moved.clamped()))
				default:
					onChange(.point(p))
				}
			})
		}
		.aspectRatio(aspect, contentMode: .fit)
		.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairlineStrong))
		.task(id: zoom.id) {
			let middle = (zoom.range.start + zoom.range.end) / 2
			frame = try? await FrameGrabber.sourceFrame(video: store.videoURL, at: middle, maxWidth: 640)
		}
	}

	/// The part of the recording the zoom shows.
	private var viewRect: NormRect {
		switch zoom.target {
		case .rect(let r): return r
		case .point(let p):
			let size = 1 / zoom.scale
			return NormRect(x: (p.x - size / 2).clamped(to: 0...(1 - size)), y: (p.y - size / 2).clamped(to: 0...(1 - size)), width: size, height: size)
		case .follow: return .full
		}
	}
}

// MARK: - Speed

private struct SpeedSettings: View {
	let store: ProjectStore
	let speed: SpeedItem

	var body: some View {
		InspectorSection(title: "Speed") {
			RateChips(rate: speed.rate) { set($0) }
			NebulaSlider("Rate", value: Binding(
				// Log scale: equal steps for 0.25× … 16×.
				get: { log2(speed.rate) },
				set: { set((pow(2, $0) * 4).rounded() / 4) }
			), in: -2...4) { Format.rate(pow(2, $0)) }
			Text("Saves \(Format.time(max(0, speed.range.duration - speed.range.duration / speed.rate))) of video.")
				.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
		}
	}

	private func set(_ rate: Double) {
		let id = speed.id
		store.apply("Speed \(Format.rate(rate))", coalescing: "speed-\(id)") { project in
			guard let i = project.speeds.firstIndex(where: { $0.id == id }) else { return }
			project.speeds[i].rate = rate.clamped(to: SpeedItem.rateRange)
		}
	}
}

// MARK: - Mask

private struct MaskSettings: View {
	let store: ProjectStore
	let mask: MaskItem

	private enum Kind: String { case blur, pixelate, highlight }

	var body: some View {
		InspectorSection(title: "Effect") {
			SegmentedPicker(selection: Binding(get: { kind }, set: { setKind($0) }), options: [(.blur, "Blur"), (.pixelate, "Pixelate"), (.highlight, "Spotlight")])
			NebulaSlider(kind == .highlight ? "Dim" : "Strength", value: Binding(
				get: { mask.kind.amount },
				set: { amount in update("Mask strength") { $0.kind = make(kind, amount) } }
			), in: 0.05...1, format: Format.percent)
			NebulaSlider("Corner radius", value: Binding(
				get: { mask.cornerRadius },
				set: { value in update("Mask corners") { $0.cornerRadius = value } }
			), in: 0...0.5, format: Format.percent)
			Text("Drag the box on the preview to move it; drag its corner to resize.")
				.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var kind: Kind {
		switch mask.kind {
		case .blur: .blur
		case .pixelate: .pixelate
		case .highlight: .highlight
		}
	}

	private func make(_ kind: Kind, _ amount: Double) -> MaskItem.Kind {
		switch kind {
		case .blur: .blur(amount: amount)
		case .pixelate: .pixelate(amount: amount)
		case .highlight: .highlight(amount: amount)
		}
	}

	private func setKind(_ kind: Kind) {
		update("Mask effect") { $0.kind = make(kind, $0.kind.amount) }
	}

	private func update(_ label: String, _ change: @escaping (inout MaskItem) -> Void) {
		let id = mask.id
		store.apply(label, coalescing: "\(label)-\(id)") { project in
			guard let i = project.masks.firstIndex(where: { $0.id == id }) else { return }
			change(&project.masks[i])
		}
	}
}

// MARK: - Annotations

private struct AnnotationSettings: View {
	let store: ProjectStore
	let note: AnnotationItem
	@State private var text = ""

	var body: some View {
		switch note.kind {
		case .text(let label):
			InspectorSection(title: "Text") {
				NebulaTextField(placeholder: "Label", text: $text)
					.onAppear { text = label.text }
					.onChange(of: text) { _, value in updateText("Edit text") { $0.text = value } }
				NebulaSlider("Size", value: Binding(get: { label.fontSize }, set: { v in updateText("Text size") { $0.fontSize = v } }), in: 0.02...0.12) { String(format: "%.0f", $0 * 1000) }
				InspectorToggle("Bold", isOn: Binding(get: { label.bold }, set: { v in updateText("Bold") { $0.bold = v } }))
				InspectorToggle("Background", isOn: Binding(
					get: { label.background != nil },
					set: { v in updateText("Text background") { $0.background = v ? ColorValue(hex: "#000000B3") : nil } }
				))
				InspectorRow(title: "Color") {
					ColorPicker("", selection: Binding(get: { label.color.color }, set: { c in updateText("Text color") { $0.color = ColorValue(c) } }), supportsOpacity: false)
						.labelsHidden()
				}
				ChipPicker(selection: Binding(get: { label.animation }, set: { v in updateText("Text animation") { $0.animation = v } }), options: TextAnimation.allCases.map { ($0, $0.rawValue.capitalized) })
			}
		case .arrow(let arrow):
			InspectorSection(title: "Arrow") {
				NebulaSlider("Thickness", value: Binding(get: { arrow.width }, set: { v in updateArrow { $0.width = v } }), in: 0.002...0.02) { String(format: "%.0f", $0 * 1000) }
				InspectorRow(title: "Color") {
					ColorPicker("", selection: Binding(get: { arrow.color.color }, set: { c in updateArrow { $0.color = ColorValue(c) } }), supportsOpacity: false)
						.labelsHidden()
				}
				Text("Drag the ends of the arrow on the preview.")
					.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
			}
		}
		InspectorSection(title: "Position") {
			SegmentedPicker(selection: Binding(
				get: { note.anchor },
				set: { value in
					let id = note.id
					store.apply("Annotation anchor") { project in
						if let i = project.annotations.firstIndex(where: { $0.id == id }) { project.annotations[i].anchor = value }
					}
				}
			), options: [(.screen, "Moves with zoom"), (.canvas, "Fixed on frame")])
		}
	}

	private func updateText(_ label: String, _ change: @escaping (inout TextAnnotation) -> Void) {
		let id = note.id
		store.apply(label, coalescing: "\(label)-\(id)") { project in
			guard let i = project.annotations.firstIndex(where: { $0.id == id }), case .text(var value) = project.annotations[i].kind else { return }
			change(&value)
			project.annotations[i].kind = .text(value)
		}
	}

	private func updateArrow(_ change: @escaping (inout ArrowAnnotation) -> Void) {
		let id = note.id
		store.apply("Arrow style", coalescing: "arrow-\(id)") { project in
			guard let i = project.annotations.firstIndex(where: { $0.id == id }), case .arrow(var value) = project.annotations[i].kind else { return }
			change(&value)
			project.annotations[i].kind = .arrow(value)
		}
	}
}

// MARK: - Volume

private struct VolumeSettings: View {
	let store: ProjectStore
	let volume: VolumeItem

	var body: some View {
		InspectorSection(title: "Volume") {
			NebulaSlider("Level", value: Binding(get: { volume.gain }, set: { v in update("Volume level") { $0.gain = v } }), in: 0...2, format: Format.percent)
			SegmentedPicker(selection: Binding(get: { volume.channel }, set: { v in update("Volume channel") { $0.channel = v } }), options: [(.all, "All"), (.microphone, "Mic"), (.system, "System")])
			Button(volume.gain == 0 ? "Unmute" : "Mute") { update("Mute") { $0.gain = $0.gain == 0 ? 1 : 0 } }
				.buttonStyle(NebulaButtonStyle(.secondary, height: 28))
		}
	}

	private func update(_ label: String, _ change: @escaping (inout VolumeItem) -> Void) {
		let id = volume.id
		store.apply(label, coalescing: "\(label)-\(id)") { project in
			guard let i = project.audio.volumes.firstIndex(where: { $0.id == id }) else { return }
			change(&project.audio.volumes[i])
		}
	}
}
