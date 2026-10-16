import AVFoundation
import CoreImage
import Foundation
import NebulaCore
import NebulaPolish
import Testing
@testable import NebulaRender

/// Writes a short H.264 test video: a dark frame with a bright square moving left to right.
func makeTestVideo(seconds: Double = 2, size: CGSize = CGSize(width: 640, height: 400), fps: Int = 30) async throws -> URL {
	let url = FileManager.default.temporaryDirectory.appending(path: "nebula-test-\(UUID().uuidString).mov")
	let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
	let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
		AVVideoCodecKey: AVVideoCodecType.h264,
		AVVideoWidthKey: Int(size.width),
		AVVideoHeightKey: Int(size.height),
	])
	let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		kCVPixelBufferWidthKey as String: Int(size.width),
		kCVPixelBufferHeightKey as String: Int(size.height),
	])
	writer.add(input)
	writer.startWriting()
	writer.startSession(atSourceTime: .zero)
	let frames = Int(seconds * Double(fps))
	for frame in 0..<frames {
		while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
		var buffer: CVPixelBuffer?
		CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
		let pixelBuffer = try #require(buffer)
		let x = CGFloat(frame) / CGFloat(frames) * (size.width - 80)
		let image = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: CGRect(x: x, y: 160, width: 80, height: 80))
			.composited(over: CIImage(color: CIColor(red: 0.12, green: 0.14, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: size)))
		RenderContext.shared.render(image, to: pixelBuffer)
		adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
	}
	input.markAsFinished()
	await writer.finishWriting()
	return url
}

func testProject(duration: Double = 2) -> Project {
	var project = Project(name: "Render test", media: MediaInfo(duration: duration, width: 640, height: 400, frameRate: 30))
	project.style.aspectRatio = .wide
	return project
}

@Suite("Renderer")
struct RenderTests {
	@Test func layoutCentresRecordingWithPadding() {
		var project = testProject()
		project.style.padding = 0.1
		let layout = SceneLayout(project: project, canvas: CGSize(width: 1920, height: 1080))
		#expect(abs(layout.content.midX - 960) <= 1)
		#expect(abs(layout.content.midY - 540) <= 1)
		#expect(layout.content.height <= 1080 - 2 * 108 + 1)
		let zoomed = layout.visibleRect(for: CameraState(center: NormPoint(x: 0.9, y: 0.9), scale: 2))
		#expect(zoomed.maxX <= 1 + 1e-9 && zoomed.maxY <= 1 + 1e-9 && abs(zoomed.width - 0.5) < 1e-9)
	}

	@Test func composedFrameHasRecordingOverBackground() throws {
		var project = testProject()
		project.style.background = .color(ColorValue(hex: "#FF0000")!)
		project.style.padding = 0.1
		project.style.shadow.opacity = 0
		let scene = RenderScene(project: project, input: .empty, bundleURL: nil)
		let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
		let canvas = CGSize(width: 640, height: 360)
		let frame = Compositor.shared.compose(source: source, outputTime: 0.5, scene: scene, canvas: canvas, quality: .export)
		let image = try #require(RenderContext.shared.createCGImage(frame, from: CGRect(origin: .zero, size: canvas)))
		#expect(image.width == 640 && image.height == 360)
		let corner = pixel(image, x: 3, y: 3)
		let middle = pixel(image, x: 320, y: 180)
		#expect(corner.r > 200 && corner.b < 60)
		#expect(middle.b > 200 && middle.r < 60)
	}

	@Test func exportsEditedMP4WithExpectedLength() async throws {
		let video = try await makeTestVideo()
		defer { try? FileManager.default.removeItem(at: video) }
		var project = testProject()
		project.cuts = [CutItem(range: TimeRange(start: 0.5, end: 1.0))]
		project.zooms = [ZoomItem(range: TimeRange(start: 1.0, end: 2.0), target: .point(NormPoint(x: 0.7, y: 0.5)), scale: 2)]
		let scene = RenderScene(project: project, input: .empty, bundleURL: nil)
		let playable = try await CompositionBuilder.build(
			scene: scene, media: .init(video: video), renderSize: CGSize(width: 1280, height: 720), frameRate: 30, quality: .export
		)
		let output = FileManager.default.temporaryDirectory.appending(path: "nebula-export-\(UUID().uuidString).mp4")
		defer { try? FileManager.default.removeItem(at: output) }
		var settings = ExportSettings()
		settings.fps = 30
		try await VideoExporter.export(playable, settings: settings, to: output) { _ in }
		let asset = AVURLAsset(url: output)
		let duration = try await asset.load(.duration).seconds
		#expect(abs(duration - 1.5) < 0.1)
		let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
		let size = try await track.load(.naturalSize)
		#expect(size == CGSize(width: 1280, height: 720))

		let frame = try await FrameGrabber.renderedFrame(playable, at: 1.2)
		#expect(frame.width == 1280)
	}

	@Test func exportsGIF() async throws {
		let video = try await makeTestVideo(seconds: 1)
		defer { try? FileManager.default.removeItem(at: video) }
		let scene = RenderScene(project: testProject(duration: 1), input: .empty, bundleURL: nil)
		let playable = try await CompositionBuilder.build(scene: scene, media: .init(video: video), renderSize: CGSize(width: 320, height: 180), frameRate: 10, quality: .export)
		let output = FileManager.default.temporaryDirectory.appending(path: "nebula-\(UUID().uuidString).gif")
		defer { try? FileManager.default.removeItem(at: output) }
		try await GIFExporter.export(playable, fps: 10, loop: true, to: output) { _ in }
		let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
		#expect(CGImageSourceGetCount(source) >= 9)
	}

	/// Renders frames of a real recording for visual review. Set NEBULA_SNAPSHOT_VIDEO (a video
	/// path, optionally with `<video>.cursor.json` from OpenScreen) and NEBULA_SNAPSHOT_OUT (a folder).
	@Test(.enabled(if: ProcessInfo.processInfo.environment["NEBULA_SNAPSHOT_VIDEO"] != nil))
	func snapshotRealRecording() async throws {
		let env = ProcessInfo.processInfo.environment
		let video = URL(fileURLWithPath: try #require(env["NEBULA_SNAPSHOT_VIDEO"]))
		let out = URL(fileURLWithPath: env["NEBULA_SNAPSHOT_OUT"] ?? NSTemporaryDirectory())
		try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
		let media = try await MediaProbe.mediaInfo(video: video, videoFileName: video.lastPathComponent, microphone: nil, microphoneFileName: nil)
		var project = Project(name: "Snapshot", media: media)
		let cursorData = try? Data(contentsOf: URL(fileURLWithPath: video.path + ".cursor.json"))
		let input = try OpenScreenImporter.convert(
			projectData: Data(#"{"version":2,"media":{"screenVideoPath":"x"},"editor":{}}"#.utf8),
			cursorData: cursorData, media: media, name: "Snapshot"
		).input
		let activity = try await FrameActivityAnalyzer.analyze(video: video)
		let plan = PolishPlanner.plan(project: project, input: input, signals: PolishSignals(frameActivity: activity), options: PolishOptions())
		PolishPlanner.apply(plan, to: &project, options: PolishOptions())
		let scene = RenderScene(project: project, input: input, bundleURL: nil)
		let canvas = SceneLayout.canvasSize(for: project, shortSide: 1080)
		let playable = try await CompositionBuilder.build(scene: scene, media: .init(video: video), renderSize: canvas, quality: .export)
		let summary = "plan: \(plan.summary); output \(scene.outputDuration)s of \(media.duration)s; zooms \(project.zooms.map { "\($0.range.start)-\($0.range.end) x\($0.scale)" })"
		try summary.write(to: out.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
		let zoomTimes = project.zooms.prefix(3).compactMap { scene.timeMap.outputTime(forSource: ($0.range.start + $0.range.end) / 2) }
		for (index, time) in ([0.5] + zoomTimes).enumerated() {
			let image = try await FrameGrabber.renderedFrame(playable, at: time)
			try FrameGrabber.pngData(image)?.write(to: out.appending(path: "frame-\(index).png"))
		}
	}
}

func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
	var data = [UInt8](repeating: 0, count: 4)
	let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
	return (Int(data[0]), Int(data[1]), Int(data[2]))
}
