import Foundation
import Testing
@testable import NebulaCore

@Suite("TimeMap")
struct TimeMapTests {
	@Test func identityWithoutEdits() {
		let map = TimeMap(duration: 10, cuts: [], speeds: [])
		#expect(map.outputDuration == 10)
		#expect(map.outputTime(forSource: 4) == 4)
		#expect(map.sourceTime(forOutput: 7) == 7)
	}

	@Test func cutsAndSpeedsMapBothWays() {
		let map = TimeMap(
			duration: 10,
			cuts: [CutItem(range: TimeRange(start: 2, end: 4))],
			speeds: [SpeedItem(range: TimeRange(start: 6, end: 10), rate: 2)]
		)
		// 0–2 kept, 2–4 cut, 4–6 kept, 6–10 at 2x → 2 + 2 + 2 = 6s
		#expect(map.outputDuration == 6)
		#expect(map.outputTime(forSource: 3) == nil)
		#expect(map.outputTime(forSource: 5) == 3)
		#expect(map.outputTime(forSource: 8) == 5)
		#expect(map.sourceTime(forOutput: 5) == 8)
		#expect(map.nearestKeptSourceTime(to: 3) == 4)
		#expect(map.rate(atSource: 7) == 2)
	}

	@Test func overlappingCutsMerge() {
		let map = TimeMap(
			duration: 10,
			cuts: [CutItem(range: TimeRange(start: 1, end: 5)), CutItem(range: TimeRange(start: 4, end: 6))],
			speeds: []
		)
		#expect(map.outputDuration == 5)
	}
}

@Suite("Geometry")
struct GeometryTests {
	@Test func rangeSetOperations() {
		let a = [TimeRange(start: 0, end: 10)]
		#expect(TimeRange.subtract(a, [TimeRange(start: 2, end: 3)]) == [TimeRange(start: 0, end: 2), TimeRange(start: 3, end: 10)])
		#expect(TimeRange.intersect(a, [TimeRange(start: 5, end: 15)]) == [TimeRange(start: 5, end: 10)])
	}

	@Test func colorHexRoundTrip() throws {
		let color = try #require(ColorValue(hex: "#8C28FF"))
		#expect(color.hex == "#8C28FF")
		#expect(ColorValue(hex: "#00000080")?.alpha == 128.0 / 255.0)
		#expect(ColorValue(hex: "nope") == nil)
	}

	@Test func rectClampsInsideUnitSquare() {
		let rect = NormRect(x: 0.9, y: -0.2, width: 0.5, height: 0.5).clamped()
		#expect(rect.maxX <= 1 && rect.y >= 0)
	}
}

@Suite("Project bundle")
struct ProjectBundleTests {
	@Test func projectRoundTripsThroughDisk() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "nebula-test-\(UUID().uuidString).nebula")
		defer { try? FileManager.default.removeItem(at: dir) }
		let bundle = ProjectBundle(url: dir)
		var project = Project(name: "Demo", media: MediaInfo(duration: 12, width: 3024, height: 1964))
		project.zooms = [ZoomItem(range: TimeRange(start: 1, end: 3), target: .rect(NormRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1)))]
		project.annotations = [AnnotationItem(range: TimeRange(start: 0, end: 2), kind: .text(TextAnnotation(text: "Hi", position: .center)))]
		project.style.background = .gradient(GradientFill(colors: [.violet, .black]))
		project.media.screen = ScreenGeometry(width: 3024, height: 1964, captureRect: NormRect(x: 0.1, y: 0.1, width: 0.6, height: 0.7))
		try bundle.write(project)
		try bundle.write(InputTrack(cursor: [CursorSample(t: 0, x: 0.5, y: 0.5)]))
		#expect(try bundle.readProject() == project)
		#expect(bundle.readInput().cursor.count == 1)
	}

	@Test func libraryCreatesUniqueBundles() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "nebula-lib-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let library = ProjectLibrary(rootURL: root)
		let a = try library.newBundle(named: "Take")
		let b = try library.newBundle(named: "Take")
		#expect(a.url != b.url)
	}
}

@Suite("OpenScreen import")
struct OpenScreenImportTests {
	let projectJSON = """
		{"version":2,"media":{"screenVideoPath":"/tmp/rec.mp4"},"editor":{
		"wallpaper":"/wallpapers/wallpaper3.jpg","padding":50,"borderRadius":14,"aspectRatio":"16:9",
		"zoomRegions":[{"id":"zoom-1","startMs":1000,"endMs":3000,"depth":3,"customScale":2.5,"focus":{"cx":0.3,"cy":0.4}}],
		"trimRegions":[{"id":"trim-1","startMs":0,"endMs":500}],
		"speedRegions":[{"id":"speed-1","startMs":4000,"endMs":6000,"speed":2}],
		"annotationRegions":[{"id":"a1","startMs":0,"endMs":1000,"type":"text","content":"Hello","position":{"x":10,"y":10},"size":{"width":30,"height":10}},
		{"id":"a2","startMs":0,"endMs":1000,"type":"blur","position":{"x":0,"y":0},"size":{"width":20,"height":5},"blurData":{"type":"mosaic"}}]}}
		"""
	let cursorJSON = """
		{"version":2,"samples":[{"timeMs":0,"cx":0.5,"cy":0.5,"interactionType":"move"},
		{"timeMs":100,"cx":0.6,"cy":0.5,"interactionType":"click","cursorType":"pointer"},
		{"timeMs":150,"cx":0.6,"cy":0.5,"interactionType":"mouseup"}]}
		"""

	@Test func convertsTimelineStyleAndCursor() throws {
		let result = try OpenScreenImporter.convert(
			projectData: Data(projectJSON.utf8),
			cursorData: Data(cursorJSON.utf8),
			media: MediaInfo(duration: 10, width: 1920, height: 1080),
			name: "Imported"
		)
		let project = result.project
		#expect(result.sourceVideoPath == "/tmp/rec.mp4")
		#expect(project.cuts.map(\.range) == [TimeRange(start: 0, end: 0.5)])
		#expect(project.speeds.first?.rate == 2)
		#expect(project.zooms.first?.scale == 2.5)
		#expect(project.zooms.first?.target == .point(NormPoint(x: 0.3, y: 0.4)))
		#expect(project.annotations.count == 1)
		#expect(project.masks.first?.kind == .pixelate(amount: 0.6))
		#expect(project.style.aspectRatio == .wide)
		#expect(project.style.background == Style().background)
		#expect(project.style.placement == .fit)
		#expect(result.input.cursor.count == 3)
		#expect(result.input.clicks.count == 1)
		#expect(result.input.clicks.first?.upT == 0.15)
		#expect(result.input.cursorShapes.contains { $0.kind == .pointer })
	}
}
