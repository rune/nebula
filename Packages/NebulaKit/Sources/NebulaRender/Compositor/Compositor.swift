import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import NebulaCore
import NebulaPolish

/// Draws one output frame. The single renderer behind preview, frame grabs and export.
///
/// Layer order: background → shadow → recording (camera transform, motion blur, masks,
/// corners, inset) → highlight dimming → annotations → cursor → keycaps → captions.
public final class Compositor: Sendable {
	public static let shared = Compositor()

	let backgrounds = BackgroundRenderer()
	let cursors = CursorArtwork()
	let text = TextArtwork()
	private let shapes = RenderCache<String, CIImage>(limit: 64)

	public init() {}

	public func compose(source: CIImage, outputTime: Double, scene: RenderScene, canvas: CGSize, quality: RenderQuality) -> CIImage {
		let project = scene.project
		let canvasRect = CGRect(origin: .zero, size: canvas)
		let layout = SceneLayout(project: project, canvas: canvas)
		let sourceTime = scene.timeMap.sourceTime(forOutput: outputTime)
		let camera = scene.camera.state(atOutput: outputTime)
		let shortSide = min(canvas.width, canvas.height)

		var frame = backgrounds.image(for: project.style.background, blur: project.style.backgroundBlur, size: canvas, bundleURL: scene.bundleURL)

		// Shadow under the recording.
		let shadow = project.style.shadow
		if shadow.opacity > 0.001, !layout.fillsCanvas {
			let radius = CGFloat(shadow.radius) * shortSide
			let shape = roundedRect(layout.content, radius: layout.cornerRadius, color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(shadow.opacity)))
			let blurred = shape
				.transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(shadow.offsetY) * shortSide))
				.clampedToExtent()
				.applyingGaussianBlur(sigma: max(0.1, radius / 2))
				.cropped(to: canvasRect)
			frame = blurred.composited(over: frame)
		}

		// The recording, framed by the camera.
		let transform = layout.videoTransform(for: camera)
		var video = source.transformed(by: transform)
		if quality.motionBlur, project.camera.motionBlur > 0.01 {
			video = applyCameraBlur(video, scene: scene, layout: layout, camera: camera, outputTime: outputTime)
		}
		video = video.cropped(to: layout.content)

		for mask in project.masks where mask.range.contains(sourceTime) {
			video = applyMask(mask, to: video, layout: layout, camera: camera)
		}

		let contentMask = roundedRect(layout.content, radius: layout.cornerRadius, color: .white)
		video = video.applyingFilter("CIBlendWithAlphaMask", parameters: [
			kCIInputBackgroundImageKey: CIImage.empty(),
			kCIInputMaskImageKey: contentMask,
		])
		frame = video.composited(over: frame)

		if project.style.inset > 0.0005, !layout.fillsCanvas {
			let width = CGFloat(project.style.inset) * shortSide
			let stroke = CIFilter.roundedRectangleStrokeGenerator()
			stroke.extent = layout.content.insetBy(dx: width / 2, dy: width / 2)
			stroke.radius = Float(max(0, layout.cornerRadius - width / 2))
			stroke.width = Float(width)
			stroke.color = project.style.insetColor.ciColor
			if let border = stroke.outputImage { frame = border.composited(over: frame) }
		}

		for mask in project.masks where mask.range.contains(sourceTime) {
			if case .highlight(let amount) = mask.kind {
				frame = applyHighlight(mask, amount: amount, to: frame, layout: layout, camera: camera, canvas: canvasRect)
			}
		}

		frame = drawAnnotations(on: frame, scene: scene, layout: layout, camera: camera, sourceTime: sourceTime, outputTime: outputTime)
		frame = drawCursor(on: frame, scene: scene, layout: layout, camera: camera, sourceTime: sourceTime, quality: quality)
		var bottomInset = shortSide * 0.045
		frame = drawKeycaps(on: frame, scene: scene, canvas: canvas, sourceTime: sourceTime, bottomInset: &bottomInset)
		frame = drawCaptions(on: frame, scene: scene, canvas: canvas, sourceTime: sourceTime, bottomInset: bottomInset)
		return frame.cropped(to: canvasRect)
	}

	// MARK: - Recording effects

	private func applyCameraBlur(_ video: CIImage, scene: RenderScene, layout: SceneLayout, camera: CameraState, outputTime: Double) -> CIImage {
		let velocity = scene.camera.velocity(atOutput: outputTime)
		let strength = scene.project.camera.motionBlur
		// Half a 60 fps frame of shutter, scaled by the user's motion blur amount.
		let shutter = 0.5 / 60 * strength * 2
		let pixelsPerUnit = layout.magnification(for: camera) * layout.videoSize.width
		let panX = velocity.dx * pixelsPerUnit
		let panY = velocity.dy * Double(layout.magnification(for: camera) * layout.videoSize.height)
		let panLength = hypot(panX, panY) * shutter
		var image = video
		// Subtle on purpose: enough to smooth fast moves, never enough to smear text.
		if panLength > 2 {
			image = image.clampedToExtent()
				.applyingFilter("CIMotionBlur", parameters: [
					kCIInputRadiusKey: min(panLength / 3, 16),
					kCIInputAngleKey: atan2(panY, -panX),
				])
				.cropped(to: video.extent)
		}
		let zoomAmount = abs(velocity.dLogScale) * Double(layout.content.width) * shutter * 0.12
		if zoomAmount > 1.5 {
			image = image.clampedToExtent()
				.applyingFilter("CIZoomBlur", parameters: [
					kCIInputCenterKey: CIVector(x: layout.content.midX, y: layout.content.midY),
					"inputAmount": min(zoomAmount, 8),
				])
				.cropped(to: video.extent)
		}
		return image
	}

	private func applyMask(_ mask: MaskItem, to video: CIImage, layout: SceneLayout, camera: CameraState) -> CIImage {
		let rect = layout.canvasRect(for: mask.rect, camera: camera).intersection(layout.content)
		guard rect.width > 1, rect.height > 1 else { return video }
		let radius = CGFloat(mask.cornerRadius.clamped(to: 0...0.5)) * min(rect.width, rect.height)
		let effect: CIImage
		switch mask.kind {
		case .blur(let amount):
			effect = video.clampedToExtent().applyingGaussianBlur(sigma: 4 + amount * 0.02 * Double(layout.content.width) * 0.6)
		case .pixelate(let amount):
			effect = video.clampedToExtent().applyingFilter("CIPixellate", parameters: [
				kCIInputScaleKey: max(6, amount * 0.03 * Double(layout.content.width)),
				kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
			])
		case .highlight:
			return video
		}
		let shape = roundedRect(rect, radius: radius, color: .white)
		return effect.cropped(to: rect).applyingFilter("CIBlendWithAlphaMask", parameters: [
			kCIInputBackgroundImageKey: video,
			kCIInputMaskImageKey: shape,
		]).cropped(to: video.extent)
	}

	private func applyHighlight(_ mask: MaskItem, amount: Double, to frame: CIImage, layout: SceneLayout, camera: CameraState, canvas: CGRect) -> CIImage {
		let rect = layout.canvasRect(for: mask.rect, camera: camera)
		let radius = CGFloat(mask.cornerRadius.clamped(to: 0...0.5)) * min(rect.width, rect.height)
		let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(amount.clamped(to: 0...1)))).cropped(to: layout.content)
		let hole = roundedRect(rect, radius: radius, color: .white)
		let darkness = CIImage.empty().applyingFilter("CIBlendWithAlphaMask", parameters: [
			kCIInputBackgroundImageKey: dim,
			kCIInputMaskImageKey: hole,
		])
		return darkness.composited(over: frame)
	}

	// MARK: - Overlays

	private func drawAnnotations(on frame: CIImage, scene: RenderScene, layout: SceneLayout, camera: CameraState, sourceTime: Double, outputTime: Double) -> CIImage {
		var frame = frame
		let canvasHeight = layout.canvas.height
		for annotation in scene.project.annotations where annotation.range.contains(sourceTime) {
			let startOutput = scene.timeMap.outputTime(forSource: annotation.range.start) ?? outputTime
			let age = max(0, outputTime - startOutput)
			let remaining = max(0, (scene.timeMap.outputTime(forSource: annotation.range.end) ?? .infinity) - outputTime)
			let anchor: (NormPoint) -> CGPoint = { point in
				annotation.anchor == .screen ? layout.canvasPoint(for: point, camera: camera) : layout.canvasPoint(forCanvas: point)
			}
			let zoom = annotation.anchor == .screen ? CGFloat(camera.scale) : 1
			switch annotation.kind {
			case .text(let label):
				let size = CGFloat(label.fontSize) * canvasHeight * zoom
				guard let art = text.label(label.text, fontSize: size, color: label.color, background: label.background, bold: label.bold, maxWidth: layout.canvas.width * 0.8) else { continue }
				let (opacity, scale, lift) = animation(label.animation, age: age, remaining: remaining)
				let center = anchor(label.position)
				var image = art.image
					.transformed(by: CGAffineTransform(translationX: -art.size.width / 2, y: -art.size.height / 2))
					.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
					.transformed(by: CGAffineTransform(translationX: center.x, y: center.y - lift * size))
				image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
				frame = image.composited(over: frame)
			case .arrow(let arrow):
				let width = CGFloat(arrow.width) * canvasHeight * zoom
				guard let (art, origin) = text.arrow(from: anchor(arrow.from), to: anchor(arrow.to), color: arrow.color, width: width) else { continue }
				let opacity = min(1, age / 0.2, remaining / 0.2)
				let image = art.image
					.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
					.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
				frame = image.composited(over: frame)
			}
		}
		return frame
	}

	private func animation(_ kind: TextAnimation, age: Double, remaining: Double) -> (opacity: CGFloat, scale: CGFloat, lift: CGFloat) {
		let fadeOut = CGFloat(min(1, remaining / 0.2))
		let t = min(1, age / 0.28)
		let ease = 1 - pow(1 - t, 3)
		switch kind {
		case .none: return (fadeOut, 1, 0)
		case .fade: return (CGFloat(ease) * fadeOut, 1, 0)
		case .pop:
			let overshoot = 1 + 0.08 * sin(t * .pi)
			return (CGFloat(min(1, age / 0.12)) * fadeOut, CGFloat(0.86 + 0.14 * ease) * CGFloat(overshoot), 0)
		case .rise: return (CGFloat(ease) * fadeOut, 1, CGFloat(1 - ease) * 0.5)
		}
	}

	private func drawCursor(on frame: CIImage, scene: RenderScene, layout: SceneLayout, camera: CameraState, sourceTime: Double, quality: RenderQuality) -> CIImage {
		let settings = scene.project.cursor
		guard settings.visible, let state = scene.cursor.state(at: sourceTime), state.shape >= 0, state.opacity > 0.01 else { return frame }
		var frame = frame
		let pixelsPerPoint = layout.magnification(for: camera) * CGFloat(scene.input.scale) * CGFloat(settings.size)

		if let progress = state.clickProgress, let point = state.clickPoint, settings.clickEffect != .none {
			let center = layout.canvasPoint(for: point, camera: camera)
			if let ring = clickEffect(settings.clickEffect, progress: progress, pixelsPerPoint: pixelsPerPoint, color: settings.clickColor) {
				frame = ring.transformed(by: CGAffineTransform(translationX: center.x - ring.extent.width / 2, y: center.y - ring.extent.height / 2)).composited(over: frame)
			}
		}

		let shapes = scene.input.cursorShapes
		let shape = state.shape < shapes.count ? shapes[state.shape] : CursorShape(kind: .arrow)
		guard let art = cursors.image(for: shape, pixelsPerPoint: pixelsPerPoint) else { return frame }
		let tip = layout.canvasPoint(for: state.position, camera: camera)
		let scale = CGFloat(state.pressScale)
		var cursor = art.image
			.transformed(by: CGAffineTransform(translationX: -art.hotspot.x, y: -art.hotspot.y))
			.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		if quality.motionBlur, scene.project.camera.motionBlur > 0.01 {
			let speed = hypot(state.velocity.dx * Double(layout.content.width) * Double(camera.scale), state.velocity.dy * Double(layout.content.height) * Double(camera.scale))
			let length = speed * (0.5 / 60) * scene.project.camera.motionBlur * 2
			if length > 2 {
				let angle = atan2(state.velocity.dy, -state.velocity.dx)
				let extent = cursor.extent
				cursor = cursor.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: min(length / 2, 36), kCIInputAngleKey: angle])
					.cropped(to: extent.insetBy(dx: -40, dy: -40))
			}
		}
		cursor = cursor
			.transformed(by: CGAffineTransform(translationX: tip.x, y: tip.y))
			.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity)])
		return cursor.composited(over: frame)
	}

	private func clickEffect(_ effect: CursorSettings.ClickEffect, progress: Double, pixelsPerPoint: CGFloat, color: ColorValue) -> CIImage? {
		let step = Int((progress * 24).rounded())
		let maxRadius = 22 * pixelsPerPoint
		let key = "click|\(effect.rawValue)|\(step)|\(Int(maxRadius))|\(color.hex)"
		return shapes.value(for: key) {
			let t = Double(step) / 24
			let ease = 1 - pow(1 - t, 3)
			let size = CGSize(width: ceil(maxRadius * 2 + 8), height: ceil(maxRadius * 2 + 8))
			return TextArtwork.draw(size: size) { context in
				let center = CGPoint(x: size.width / 2, y: size.height / 2)
				switch effect {
				case .ripple:
					let radius = maxRadius * CGFloat(0.25 + 0.75 * ease)
					context.setStrokeColor(color.withAlpha(0.85 * (1 - t)).cgColor)
					context.setLineWidth(max(1.5, pixelsPerPoint * 2.2 * CGFloat(1 - t * 0.6)))
					context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
					context.strokePath()
					context.setFillColor(color.withAlpha(0.22 * (1 - t)).cgColor)
					context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
					context.fillPath()
				case .circle:
					let radius = maxRadius * 0.55 * CGFloat(1 - 0.35 * ease)
					context.setFillColor(color.withAlpha(0.45 * (1 - t)).cgColor)
					context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
					context.fillPath()
				case .none:
					break
				}
			}?.image
		}
	}

	private func drawKeycaps(on frame: CIImage, scene: RenderScene, canvas: CGSize, sourceTime: Double, bottomInset: inout CGFloat) -> CIImage {
		let settings = scene.project.shortcutOverlay
		guard settings.enabled, let press = scene.shortcuts.last(where: { $0.t <= sourceTime && sourceTime - $0.t < 1.4 }) else { return frame }
		let age = sourceTime - press.t
		let opacity = CGFloat(min(1, age / 0.1, (1.4 - age) / 0.25))
		let height = CGFloat(settings.size) * canvas.height
		guard let art = text.keycaps(press.keys, height: height) else { return frame }
		let margin = min(canvas.width, canvas.height) * 0.045
		let x: CGFloat = switch settings.position {
		case .bottomLeft: margin
		case .bottomRight: canvas.width - margin - art.size.width
		case .bottomCenter, .topCenter: (canvas.width - art.size.width) / 2
		}
		let y = settings.position == .topCenter ? canvas.height - margin - art.size.height : bottomInset
		if settings.position != .topCenter { bottomInset += art.size.height + margin * 0.5 }
		let lift = (1 - min(1, CGFloat(age) / 0.15)) * height * 0.2
		let image = art.image
			.transformed(by: CGAffineTransform(translationX: x, y: y - lift))
			.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
		return image.composited(over: frame)
	}

	private func drawCaptions(on frame: CIImage, scene: RenderScene, canvas: CGSize, sourceTime: Double, bottomInset: CGFloat) -> CIImage {
		guard let track = scene.project.captions, track.enabled,
			let line = scene.captionLines.first(where: { $0.range.contains(sourceTime) }) else { return frame }
		let style = track.style
		let fontSize = CGFloat(style.fontSize) * canvas.height
		let words = line.words.isEmpty ? line.text.split(separator: " ").map(String.init) : line.words.map(\.text)
		let highlight = line.words.firstIndex { $0.range.contains(sourceTime) }
		let shown: [String]
		let highlighted: Int?
		switch style.mode {
		case .line:
			shown = words
			highlighted = highlight
		case .word:
			let index = highlight ?? line.words.lastIndex { $0.range.start <= sourceTime } ?? 0
			shown = words.isEmpty ? [] : [words[min(index, words.count - 1)]]
			highlighted = nil
		}
		guard !shown.isEmpty,
			let art = text.caption(words: shown, highlight: highlighted, style: style, fontSize: style.mode == .word ? fontSize * 1.6 : fontSize, maxWidth: canvas.width * 0.82)
		else { return frame }
		let x = (canvas.width - art.size.width) / 2
		let y = style.position == .top ? canvas.height - min(canvas.width, canvas.height) * 0.06 - art.size.height : bottomInset
		return art.image.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: frame)
	}

	// MARK: - Shapes

	private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
		let generator = CIFilter.roundedRectangleGenerator()
		generator.extent = rect
		generator.radius = Float(max(0, min(radius, min(rect.width, rect.height) / 2)))
		generator.color = color
		return generator.outputImage ?? CIImage.empty()
	}
}
