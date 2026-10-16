import AVFoundation
import NebulaAudio
import NebulaCore
import NebulaDesign
import SwiftUI

/// The timeline. The axis is the original recording's time, so cuts stay visible (hatched) and
/// can be dragged or removed; the transport shows the edited (output) time.
struct TimelineView: View {
	let store: ProjectStore
	@State private var zoom: Double = 1
	@State private var pinchStart: Double?

	private enum Row {
		static let ruler: CGFloat = 26
		static let clips: CGFloat = 34
		static let lane: CGFloat = 30
		static let audio: CGFloat = 40
		static let spacing: CGFloat = 6
	}

	var body: some View {
		VStack(spacing: 0) {
			toolbar
			Hairline()
			HStack(alignment: .top, spacing: 0) {
				labels
				Rectangle().fill(Theme.hairline).frame(width: 1)
				GeometryReader { proxy in
					let duration = max(store.project.media.duration, 0.1)
					let pps = max(4, (proxy.size.width - 32) / duration * zoom)
					ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
						ZStack(alignment: .topLeading) {
							VStack(alignment: .leading, spacing: Row.spacing) {
								RulerView(store: store, duration: duration, pps: pps).frame(height: Row.ruler)
								clipTrack(pps: pps).frame(height: Row.clips)
								zoomTrack(pps: pps).frame(height: Row.lane)
								overlayTrack(pps: pps).frame(height: Row.lane)
								captionTrack(pps: pps).frame(height: Row.lane)
								audioTrack(pps: pps).frame(height: Row.audio)
							}
							PlayheadView(store: store, pps: pps)
						}
						.frame(width: duration * pps, alignment: .topLeading)
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
					}
					.scrollBounceBehavior(.basedOnSize)
				}
				.gesture(MagnifyGesture()
					.onChanged { value in
						let start = pinchStart ?? zoom
						pinchStart = start
						zoom = (start * value.magnification).clamped(to: 1...40)
					}
					.onEnded { _ in pinchStart = nil })
			}
		}
		.background(Theme.window)
	}

	// MARK: Toolbar

	private var toolbar: some View {
		HStack(spacing: 4) {
			ToolButton(title: "Cut", symbol: "scissors", key: "C") { store.cutAtPlayhead() }
			Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 6)
			ToolButton(title: "Zoom", symbol: "plus.magnifyingglass", key: "Z") { store.addZoom() }
			ToolButton(title: "Speed", symbol: "gauge.with.dots.needle.67percent", key: "S") { store.addSpeed() }
			ToolButton(title: "Blur", symbol: "eye.slash", key: "M") { store.addMask() }
			ToolButton(title: "Text", symbol: "textformat", key: "T") { store.addText() }
			ToolButton(title: "Arrow", symbol: "arrow.up.right", key: "A") { store.addArrow() }
			Spacer()
			if !store.selection.isEmpty {
				Button {
					store.delete(store.selection)
				} label: {
					Label(store.selection.count == 1 ? "Delete" : "Delete \(store.selection.count)", systemImage: "trash")
				}
				.buttonStyle(NebulaButtonStyle(.ghost, height: 28))
				.padding(.trailing, 8)
			}
			Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.text3)
			Slider(value: $zoom, in: 1...40)
				.controlSize(.mini)
				.tint(Theme.violet)
				.frame(width: 120)
			Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.text3)
		}
		.padding(.horizontal, 14)
		.frame(height: 44)
	}

	private var labels: some View {
		VStack(alignment: .leading, spacing: Row.spacing) {
			Color.clear.frame(height: Row.ruler)
			TrackLabel(title: "Clips", symbol: "rectangle.on.rectangle").frame(height: Row.clips)
			TrackLabel(title: "Zoom", symbol: "plus.magnifyingglass").frame(height: Row.lane)
			TrackLabel(title: "Overlays", symbol: "square.on.square.dashed").frame(height: Row.lane)
			TrackLabel(title: "Captions", symbol: "captions.bubble").frame(height: Row.lane)
			TrackLabel(title: "Audio", symbol: "waveform").frame(height: Row.audio)
		}
		.padding(.vertical, 8)
		.padding(.leading, 16)
		.frame(width: 112, alignment: .leading)
	}

	// MARK: Tracks

	private func clipTrack(pps: Double) -> some View {
		let p = store.project
		return TrackLane(store: store, pps: pps) {
			ZStack(alignment: .leading) {
				Filmstrip(url: store.videoURL, aspect: p.media.aspect, height: Row.clips, width: p.media.duration * pps)
					.opacity(0.32)
					.clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
					.allowsHitTesting(false)
				ForEach(p.speeds) { speed in
					TimelineBlock(store: store, id: speed.id, range: speed.range, pps: pps, tint: Theme.trackSpeed, label: "\(Format.rate(speed.rate)) speed", symbol: speed.source == .polish ? "sparkles" : "forward.fill")
				}
				ForEach(p.cuts) { cut in
					TimelineBlock(store: store, id: cut.id, range: cut.range, pps: pps, tint: Theme.text3, label: "cut · \(String(format: "%.1f", cut.range.duration))s", symbol: cut.source == .polish ? "sparkles" : nil, hatched: true)
				}
			}
		}
	}

	private func zoomTrack(pps: Double) -> some View {
		TrackLane(store: store, pps: pps) {
			ForEach(store.project.zooms) { zoom in
				TimelineBlock(store: store, id: zoom.id, range: zoom.range, pps: pps, tint: Theme.trackZoom, label: "\(Format.rate(zoom.scale)) · \(zoom.target.title)", symbol: zoom.source == .polish ? "sparkles" : nil)
			}
		}
	}

	private func overlayTrack(pps: Double) -> some View {
		TrackLane(store: store, pps: pps) {
			ForEach(store.project.masks) { mask in
				TimelineBlock(store: store, id: mask.id, range: mask.range, pps: pps, tint: Theme.trackMask, label: mask.kind.title, symbol: "eye.slash")
			}
			ForEach(store.project.annotations) { note in
				TimelineBlock(store: store, id: note.id, range: note.range, pps: pps, tint: Theme.trackNote, label: note.kind.title, symbol: note.kind.symbol)
			}
		}
	}

	private func captionTrack(pps: Double) -> some View {
		TrackLane(store: store, pps: pps) {
			if let captions = store.project.captions, captions.enabled {
				ForEach(captions.segments) { segment in
					Text(segment.text)
						.font(.nebula(11.5, 600))
						.foregroundStyle(Theme.text2)
						.lineLimit(1)
						.padding(.horizontal, 8)
						.frame(width: max(segment.range.duration * pps, 4), height: Row.lane - 4, alignment: .leading)
						.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface2))
						.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineStrong))
						.clipped()
						.offset(x: segment.range.start * pps)
						.onTapGesture { seek(store, toSource: segment.range.start) }
				}
			}
		}
	}

	private func audioTrack(pps: Double) -> some View {
		TrackLane(store: store, pps: pps) {
			ZStack(alignment: .leading) {
				WaveformShape(waveform: store.micWaveform ?? store.systemWaveform, duration: store.project.media.duration, cuts: store.project.cuts)
					.fill(Theme.text3.opacity(0.75))
					.frame(width: store.project.media.duration * pps)
					.allowsHitTesting(false)
				ForEach(store.project.audio.volumes) { volume in
					TimelineBlock(store: store, id: volume.id, range: volume.range, pps: pps, tint: Theme.lavender, label: volume.gain == 0 ? "Muted" : "Volume \(Format.percent(volume.gain))", symbol: volume.gain == 0 ? "speaker.slash" : "speaker.wave.2", height: 22)
				}
			}
		}
	}
}

@MainActor private func seek(_ store: ProjectStore, toSource time: Double, precise: Bool = true) {
	let map = store.timeMap
	let kept = map.nearestKeptSourceTime(to: time)
	store.preview.seek(to: map.outputTime(forSource: kept) ?? 0, precise: precise)
}

// MARK: - Pieces

private struct ToolButton: View {
	let title: String
	let symbol: String
	let key: String
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
				Text(title)
				KeyHint(key)
			}
		}
		.buttonStyle(NebulaButtonStyle(.ghost, height: 28))
		.help("\(title) (\(key))")
	}
}

private struct TrackLabel: View {
	let title: String
	let symbol: String

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
			Text(title).font(.nebula(12, 600))
		}
		.foregroundStyle(Theme.text3)
	}
}

/// A track's background. Clicking empty space deselects and moves the playhead.
private struct TrackLane<Content: View>: View {
	let store: ProjectStore
	let pps: Double
	@ViewBuilder let content: Content

	var body: some View {
		ZStack(alignment: .leading) {
			RoundedRectangle(cornerRadius: 7, style: .continuous)
				.fill(Theme.surface1)
				.contentShape(Rectangle())
				.gesture(SpatialTapGesture().onEnded { tap in
					store.selection = []
					seek(store, toSource: tap.location.x / pps)
				})
			content
		}
	}
}

private struct RulerView: View {
	let store: ProjectStore
	let duration: Double
	let pps: Double

	var body: some View {
		Canvas { context, size in
			let step = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 * pps >= 64 } ?? 600
			var t = 0.0
			while t <= duration + 0.001 {
				let x = t * pps
				context.fill(Path(CGRect(x: x, y: size.height - 7, width: 1, height: 7)), with: .color(Theme.text3.opacity(0.6)))
				let label = step < 1 ? Format.time(t) : Format.time(t, tenths: false)
				context.draw(Text(label).font(.nebula(10.5, 600)).foregroundStyle(Theme.text3), at: CGPoint(x: x + 3, y: size.height / 2 - 3), anchor: .leading)
				let minor = step / 4
				for i in 1..<4 {
					let mx = (t + minor * Double(i)) * pps
					if mx <= duration * pps {
						context.fill(Path(CGRect(x: mx, y: size.height - 4, width: 1, height: 4)), with: .color(Theme.text3.opacity(0.3)))
					}
				}
				t += step
			}
		}
		.contentShape(Rectangle())
		.gesture(DragGesture(minimumDistance: 0)
			.onChanged { drag in
				store.preview.pause()
				seek(store, toSource: (drag.location.x / pps).clamped(to: 0...duration), precise: false)
			}
			.onEnded { drag in seek(store, toSource: (drag.location.x / pps).clamped(to: 0...duration)) })
	}
}

/// Reads the playhead on its own so 60 Hz updates only redraw this view.
private struct PlayheadView: View {
	let store: ProjectStore
	let pps: Double

	var body: some View {
		let x = store.playheadSourceTime * pps
		ZStack(alignment: .top) {
			Rectangle().fill(Theme.text1).frame(width: 1.5)
			Text(Format.time(store.preview.currentTime))
				.font(.nebula(10.5, 750))
				.monospacedDigit()
				.foregroundStyle(Theme.window)
				.padding(.horizontal, 6)
				.frame(height: 18)
				.background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.text1))
				.fixedSize()
		}
		.frame(width: 60)
		.offset(x: x - 30)
		.allowsHitTesting(false)
	}
}

/// One item on a track: drag to move, drag its edges to trim, click to select.
private struct TimelineBlock: View {
	let store: ProjectStore
	let id: ItemID
	let range: TimeRange
	let pps: Double
	let tint: Color
	let label: String
	var symbol: String?
	var hatched = false
	var height: CGFloat?
	@State private var dragStart: TimeRange?

	private enum Edge { case start, end, both }

	var body: some View {
		let selected = store.selection.contains(id)
		let width = max(range.duration * pps, 6)
		HStack(spacing: 5) {
			if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
			Text(label).lineLimit(1)
		}
		.font(.nebula(11.5, 650))
		.foregroundStyle(tint == Theme.trackNote ? Theme.text1 : selected ? .white : Color.white.opacity(0.88))
		.padding(.horizontal, 8)
		.frame(width: width, alignment: .leading)
		.frame(maxHeight: height ?? .infinity)
		.padding(.vertical, height == nil ? 2 : 0)
		.background {
			ZStack {
				RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(selected ? 0.42 : hatched ? 0.10 : 0.24))
				if hatched { Hatch().stroke(tint.opacity(0.35), lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
			}
		}
		.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Theme.lavender : tint.opacity(0.5), lineWidth: selected ? 1.5 : 1))
		.clipped()
		.contentShape(Rectangle())
		.overlay(alignment: .leading) { edgeHandle(.start) }
		.overlay(alignment: .trailing) { edgeHandle(.end) }
		.offset(x: range.start * pps)
		.gesture(drag(.both))
		.onTapGesture { select() }
		.contextMenu {
			Button("Go to start") { seek(store, toSource: range.start) }
			Button("Delete") { store.delete([id]) }
		}
		.help(label)
	}

	private func edgeHandle(_ edge: Edge) -> some View {
		Color.clear
			.frame(width: min(8, max(range.duration * pps / 3, 3)))
			.contentShape(Rectangle())
			.pointerStyle(.columnResize)
			.gesture(drag(edge))
	}

	private func select() {
		if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
			if store.selection.contains(id) { store.selection.remove(id) } else { store.selection.insert(id) }
		} else {
			store.selection = [id]
		}
	}

	private func drag(_ edge: Edge) -> some Gesture {
		DragGesture(minimumDistance: 2, coordinateSpace: .global)
			.onChanged { value in
				let start = dragStart ?? range
				if dragStart == nil {
					dragStart = start
					if !store.selection.contains(id) { store.selection = [id] }
				}
				let dt = value.translation.width / pps
				var next = start
				switch edge {
				case .both:
					var s = start.start + dt
					s = snap(s) ?? snap(s + start.duration).map { $0 - start.duration } ?? s
					s = s.clamped(to: 0...max(0, store.project.media.duration - start.duration))
					next = TimeRange(start: s, end: s + start.duration)
				case .start:
					let s = snap(start.start + dt) ?? start.start + dt
					next = TimeRange(start: min(s, start.end - 0.1), end: start.end)
				case .end:
					let e = snap(start.end + dt) ?? start.end + dt
					next = TimeRange(start: start.start, end: max(e, start.start + 0.1))
				}
				store.setRange(id, to: next, label: edge == .both ? "Move" : "Trim", coalescing: "timeline-\(id)")
			}
			.onEnded { _ in dragStart = nil }
	}

	/// Snaps to the playhead and other items' edges within 6 points.
	private func snap(_ time: Double) -> Double? {
		let p = store.project
		var targets = [store.playheadSourceTime, 0, p.media.duration]
		let ranges = p.zooms.filter { $0.id != id }.map(\.range) + p.cuts.filter { $0.id != id }.map(\.range)
			+ p.speeds.filter { $0.id != id }.map(\.range) + p.masks.filter { $0.id != id }.map(\.range)
			+ p.annotations.filter { $0.id != id }.map(\.range)
		for r in ranges { targets += [r.start, r.end] }
		let threshold = 6 / pps
		return targets.min { abs($0 - time) < abs($1 - time) }.flatMap { abs($0 - time) < threshold ? $0 : nil }
	}
}

private struct Hatch: Shape {
	func path(in rect: CGRect) -> Path {
		var path = Path()
		var x = rect.minX - rect.height
		while x < rect.maxX {
			path.move(to: CGPoint(x: x, y: rect.maxY))
			path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
			x += 7
		}
		return path
	}
}

/// Mirrored peak bars. Cut sections are drawn faint.
private struct WaveformShape: Shape {
	let waveform: Waveform?
	let duration: Double
	let cuts: [CutItem]

	func path(in rect: CGRect) -> Path {
		var path = Path()
		guard let waveform, !waveform.isEmpty, duration > 0 else {
			path.addRect(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1))
			return path
		}
		let barWidth: CGFloat = 2
		let gap: CGFloat = 1.5
		var x = rect.minX
		while x < rect.maxX {
			let t0 = Double((x - rect.minX) / rect.width) * duration
			let t1 = Double((x + barWidth + gap - rect.minX) / rect.width) * duration
			let peak = CGFloat(waveform.peak(in: TimeRange(start: t0, end: t1)))
			let h = max(2, min(1, sqrt(peak) * 1.15) * (rect.height - 6))
			path.addRoundedRect(in: CGRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h), cornerSize: CGSize(width: 1, height: 1))
			x += barWidth + gap
		}
		return path
	}
}

/// Thumbnails along the clip track.
private struct Filmstrip: View {
	let url: URL
	let aspect: Double
	let height: CGFloat
	let width: CGFloat
	@State private var frames: [CGImage] = []

	private var count: Int {
		let thumbWidth = height * aspect
		return max(1, min(80, Int((width / max(thumbWidth, 1)).rounded(.up))))
	}

	var body: some View {
		HStack(spacing: 0) {
			ForEach(frames.indices, id: \.self) { index in
				Image(decorative: frames[index], scale: 2)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: width / CGFloat(frames.count), height: height)
					.clipped()
			}
		}
		.frame(width: width, height: height, alignment: .leading)
		.task(id: "\(url.path)-\(count)") {
			frames = await Self.load(url: url, count: count, height: height)
		}
	}

	private static func load(url: URL, count: Int, height: CGFloat) async -> [CGImage] {
		let asset = AVURLAsset(url: url)
		guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
		let generator = AVAssetImageGenerator(asset: asset)
		generator.maximumSize = CGSize(width: 0, height: height * 2)
		generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
		generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
		let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) / Double(count) * duration, preferredTimescale: 600) }
		var images: [CGImage] = []
		for await result in generator.images(for: times) {
			if let image = try? result.image { images.append(image) }
		}
		return images
	}
}

// MARK: - Labels

extension ZoomItem.Target {
	var title: String {
		switch self {
		case .follow: "Follow"
		case .point: "Point"
		case .rect: "Area"
		}
	}
}

extension MaskItem.Kind {
	var title: String {
		switch self {
		case .blur: "Blur"
		case .pixelate: "Pixelate"
		case .highlight: "Spotlight"
		}
	}

	var amount: Double {
		switch self {
		case .blur(let amount), .pixelate(let amount), .highlight(let amount): amount
		}
	}
}

extension AnnotationItem.Kind {
	var title: String {
		switch self {
		case .text(let label): "“\(label.text)”"
		case .arrow: "Arrow"
		}
	}

	var symbol: String {
		switch self {
		case .text: "textformat"
		case .arrow: "arrow.up.right"
		}
	}
}
