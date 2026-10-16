import AVFoundation
import NebulaAudio
import NebulaCore
import NebulaDesign
import SwiftUI

/// The timeline, laid out like a video editor: the axis is the edited video's time, the video
/// track is a row of clips you can split, trim, speed up and ripple-delete, and every other
/// track follows the clips.
struct TimelineView: View {
	let store: ProjectStore
	@State private var zoom: Double = 1
	@State private var pinchStart: Double?

	private enum Row {
		static let ruler: CGFloat = 26
		static let video: CGFloat = 48
		static let lane: CGFloat = 28
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
					let duration = max(store.timeMap.outputDuration, 0.1)
					let pps = max(4, (proxy.size.width - 32) / duration * zoom)
					ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
						ZStack(alignment: .topLeading) {
							VStack(alignment: .leading, spacing: Row.spacing) {
								RulerView(store: store, duration: duration, pps: pps).frame(height: Row.ruler)
								ClipTrack(store: store, pps: pps, height: Row.video).frame(height: Row.video)
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
			ToolButton(title: "Split", symbol: "scissors", key: "C") { store.splitAtPlayhead() }
			ToolButton(title: "Speed", symbol: "gauge.with.dots.needle.67percent", key: "S") { store.addSpeed() }
			Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 6)
			ToolButton(title: "Zoom", symbol: "plus.magnifyingglass", key: "Z") { store.addZoom() }
			ToolButton(title: "Blur", symbol: "eye.slash", key: "M") { store.addMask() }
			ToolButton(title: "Text", symbol: "textformat", key: "T") { store.addText() }
			ToolButton(title: "Arrow", symbol: "arrow.up.right", key: "A") { store.addArrow() }
			Spacer()
			if let clip = store.selectedClip, store.selection.isEmpty {
				Button {
					store.deleteClip(clip)
				} label: {
					Label("Delete clip", systemImage: "rectangle.badge.minus")
				}
				.buttonStyle(NebulaButtonStyle(.ghost, height: 28))
				.help("Remove the clip and close the gap (⌫)")
				.padding(.trailing, 8)
			} else if !store.selection.isEmpty {
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
			TrackLabel(title: "Video", symbol: "film").frame(height: Row.video)
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
		let map = store.timeMap
		return TrackLane(store: store, pps: pps) {
			if let captions = store.project.captions, captions.enabled {
				ForEach(captions.segments) { segment in
					if let out = map.outputRange(forSource: segment.range) {
						Text(segment.text)
							.font(.nebula(11.5, 600))
							.foregroundStyle(Theme.text2)
							.lineLimit(1)
							.padding(.horizontal, 8)
							.frame(width: max(out.duration * pps - 2, 4), height: Row.lane - 4, alignment: .leading)
							.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface2))
							.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineStrong))
							.clipped()
							.offset(x: out.start * pps + 1)
							.onTapGesture { store.preview.seek(to: out.start) }
					}
				}
			}
		}
	}

	private func audioTrack(pps: Double) -> some View {
		let waveform = store.micWaveform ?? store.systemWaveform
		return TrackLane(store: store, pps: pps) {
			ZStack(alignment: .leading) {
				ForEach(store.project.clips) { clip in
					WaveformShape(waveform: waveform, source: clip.source)
						.fill(Theme.text3.opacity(0.75))
						.frame(width: max(clip.outputDuration * pps - 2, 1))
						.offset(x: clip.outputStart * pps + 1)
						.allowsHitTesting(false)
				}
				ForEach(store.project.audio.volumes) { volume in
					TimelineBlock(store: store, id: volume.id, range: volume.range, pps: pps, tint: Theme.lavender, label: volume.gain == 0 ? "Muted" : "Volume \(Format.percent(volume.gain))", symbol: volume.gain == 0 ? "speaker.slash" : "speaker.wave.2", height: 22)
				}
			}
		}
	}
}

// MARK: - Video track

/// The clips, back to back. Click to select, drag an edge to trim (outward brings back what was
/// removed), right-click for speed and delete.
private struct ClipTrack: View {
	let store: ProjectStore
	let pps: Double
	let height: CGFloat

	var body: some View {
		let clips = store.project.clips
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 7, style: .continuous)
				.fill(Theme.surface1)
				.contentShape(Rectangle())
				.onTapGesture { store.selectClip(nil) }
			ForEach(clips) { clip in
				ClipView(store: store, clip: clip, pps: pps, height: height)
			}
			ForEach(Array(zip(clips, clips.dropFirst())), id: \.1.index) { previous, next in
				if next.source.start - previous.source.end > 0.01 {
					RemovedMarker(store: store, removed: TimeRange(start: previous.source.end, end: next.source.start))
						.offset(x: next.outputStart * pps - 8, y: -6)
				}
			}
		}
	}
}

private struct ClipView: View {
	let store: ProjectStore
	let clip: Clip
	let pps: Double
	let height: CGFloat
	@State private var trimBase: (project: Project, clip: Clip)?
	@State private var hovering = false

	var body: some View {
		let selected = store.selectedClip?.index == clip.index && store.selection.isEmpty
		let width = max(clip.outputDuration * pps - 2, 2)
		let sped = abs(clip.rate - 1) > 0.001
		ZStack(alignment: .topLeading) {
			Theme.surface2
			ClipFilmstrip(url: store.videoURL, source: clip.source, aspect: store.project.media.aspect, width: width, height: height)
				.opacity(selected ? 0.9 : 0.62)
			LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
			if width > 34 {
				HStack(spacing: 5) {
					if sped {
						HStack(spacing: 3) {
							Image(systemName: clip.rate > 1 ? "forward.fill" : "tortoise.fill").font(.system(size: 8, weight: .bold))
							Text(Format.rate(clip.rate))
						}
						.padding(.horizontal, 5)
						.frame(height: 16)
						.background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.trackSpeed))
					}
					if width > 90 {
						Text(Format.time(clip.outputDuration))
							.foregroundStyle(Color.white.opacity(0.8))
					}
				}
				.font(.nebula(10.5, 700))
				.monospacedDigit()
				.foregroundStyle(.white)
				.padding(5)
			}
		}
		.frame(width: width, height: height)
		.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.strokeBorder(selected ? Theme.lavender : sped ? Theme.trackSpeed.opacity(0.8) : hovering ? Color.white.opacity(0.22) : Theme.hairlineStrong, lineWidth: selected ? 2 : 1)
		)
		.overlay(alignment: .leading) { trimHandle(.start, selected: selected) }
		.overlay(alignment: .trailing) { trimHandle(.end, selected: selected) }
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.onTapGesture { store.selectClip(clip) }
		.contextMenu { menu }
		.offset(x: clip.outputStart * pps + 1)
		.help(sped ? "\(Format.rate(clip.rate)) · drag the edges to trim" : "Drag the edges to trim")
	}

	@ViewBuilder private var menu: some View {
		let playhead = store.playheadSourceTime
		Button("Split at Playhead") { store.splitAtPlayhead() }
			.disabled(!(playhead > clip.source.start + 0.05 && playhead < clip.source.end - 0.05))
		Menu("Speed") {
			ForEach([0.5, 1, 1.5, 2, 3, 4, 8], id: \.self) { rate in
				Button(Format.rate(rate) + (rate == clip.rate ? "  ✓" : "")) { store.setRate(rate, for: clip) }
			}
		}
		Divider()
		Button("Delete Clip") { store.deleteClip(clip) }
	}

	private func trimHandle(_ edge: Project.ClipEdge, selected: Bool) -> some View {
		ZStack {
			if selected || hovering {
				RoundedRectangle(cornerRadius: 1.5).fill(selected ? Theme.lavender : Color.white.opacity(0.6)).frame(width: 3, height: height * 0.45)
			}
		}
		.frame(width: 10, height: height)
		.contentShape(Rectangle())
		.pointerStyle(.columnResize)
		.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
			.onChanged { drag in
				let base = trimBase ?? (store.project, clip)
				if trimBase == nil {
					trimBase = base
					store.preview.pause()
				}
				let delta = drag.translation.width / pps * base.clip.rate
				let target = edge == .end ? base.clip.source.end + delta : base.clip.source.start + delta
				store.trim(base.clip, edge: edge, toSource: target, base: base.project)
			}
			.onEnded { _ in
				if let base = trimBase {
					// Keep the trimmed clip selected and show its new edge.
					// The edge that didn't move identifies the clip.
					let anchor = edge == .end ? base.clip.source.start + 0.001 : base.clip.source.end - 0.001
					if let trimmed = store.project.clip(atSource: anchor) {
						store.selectClip(trimmed)
						store.preview.seek(to: edge == .end ? max(0, trimmed.outputEnd - 0.02) : trimmed.outputStart)
					}
				}
				trimBase = nil
			})
	}
}

/// Marks where material was removed between two clips. Double-click to bring it back.
private struct RemovedMarker: View {
	let store: ProjectStore
	let removed: TimeRange

	var body: some View {
		Image(systemName: "scissors")
			.font(.system(size: 7.5, weight: .bold))
			.foregroundStyle(Theme.text2)
			.frame(width: 16, height: 16)
			.background(Circle().fill(Theme.surface3))
			.overlay(Circle().strokeBorder(Theme.hairlineStrong))
			.contentShape(Circle())
			.onTapGesture(count: 2) { store.restore(removed) }
			.contextMenu { Button("Restore \(String(format: "%.1f", removed.duration)) s") { store.restore(removed) } }
			.help("\(String(format: "%.1f", removed.duration)) s removed · double-click to restore")
	}
}

/// Thumbnails across one clip's part of the recording.
private struct ClipFilmstrip: View {
	let url: URL
	let source: TimeRange
	let aspect: Double
	let width: CGFloat
	let height: CGFloat
	@State private var frames: [CGImage] = []

	private var count: Int {
		max(1, min(48, Int((width / max(height * aspect, 1)).rounded(.up))))
	}

	var body: some View {
		HStack(spacing: 0) {
			ForEach(frames.indices, id: \.self) { index in
				Image(decorative: frames[index], scale: 2)
					.resizable()
					.aspectRatio(contentMode: .fill)
					.frame(width: width / CGFloat(max(frames.count, 1)), height: height)
					.clipped()
			}
		}
		.frame(width: width, height: height, alignment: .leading)
		.task(id: "\(source.start)-\(source.end)-\(count)") {
			let times = (0..<count).map { source.start + (Double($0) + 0.5) / Double(count) * source.duration }
			frames = await ThumbnailCache.shared.frames(url: url, at: times, height: height)
		}
	}
}

/// Recording thumbnails shared by all clips, keyed by quarter-second.
actor ThumbnailCache {
	static let shared = ThumbnailCache()
	private var images: [String: CGImage] = [:]

	func frames(url: URL, at times: [Double], height: CGFloat) async -> [CGImage] {
		let keys = times.map { "\(url.path)#\(Int(($0 * 4).rounded()))" }
		let missing = zip(keys, times).filter { images[$0.0] == nil }
		if !missing.isEmpty {
			let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
			generator.maximumSize = CGSize(width: 0, height: height * 2)
			generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
			generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
			let requested = missing.map { CMTime(seconds: $0.1, preferredTimescale: 600) }
			var index = 0
			for await result in generator.images(for: requested) {
				if let image = try? result.image, index < missing.count { images[missing[index].0] = image }
				index += 1
			}
		}
		return keys.compactMap { images[$0] }
	}
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
					store.selectClip(nil)
					store.preview.seek(to: tap.location.x / pps)
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
				store.preview.seek(to: (drag.location.x / pps).clamped(to: 0...duration), precise: false)
			}
			.onEnded { drag in store.preview.seek(to: (drag.location.x / pps).clamped(to: 0...duration)) })
	}
}

/// Reads the playhead on its own so 60 Hz updates only redraw this view.
private struct PlayheadView: View {
	let store: ProjectStore
	let pps: Double

	var body: some View {
		let x = store.preview.currentTime * pps
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

/// One item on a track, placed by where its source range plays in the edited video. Drag to
/// move, drag its edges to change its length, click to select.
private struct TimelineBlock: View {
	let store: ProjectStore
	let id: ItemID
	let range: TimeRange
	let pps: Double
	let tint: Color
	let label: String
	var symbol: String?
	var height: CGFloat?
	@State private var dragStart: (source: TimeRange, output: TimeRange)?

	private enum Edge { case start, end, both }

	var body: some View {
		if let output = store.timeMap.outputRange(forSource: range) {
			block(output)
		}
	}

	private func block(_ output: TimeRange) -> some View {
		let selected = store.selection.contains(id)
		let width = max(output.duration * pps - 2, 6)
		return HStack(spacing: 5) {
			if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
			Text(label).lineLimit(1)
		}
		.font(.nebula(11.5, 650))
		.foregroundStyle(tint == Theme.trackNote ? Theme.text1 : selected ? .white : Color.white.opacity(0.88))
		.padding(.horizontal, 8)
		.frame(width: width, alignment: .leading)
		.frame(maxHeight: height ?? .infinity)
		.padding(.vertical, height == nil ? 2 : 0)
		.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(selected ? 0.42 : 0.24)))
		.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Theme.lavender : tint.opacity(0.5), lineWidth: selected ? 1.5 : 1))
		.clipped()
		.contentShape(Rectangle())
		.overlay(alignment: .leading) { edgeHandle(.start, output: output) }
		.overlay(alignment: .trailing) { edgeHandle(.end, output: output) }
		.offset(x: output.start * pps + 1)
		.gesture(drag(.both, output: output))
		.onTapGesture { select() }
		.contextMenu {
			Button("Go to Start") { store.preview.seek(to: output.start) }
			Button("Delete") { store.delete([id]) }
		}
		.help(label)
	}

	private func edgeHandle(_ edge: Edge, output: TimeRange) -> some View {
		Color.clear
			.frame(width: min(8, max(output.duration * pps / 3, 3)))
			.contentShape(Rectangle())
			.pointerStyle(.columnResize)
			.gesture(drag(edge, output: output))
	}

	private func select() {
		if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
			if store.selection.contains(id) { store.selection.remove(id) } else { store.selection.insert(id) }
		} else {
			store.selection = [id]
		}
	}

	private func drag(_ edge: Edge, output: TimeRange) -> some Gesture {
		DragGesture(minimumDistance: 2, coordinateSpace: .global)
			.onChanged { value in
				let start = dragStart ?? (range, output)
				if dragStart == nil {
					dragStart = start
					if !store.selection.contains(id) { store.selection = [id] }
				}
				let map = store.timeMap
				let total = map.outputDuration
				let dt = value.translation.width / pps
				var next = start.source
				switch edge {
				case .both:
					var s = start.output.start + dt
					s = snap(s) ?? snap(s + start.output.duration).map { $0 - start.output.duration } ?? s
					s = s.clamped(to: 0...max(0, total - start.output.duration))
					let sourceStart = map.sourceTime(forOutput: s)
					next = TimeRange(start: sourceStart, end: min(store.project.media.duration, sourceStart + start.source.duration))
				case .start:
					let s = (snap(start.output.start + dt) ?? start.output.start + dt).clamped(to: 0...(start.output.end - 0.1))
					next = TimeRange(start: map.sourceTime(forOutput: s), end: start.source.end)
				case .end:
					let e = (snap(start.output.end + dt) ?? start.output.end + dt).clamped(to: (start.output.start + 0.1)...total)
					next = TimeRange(start: start.source.start, end: map.sourceTime(forOutput: e))
				}
				store.setRange(id, to: next, label: edge == .both ? "Move" : "Trim", coalescing: "timeline-\(id)")
			}
			.onEnded { _ in dragStart = nil }
	}

	/// Snaps an output time to the playhead, clip edges and other items within 6 points.
	private func snap(_ time: Double) -> Double? {
		let p = store.project
		let map = store.timeMap
		var targets = [store.preview.currentTime, 0, map.outputDuration]
		for clip in p.clips { targets += [clip.outputStart, clip.outputEnd] }
		let ranges = p.zooms.filter { $0.id != id }.map(\.range) + p.masks.filter { $0.id != id }.map(\.range)
			+ p.annotations.filter { $0.id != id }.map(\.range)
		for r in ranges { if let out = map.outputRange(forSource: r) { targets += [out.start, out.end] } }
		let threshold = 6 / pps
		return targets.min { abs($0 - time) < abs($1 - time) }.flatMap { abs($0 - time) < threshold ? $0 : nil }
	}
}

/// Mirrored peak bars for one clip's part of the recording.
private struct WaveformShape: Shape {
	let waveform: Waveform?
	let source: TimeRange

	func path(in rect: CGRect) -> Path {
		var path = Path()
		guard let waveform, !waveform.isEmpty, source.duration > 0 else {
			path.addRect(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1))
			return path
		}
		let barWidth: CGFloat = 2
		let gap: CGFloat = 1.5
		var x = rect.minX
		while x < rect.maxX {
			let t0 = source.start + Double((x - rect.minX) / rect.width) * source.duration
			let t1 = source.start + Double((x + barWidth + gap - rect.minX) / rect.width) * source.duration
			let peak = CGFloat(waveform.peak(in: TimeRange(start: t0, end: t1)))
			let h = max(2, min(1, sqrt(peak) * 1.15) * (rect.height - 6))
			path.addRoundedRect(in: CGRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h), cornerSize: CGSize(width: 1, height: 1))
			x += barWidth + gap
		}
		return path
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
