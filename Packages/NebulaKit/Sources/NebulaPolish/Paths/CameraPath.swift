import Foundation
import NebulaCore

/// Where the virtual camera looks: `center` of the view in normalized video coordinates and
/// `scale` (1 = whole recording, 2 = half the width visible).
public struct CameraState: Sendable, Equatable {
	public var center: NormPoint
	public var scale: Double

	public init(center: NormPoint = .center, scale: Double = 1) {
		self.center = center
		self.scale = scale
	}

	public static let identity = CameraState()

	/// The visible part of the recording.
	public var viewRect: NormRect {
		let size = 1 / scale
		return NormRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
	}

	/// Keeps the view inside the recording.
	func clamped() -> CameraState {
		let half = 0.5 / max(scale, 1)
		return CameraState(
			center: NormPoint(x: center.x.clamped(to: half...(1 - half)), y: center.y.clamped(to: half...(1 - half))),
			scale: max(scale, 1)
		)
	}
}

/// The camera animated over the *output* timeline, so springs feel the same after cuts and
/// speed changes. Precomputed per project change; frames look it up.
public struct CameraPath: Sendable {
	public static let sampleRate = 120.0

	let states: [CameraState]

	public init(project: Project, cursor: CursorPath) {
		let map = project.timeMap
		let count = Int((map.outputDuration * Self.sampleRate).rounded(.up)) + 1
		let dt = 1 / Self.sampleRate
		let spring = project.camera.spring
		var x = Spring(tension: spring.tension, friction: spring.friction, value: 0.5)
		var y = Spring(tension: spring.tension, friction: spring.friction, value: 0.5)
		var logScale = Spring(tension: spring.tension, friction: spring.friction, value: 0)
		let deadzone = project.camera.followDeadzone.clamped(to: 0.1...0.95)
		let zooms = project.zooms.sorted { $0.range.start < $1.range.start }

		var states: [CameraState] = []
		states.reserveCapacity(max(count, 1))
		var activeID: ItemID?
		var followCenter = NormPoint.center
		var lastCursor = NormPoint.center

		for i in 0..<max(count, 1) {
			let outputTime = Double(i) * dt
			let sourceTime = map.sourceTime(forOutput: outputTime)
			let zoom = zooms.last { $0.range.contains(sourceTime) }
			if let position = cursor.state(at: sourceTime)?.position { lastCursor = position }

			var target = CameraState.identity
			if let zoom {
				let scale = zoom.scale.clamped(to: ZoomItem.scaleRange)
				switch zoom.target {
				case .point(let point):
					target = CameraState(center: point, scale: scale)
				case .rect(let rect):
					let fit = 0.82 / max(rect.width, rect.height, 0.05)
					target = CameraState(center: rect.center, scale: min(scale, fit).clamped(to: 1.15...5))
				case .follow:
					if activeID != zoom.id { followCenter = lastCursor }
					// Pan only when the cursor leaves the dead zone, then just enough to keep it inside.
					let half = 0.5 / scale * deadzone
					if lastCursor.x > followCenter.x + half { followCenter.x = lastCursor.x - half }
					if lastCursor.x < followCenter.x - half { followCenter.x = lastCursor.x + half }
					if lastCursor.y > followCenter.y + half { followCenter.y = lastCursor.y - half }
					if lastCursor.y < followCenter.y - half { followCenter.y = lastCursor.y + half }
					target = CameraState(center: followCenter, scale: scale)
				}
			}
			target = target.clamped()

			let entering = zoom?.id != activeID
			let instant = entering && ((zoom?.transition == .instant) || (zoom == nil && zooms.first { $0.id == activeID }?.transition == .instant))
			if instant || i == 0 && zoom != nil && zoom?.transition == .instant {
				x.snap(to: target.center.x)
				y.snap(to: target.center.y)
				logScale.snap(to: log(target.scale))
			} else {
				x.step(toward: target.center.x, dt: dt)
				y.step(toward: target.center.y, dt: dt)
				logScale.step(toward: log(target.scale), dt: dt)
			}
			activeID = zoom?.id
			states.append(CameraState(center: NormPoint(x: x.value, y: y.value), scale: exp(logScale.value)).clamped())
		}
		self.states = states
	}

	/// Camera at an output time.
	public func state(atOutput time: Double) -> CameraState {
		guard states.count > 1 else { return states.first ?? .identity }
		let f = (time * Self.sampleRate).clamped(to: 0...Double(states.count - 1))
		let i = Int(f)
		let j = min(i + 1, states.count - 1)
		let w = f - Double(i)
		let a = states[i]
		let b = states[j]
		return CameraState(
			center: NormPoint(x: a.center.x + (b.center.x - a.center.x) * w, y: a.center.y + (b.center.y - a.center.y) * w),
			scale: a.scale + (b.scale - a.scale) * w
		)
	}

	/// Rate of change per second at an output time: pan in normalized units, zoom in log-scale units.
	public func velocity(atOutput time: Double) -> (dx: Double, dy: Double, dLogScale: Double) {
		let h = 1 / Self.sampleRate
		let a = state(atOutput: max(0, time - h))
		let b = state(atOutput: time + h)
		return ((b.center.x - a.center.x) / (2 * h), (b.center.y - a.center.y) / (2 * h), (log(b.scale) - log(a.scale)) / (2 * h))
	}
}
