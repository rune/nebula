import CoreGraphics
import Foundation
import NebulaCore
import NebulaPolish

/// Geometry of one output frame. Core Image coordinates: origin bottom-left, in output pixels.
public struct SceneLayout: Sendable {
	public let canvas: CGSize
	/// Where the recording sits on the canvas (before shadow).
	public let content: CGRect
	public let cornerRadius: CGFloat
	public let videoSize: CGSize
	let crop: NormRect

	/// Output size for a project at a given short-side resolution (even dimensions).
	public static func canvasSize(for project: Project, shortSide: Int) -> CGSize {
		let cropAspect = project.media.aspect * project.style.crop.width / max(project.style.crop.height, 0.01)
		let aspect = project.style.aspectRatio.value ?? cropAspect
		let short = Double(shortSide)
		let size = aspect >= 1 ? CGSize(width: short * aspect, height: short) : CGSize(width: short, height: short / aspect)
		return CGSize(width: (size.width / 2).rounded() * 2, height: (size.height / 2).rounded() * 2)
	}

	public init(project: Project, canvas: CGSize) {
		self.canvas = canvas
		self.videoSize = CGSize(width: project.media.width, height: project.media.height)
		self.crop = project.style.crop
		let shortSide = min(canvas.width, canvas.height)
		let pad = CGFloat(project.style.padding.clamped(to: 0...0.4)) * shortSide
		let available = CGRect(origin: .zero, size: canvas).insetBy(dx: pad, dy: pad)
		let cropAspect = CGFloat(project.media.aspect * crop.width / max(crop.height, 0.01))
		var size = available.size
		if size.width / max(size.height, 1) > cropAspect {
			size.width = size.height * cropAspect
		} else {
			size.height = size.width / cropAspect
		}
		content = CGRect(
			x: ((canvas.width - size.width) / 2).rounded(),
			y: ((canvas.height - size.height) / 2).rounded(),
			width: size.width.rounded(),
			height: size.height.rounded()
		)
		cornerRadius = CGFloat(project.style.cornerRadius.clamped(to: 0...0.1)) * shortSide
	}

	/// The part of the recording shown for a camera state, in normalized (top-left) coordinates.
	/// Camera scale 1 shows the whole crop; the view stays inside the crop.
	public func visibleRect(for camera: CameraState) -> NormRect {
		let width = crop.width / camera.scale
		let height = crop.height / camera.scale
		let x = (camera.center.x - width / 2).clamped(to: crop.x...(crop.maxX - width))
		let y = (camera.center.y - height / 2).clamped(to: crop.y...(crop.maxY - height))
		return NormRect(x: x, y: y, width: width, height: height)
	}

	/// Transform from source video pixels (Core Image, bottom-left origin) to canvas pixels.
	public func videoTransform(for camera: CameraState) -> CGAffineTransform {
		let visible = visibleRect(for: camera)
		let sourceRect = CGRect(
			x: visible.x * videoSize.width,
			y: (1 - visible.maxY) * videoSize.height,
			width: visible.width * videoSize.width,
			height: visible.height * videoSize.height
		)
		let sx = content.width / sourceRect.width
		let sy = content.height / sourceRect.height
		return CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY)
			.concatenating(CGAffineTransform(scaleX: sx, y: sy))
			.concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
	}

	/// Canvas point for a normalized (top-left origin) point on the recording.
	public func canvasPoint(for point: NormPoint, camera: CameraState) -> CGPoint {
		let source = CGPoint(x: point.x * videoSize.width, y: (1 - point.y) * videoSize.height)
		return source.applying(videoTransform(for: camera))
	}

	/// Canvas rect for a normalized rect on the recording.
	public func canvasRect(for rect: NormRect, camera: CameraState) -> CGRect {
		let a = canvasPoint(for: NormPoint(x: rect.x, y: rect.y), camera: camera)
		let b = canvasPoint(for: NormPoint(x: rect.maxX, y: rect.maxY), camera: camera)
		return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
	}

	/// Canvas point for a normalized point on the output frame (top-left origin).
	public func canvasPoint(forCanvas point: NormPoint) -> CGPoint {
		CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
	}

	/// Output pixels per source pixel at a camera state (how much the recording is magnified).
	public func magnification(for camera: CameraState) -> CGFloat {
		content.width / (visibleRect(for: camera).width * videoSize.width)
	}
}
