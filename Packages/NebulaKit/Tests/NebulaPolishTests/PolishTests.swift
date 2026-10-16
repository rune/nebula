import Foundation
import NebulaCore
import Testing
@testable import NebulaPolish

/// A synthetic 30 s recording: cursor moves 0–6 s and clicks at 4 s near the top-left; idle
/// 6–14 s; types 14–20 s into a field at the bottom; clicks at 22 s near the right; idle to 30 s.
func makeInput() -> InputTrack {
	var input = InputTrack()
	for i in 0...60 {
		let t = Double(i) * 0.1
		input.cursor.append(CursorSample(t: t, x: 0.1 + t * 0.02, y: 0.2))
	}
	input.cursor.append(CursorSample(t: 14, x: 0.5, y: 0.85))
	for i in 0...40 {
		let t = 20 + Double(i) * 0.05
		input.cursor.append(CursorSample(t: t, x: 0.5 + Double(i) * 0.008, y: 0.85 - Double(i) * 0.01))
	}
	input.clicks = [ClickEvent(t: 4, x: 0.18, y: 0.2, upT: 4.1), ClickEvent(t: 22, x: 0.82, y: 0.45, upT: 22.1)]
	input.keys = stride(from: 14.0, to: 20.0, by: 0.15).map { KeyEvent(t: $0, kind: .typing) }
	input.focus = [FocusEvent(t: 13.8, rect: NormRect(x: 0.3, y: 0.8, width: 0.4, height: 0.06))]
	return input
}

func makeProject() -> Project {
	Project(name: "Test", media: MediaInfo(duration: 30, width: 2880, height: 1800))
}

@Suite("Polish planner")
struct PolishPlannerTests {
	@Test func zoomsOnClicksAndTyping() {
		let plan = PolishPlanner.plan(project: makeProject(), input: makeInput(), signals: PolishSignals(), options: PolishOptions())
		#expect(plan.zooms.count == 3)
		let typing = plan.zooms.first { $0.range.contains(16) }
		guard case .rect(let rect)? = typing?.target else {
			Issue.record("typing zoom should frame the focused field, got \(String(describing: typing?.target))")
			return
		}
		#expect(rect.contains(NormPoint(x: 0.5, y: 0.83)))
		#expect(plan.zooms.allSatisfy { $0.source == .polish && ZoomItem.scaleRange.contains($0.scale) })
	}

	@Test func cutsDeadAirAndTrimsEnds() {
		var options = PolishOptions()
		options.deadAirMinimum = 2
		let signals = PolishSignals(frameActivity: ActivitySeries(interval: 1, values: Array(repeating: 0, count: 30)))
		let plan = PolishPlanner.plan(project: makeProject(), input: makeInput(), signals: signals, options: options)
		// The 6–14 s idle stretch is cut (with padding) and the tail after the last click is trimmed.
		#expect(plan.cuts.contains { $0.range.start > 6 && $0.range.end < 14 && $0.range.duration > 5 })
		#expect(plan.cuts.contains { $0.range.end == 30 })
	}

	@Test func speedsUpTypingUnlessSomeoneTalks() {
		let quiet = PolishPlanner.plan(project: makeProject(), input: makeInput(), signals: PolishSignals(), options: PolishOptions())
		#expect(quiet.speeds.count == 1)
		#expect(quiet.speeds.first.map { $0.range.start >= 13.9 && $0.range.end <= 20.4 } == true)

		let talking = PolishPlanner.plan(
			project: makeProject(), input: makeInput(),
			signals: PolishSignals(speech: [TimeRange(start: 13, end: 21)]), options: PolishOptions()
		)
		#expect(talking.speeds.isEmpty)
	}

	@Test func applyReplacesOnlyPolishItems() {
		var project = makeProject()
		project.zooms = [ZoomItem(range: TimeRange(start: 25, end: 27), source: .user), ZoomItem(range: TimeRange(start: 1, end: 2), source: .polish)]
		let plan = PolishPlanner.plan(project: project, input: makeInput(), signals: PolishSignals(), options: PolishOptions())
		PolishPlanner.apply(plan, to: &project, options: PolishOptions())
		#expect(project.zooms.contains { $0.source == .user })
		#expect(!project.zooms.contains { $0.range == TimeRange(start: 1, end: 2) })
		#expect(project.zooms.filter { $0.source == .polish }.allSatisfy { !$0.range.overlaps(TimeRange(start: 25, end: 27)) })
	}
}

@Suite("Camera and cursor paths")
struct PathTests {
	@Test func cameraSettlesOnZoomAndReturns() {
		var project = makeProject()
		project.zooms = [ZoomItem(range: TimeRange(start: 5, end: 10), target: .point(NormPoint(x: 0.3, y: 0.3)), scale: 2)]
		let camera = CameraPath(project: project, cursor: CursorPath(input: .empty, settings: CursorSettings(), duration: 30))
		#expect(camera.state(atOutput: 2) == .identity)
		let zoomed = camera.state(atOutput: 9)
		#expect(abs(zoomed.scale - 2) < 0.02)
		#expect(abs(zoomed.center.x - 0.3) < 0.01)
		let after = camera.state(atOutput: 14)
		#expect(abs(after.scale - 1) < 0.02)
	}

	@Test func cameraNeverShowsOutsideTheRecording() {
		var project = makeProject()
		project.zooms = [ZoomItem(range: TimeRange(start: 1, end: 4), target: .point(NormPoint(x: 0.02, y: 0.98)), scale: 3)]
		let camera = CameraPath(project: project, cursor: CursorPath(input: .empty, settings: CursorSettings(), duration: 30))
		for t in stride(from: 0.0, to: 6, by: 0.05) {
			let view = camera.state(atOutput: t).viewRect
			#expect(view.x >= -1e-9 && view.y >= -1e-9 && view.maxX <= 1 + 1e-9 && view.maxY <= 1 + 1e-9)
		}
	}

	@Test func instantZoomsSnap() {
		var project = makeProject()
		project.zooms = [ZoomItem(range: TimeRange(start: 5, end: 10), target: .point(.center), scale: 2, transition: .instant)]
		let camera = CameraPath(project: project, cursor: CursorPath(input: .empty, settings: CursorSettings(), duration: 30))
		#expect(abs(camera.state(atOutput: 5.02).scale - 2) < 0.01)
	}

	@Test func cursorFadesWhenIdleAndPinsClicks() {
		let cursor = CursorPath(input: makeInput(), settings: CursorSettings(), duration: 30)
		#expect((cursor.state(at: 3)?.opacity ?? 0) > 0.99)
		#expect((cursor.state(at: 11)?.opacity ?? 1) < 0.01)
		let atClick = cursor.state(at: 4)
		#expect(atClick?.position.distance(to: NormPoint(x: 0.18, y: 0.2)) ?? 1 < 0.01)
		#expect(cursor.state(at: 4.1)?.clickProgress != nil)
	}
}
