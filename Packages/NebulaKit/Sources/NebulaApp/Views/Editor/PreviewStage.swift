import AVFoundation
import NebulaCore
import NebulaDesign
import NebulaPolish
import NebulaRender
import SwiftUI

/// The preview: the rendered frame at the largest size that fits, plus on-canvas editing handles
/// for the selected mask or annotation.
struct PreviewStage: View {
	let store: ProjectStore

	var body: some View {
		GeometryReader { proxy in
			let aspect = SceneLayout.aspect(for: store.project)
			let size = fit(aspect: aspect, in: CGSize(width: proxy.size.width - 48, height: proxy.size.height - 40))
			ZStack {
				ZStack {
					Theme.canvas
					PlayerLayerView(player: store.preview.player)
						.opacity(store.preview.isReady ? 1 : 0)
					if !store.preview.isReady {
						ProgressView().controlSize(.small).tint(Theme.text2)
					}
				}
				.frame(width: size.width, height: size.height)
				.clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
				.shadow(color: .black.opacity(0.55), radius: 26, y: 14)
				.overlay(StageOverlay(store: store, size: size))
				.overlay(alignment: .topLeading) { PlacementBadge(project: store.project).padding(12) }
				.overlay { BusyPill(message: store.busyMessage) }
				.contentShape(Rectangle())
				.onTapGesture {
					if store.selection.isEmpty { store.preview.togglePlay() } else { store.selection = [] }
				}
			}
			.frame(width: proxy.size.width, height: proxy.size.height)
			.task(id: renderBucket(size)) {
				try? await Task.sleep(for: .milliseconds(250))
				guard !Task.isCancelled else { return }
				store.previewShortSide = renderBucket(size)
			}
		}
	}

	private func fit(aspect: Double, in bounds: CGSize) -> CGSize {
		let width = max(bounds.width, 100)
		let height = max(bounds.height, 100)
		if width / height > aspect {
			return CGSize(width: (height * aspect).rounded(), height: height.rounded())
		}
		return CGSize(width: width.rounded(), height: (width / aspect).rounded())
	}

	/// Render resolution for the preview: the view's short side in pixels, in steps of 120 so
	/// window resizes don't rebuild the player constantly.
	private func renderBucket(_ size: CGSize) -> Int {
		let scale = NSScreen.main?.backingScaleFactor ?? 2
		let pixels = Int(min(size.width, size.height) * scale)
		return min(2160, max(360, (pixels / 120 + 1) * 120))
	}
}

/// "Window · as on screen" in the stage corner.
private struct PlacementBadge: View {
	let project: Project

	var body: some View {
		if let text {
			Text(text)
				.font(.nebula(11.5, 650))
				.foregroundStyle(Theme.lavender)
				.padding(.horizontal, 9)
				.padding(.vertical, 5)
				.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color.black.opacity(0.55)))
				.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairlineStrong))
				.allowsHitTesting(false)
		}
	}

	private var text: String? {
		guard project.media.screen != nil else { return nil }
		return project.style.placement == .original ? "Window · as on screen" : "Window · fit with padding"
	}
}

private struct BusyPill: View {
	let message: String?

	var body: some View {
		if let message {
			HStack(spacing: 8) {
				ProgressView().controlSize(.small).tint(Theme.lavender)
				Text(message).font(.nebula(12.5, 650)).foregroundStyle(Theme.text1)
			}
			.padding(.horizontal, 14)
			.frame(height: 36)
			.background(Capsule().fill(Theme.surface2))
			.overlay(Capsule().strokeBorder(Theme.hairlineStrong))
			.shadow(color: .black.opacity(0.5), radius: 12, y: 6)
			.transition(.opacity.combined(with: .scale(scale: 0.96)))
		}
	}
}

// MARK: - Player layer

struct PlayerLayerView: NSViewRepresentable {
	let player: AVPlayer

	func makeNSView(context: Context) -> PlayerNSView {
		let view = PlayerNSView()
		view.playerLayer.player = player
		return view
	}

	func updateNSView(_ nsView: PlayerNSView, context: Context) {
		if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
	}

	final class PlayerNSView: NSView {
		let playerLayer = AVPlayerLayer()

		override init(frame: NSRect) {
			super.init(frame: frame)
			wantsLayer = true
			layer = CALayer()
			playerLayer.videoGravity = .resizeAspect
			playerLayer.backgroundColor = NSColor.clear.cgColor
			layer?.addSublayer(playerLayer)
		}

		@available(*, unavailable)
		required init?(coder: NSCoder) { nil }

		override func layout() {
			super.layout()
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			playerLayer.frame = bounds
			CATransaction.commit()
		}
	}
}

// MARK: - On-canvas handles

/// Maps between normalized project coordinates and points in the stage view.
private struct StageMapper {
	let layout: SceneLayout
	let camera: CameraState
	let view: CGSize

	private var sx: CGFloat { view.width / layout.canvas.width }
	private var sy: CGFloat { view.height / layout.canvas.height }

	func point(_ p: NormPoint, anchor: AnnotationItem.Anchor) -> CGPoint {
		switch anchor {
		case .canvas:
			return CGPoint(x: p.x * view.width, y: p.y * view.height)
		case .screen:
			let c = layout.canvasPoint(for: p, camera: camera)
			return CGPoint(x: c.x * sx, y: view.height - c.y * sy)
		}
	}

	func rect(_ r: NormRect) -> CGRect {
		let c = layout.canvasRect(for: r, camera: camera)
		return CGRect(x: c.minX * sx, y: view.height - c.maxY * sy, width: c.width * sx, height: c.height * sy)
	}

	/// A drag distance in view points as a distance in normalized coordinates.
	func delta(_ d: CGSize, anchor: AnnotationItem.Anchor = .screen) -> (dx: Double, dy: Double) {
		switch anchor {
		case .canvas:
			return (d.width / view.width, d.height / view.height)
		case .screen:
			let visible = layout.visibleRect(for: camera)
			let contentW = layout.content.width * sx
			let contentH = layout.content.height * sy
			return (d.width / max(contentW, 1) * visible.width, d.height / max(contentH, 1) * visible.height)
		}
	}
}

private struct StageOverlay: View {
	let store: ProjectStore
	let size: CGSize
	@State private var startRect: NormRect?
	@State private var startPoints: [NormPoint] = []

	var body: some View {
		if store.selection.count == 1, let id = store.selection.first, let ref = store.item(id), let playable = store.preview.playable {
			let mapper = StageMapper(
				layout: SceneLayout(project: playable.scene.project, canvas: playable.renderSize),
				camera: playable.scene.camera.state(atOutput: store.preview.currentTime),
				view: size
			)
			ZStack(alignment: .topLeading) {
				switch ref {
				case .mask(let mask):
					maskHandles(mask, mapper: mapper)
				case .annotation(let note):
					annotationHandles(note, mapper: mapper)
				default:
					EmptyView()
				}
			}
			.frame(width: size.width, height: size.height, alignment: .topLeading)
		}
	}

	// Masks: drag to move, corner to resize.
	@ViewBuilder private func maskHandles(_ mask: MaskItem, mapper: StageMapper) -> some View {
		let frame = mapper.rect(mask.rect)
		RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
			.strokeBorder(Theme.lavender, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
			.background(Theme.violet.opacity(0.08))
			.frame(width: frame.width, height: frame.height)
			.contentShape(Rectangle())
			.position(x: frame.midX, y: frame.midY)
			.gesture(DragGesture(minimumDistance: 1).onChanged { drag in
				let start = startRect ?? mask.rect
				startRect = start
				let d = mapper.delta(drag.translation)
				var rect = start
				rect.x = (start.x + d.dx).clamped(to: 0...(1 - start.width))
				rect.y = (start.y + d.dy).clamped(to: 0...(1 - start.height))
				store.apply("Move blur", coalescing: "stage-\(mask.id)") { project in
					if let i = project.masks.firstIndex(where: { $0.id == mask.id }) { project.masks[i].rect = rect }
				}
			}.onEnded { _ in startRect = nil })
		Handle()
			.position(x: frame.maxX, y: frame.maxY)
			.gesture(DragGesture(minimumDistance: 1).onChanged { drag in
				let start = startRect ?? mask.rect
				startRect = start
				let d = mapper.delta(drag.translation)
				var rect = start
				rect.width = (start.width + d.dx).clamped(to: 0.02...(1 - start.x))
				rect.height = (start.height + d.dy).clamped(to: 0.02...(1 - start.y))
				store.apply("Resize blur", coalescing: "stage-\(mask.id)") { project in
					if let i = project.masks.firstIndex(where: { $0.id == mask.id }) { project.masks[i].rect = rect }
				}
			}.onEnded { _ in startRect = nil })
	}

	@ViewBuilder private func annotationHandles(_ note: AnnotationItem, mapper: StageMapper) -> some View {
		switch note.kind {
		case .text(let label):
			let center = mapper.point(label.position, anchor: note.anchor)
			let height = label.fontSize * size.height * 1.7
			let width = max(40, Double(label.text.count) * label.fontSize * size.height * 0.62 + height * 0.8)
			RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
				.strokeBorder(Theme.lavender, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
				.frame(width: width, height: height)
				.contentShape(Rectangle())
				.position(center)
				.gesture(DragGesture(minimumDistance: 1).onChanged { drag in
					moveAnnotation(note, points: [label.position], drag: drag.translation, mapper: mapper) { kind, points in
						guard case .text(var text) = kind else { return kind }
						text.position = points[0]
						return .text(text)
					}
				}.onEnded { _ in startPoints = [] })
		case .arrow(let arrow):
			let from = mapper.point(arrow.from, anchor: note.anchor)
			let to = mapper.point(arrow.to, anchor: note.anchor)
			Path { path in
				path.move(to: from)
				path.addLine(to: to)
			}
			.stroke(Theme.lavender.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
			.allowsHitTesting(false)
			ForEach(0..<2, id: \.self) { index in
				Handle()
					.position(index == 0 ? from : to)
					.gesture(DragGesture(minimumDistance: 1).onChanged { drag in
						moveAnnotation(note, points: [arrow.from, arrow.to], drag: drag.translation, mapper: mapper) { kind, points in
							guard case .arrow(var value) = kind else { return kind }
							if index == 0 { value.from = points[0] } else { value.to = points[1] }
							return .arrow(value)
						}
					}.onEnded { _ in startPoints = [] })
			}
		}
	}

	private func moveAnnotation(_ note: AnnotationItem, points: [NormPoint], drag: CGSize, mapper: StageMapper, update: @escaping (AnnotationItem.Kind, [NormPoint]) -> AnnotationItem.Kind) {
		if startPoints.isEmpty { startPoints = points }
		let d = mapper.delta(drag, anchor: note.anchor)
		let moved = startPoints.map { NormPoint(x: ($0.x + d.dx).clamped(to: 0...1), y: ($0.y + d.dy).clamped(to: 0...1)) }
		store.apply("Move annotation", coalescing: "stage-\(note.id)") { project in
			if let i = project.annotations.firstIndex(where: { $0.id == note.id }) {
				project.annotations[i].kind = update(project.annotations[i].kind, moved)
			}
		}
	}
}

private struct Handle: View {
	var body: some View {
		RoundedRectangle(cornerRadius: 3, style: .continuous)
			.fill(.white)
			.overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.violet, lineWidth: 1.5))
			.frame(width: 11, height: 11)
			.frame(width: 24, height: 24)
			.contentShape(Rectangle())
	}
}

// MARK: - Transport

struct TransportBar: View {
	let store: ProjectStore

	var body: some View {
		HStack(spacing: 14) {
			MenuChip(title: store.project.style.aspectRatio == .auto ? (store.project.media.screen != nil ? "Auto · screen" : "Auto") : store.project.style.aspectRatio.title) {
				ForEach(AspectRatio.allCases, id: \.self) { aspect in
					Button(aspect.title) { store.apply("Aspect ratio \(aspect.title)") { $0.style.aspectRatio = aspect } }
				}
			}
			Spacer()
			IconButton("backward.end.fill", help: "Go to start") { store.preview.seek(to: 0) }
			Button {
				store.preview.togglePlay()
			} label: {
				Image(systemName: store.preview.isPlaying ? "pause.fill" : "play.fill")
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(Theme.window)
					.frame(width: 36, height: 36)
					.background(Circle().fill(Theme.text1))
			}
			.buttonStyle(.plain)
			.help("Play or pause (Space)")
			IconButton("forward.end.fill", help: "Go to end") { store.preview.seek(to: store.preview.duration) }
			TimeReadout(preview: store.preview)
			Spacer()
			MenuChip(title: Format.rate(Double(store.preview.playbackRate))) {
				ForEach([0.5, 1, 1.5, 2], id: \.self) { rate in
					Button(Format.rate(rate)) { store.preview.playbackRate = Float(rate) }
				}
			}
		}
		.padding(.horizontal, 24)
		.frame(height: 52)
	}
}

private struct TimeReadout: View {
	let preview: PreviewEngine

	var body: some View {
		HStack(spacing: 0) {
			Text(Format.time(preview.currentTime)).foregroundStyle(Theme.text1)
			Text(" / \(Format.time(preview.duration))").foregroundStyle(Theme.text3)
		}
		.font(.nebula(13, 650))
		.monospacedDigit()
		.frame(width: 130, alignment: .leading)
	}
}
