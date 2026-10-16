import CoreImage
import CoreVideo
import Foundation
import NebulaCore
import NebulaPolish
import Testing
@testable import NebulaRender

/// Per-frame compositor cost. Run with NEBULA_BENCH=1; prints milliseconds per frame.
@Suite("Performance", .enabled(if: ProcessInfo.processInfo.environment["NEBULA_BENCH"] != nil))
struct PerformanceTests {
	private func frameTime(_ project: Project, canvas: CGSize, frames: Int = 120) throws -> Double {
		let scene = RenderScene(project: project, input: .empty, bundleURL: nil)
		let source = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 3024, height: 1964))
		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(nil, Int(canvas.width), Int(canvas.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
		let output = try #require(buffer)
		// Warm up caches and the GPU pipeline.
		for i in 0..<5 {
			let frame = Compositor.shared.compose(source: source, outputTime: Double(i) / 60, scene: scene, canvas: canvas, quality: .preview)
			RenderContext.shared.render(frame, to: output, bounds: CGRect(origin: .zero, size: canvas), colorSpace: RenderContext.outputColorSpace)
		}
		let start = CFAbsoluteTimeGetCurrent()
		for i in 0..<frames {
			let frame = Compositor.shared.compose(source: source, outputTime: Double(i) / 60, scene: scene, canvas: canvas, quality: .preview)
			RenderContext.shared.render(frame, to: output, bounds: CGRect(origin: .zero, size: canvas), colorSpace: RenderContext.outputColorSpace)
		}
		return (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1000
	}

	private func project(_ configure: (inout Project) -> Void) -> Project {
		var project = Project(name: "Bench", media: MediaInfo(duration: 10, width: 3024, height: 1964))
		project.media.screen = ScreenGeometry(width: 3024, height: 1964, captureRect: NormRect(x: 0.15, y: 0.12, width: 0.7, height: 0.7))
		configure(&project)
		return project
	}

	@Test func compositorFrameCost() throws {
		let wallpaper = "/System/Library/Desktop Pictures/iMac Purple.heic"
		let canvas = CGSize(width: 1920, height: 1246)
		let cases: [(String, Project)] = [
			("colour background", project { $0.style.background = .color(.black) }),
			("wallpaper", project { $0.style.background = .image(path: wallpaper) }),
			("wallpaper + blur", project { $0.style.background = .image(path: wallpaper); $0.style.backgroundBlur = 0.5 }),
			("gradient + shadow", project { $0.style.background = .gradient(GradientFill(colors: [.violet, .black])); $0.style.shadow.opacity = 0.6 }),
			("wallpaper + mask + zoom", project {
				$0.style.background = .image(path: wallpaper)
				$0.masks = [MaskItem(range: TimeRange(start: 0, end: 10), rect: NormRect(x: 0.3, y: 0.3, width: 0.3, height: 0.1))]
				$0.zooms = [ZoomItem(range: TimeRange(start: 0, end: 10), target: .point(NormPoint(x: 0.5, y: 0.5)), scale: 2)]
			}),
		]
		for (name, project) in cases {
			let ms = try frameTime(project, canvas: canvas)
			print("BENCH \(name): \(String(format: "%.2f", ms)) ms/frame at \(Int(canvas.width))×\(Int(canvas.height))")
		}
	}
}

/// Cost of rebuilding the preview after an edit, on a real project (NEBULA_BENCH_PROJECT=<.nebula path>).
@Suite("Edit performance", .enabled(if: ProcessInfo.processInfo.environment["NEBULA_BENCH_PROJECT"] != nil))
struct EditPerformanceTests {
	@Test func rebuildCost() async throws {
		let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEBULA_BENCH_PROJECT"]))
		let bundle = ProjectBundle(url: url)
		let project = try bundle.readProject()
		let input = bundle.readInput()
		print("BENCH project \(project.media.duration)s, \(input.cursor.count) cursor samples, \(project.zooms.count) zooms")

		var start = CFAbsoluteTimeGetCurrent()
		var scene = RenderScene(project: project, input: input, bundleURL: url)
		for _ in 0..<9 { scene = RenderScene(project: project, input: input, bundleURL: url) }
		print("BENCH RenderScene: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 100)) ms")

		var styled = project
		styled.style.padding = 0.08
		start = CFAbsoluteTimeGetCurrent()
		for _ in 0..<10 { _ = RenderScene(project: styled, input: input, bundleURL: url, reusing: scene) }
		print("BENCH RenderScene after a style edit (reused paths): \(String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - start) * 100)) ms")

		start = CFAbsoluteTimeGetCurrent()
		for _ in 0..<5 {
			_ = try await CompositionBuilder.build(scene: scene, media: .init(video: bundle.videoURL(for: project)), renderSize: CGSize(width: 1500, height: 974), quality: .preview)
		}
		print("BENCH CompositionBuilder.build: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 200)) ms")

		start = CFAbsoluteTimeGetCurrent()
		for _ in 0..<1000 { _ = project.timeMap }
		print("BENCH project.timeMap: \(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - start))) ms")
		start = CFAbsoluteTimeGetCurrent()
		for _ in 0..<1000 { _ = project.clips }
		print("BENCH project.clips: \(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - start))) ms")
	}
}
