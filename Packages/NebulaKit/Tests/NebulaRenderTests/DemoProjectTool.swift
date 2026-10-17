import Foundation
import NebulaCore
import Testing
@testable import NebulaRender

/// Builds the website's demo project from website/tools/demo output. Not a test: run with
/// NEBULA_DEMO_DIR=<render.cjs output> NEBULA_DEMO_LIBRARY=<library folder>.
@Suite("Demo project tool", .enabled(if: ProcessInfo.processInfo.environment["NEBULA_DEMO_DIR"] != nil))
struct DemoProjectTool {
	@Test func makeDemoProject() async throws {
		let env = ProcessInfo.processInfo.environment
		let source = URL(fileURLWithPath: try #require(env["NEBULA_DEMO_DIR"]))
		let library = ProjectLibrary(rootURL: URL(fileURLWithPath: try #require(env["NEBULA_DEMO_LIBRARY"])))
		let name = env["NEBULA_DEMO_NAME"] ?? "Orbit onboarding"
		try? FileManager.default.removeItem(at: library.rootURL.appending(path: "\(name).nebula"))
		let bundle = try library.newBundle(named: name)

		let video = bundle.url.appending(path: "recording.mp4")
		try FileManager.default.copyItem(at: source.appending(path: "recording.mp4"), to: video)
		try FileManager.default.createDirectory(at: bundle.mediaURL, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: source.appending(path: "desktop.jpg"), to: bundle.mediaURL.appending(path: ProjectBundle.desktopFileName))

		var media = try await MediaProbe.mediaInfo(video: video, videoFileName: "recording.mp4", microphone: nil, microphoneFileName: nil)
		media.screen = try JSONDecoder().decode(ScreenGeometry.self, from: Data(contentsOf: source.appending(path: "screen.json")))
		var project = Project(name: name, media: media)
		StylePreset.builtIn[0].apply(to: &project)
		let input = try JSONDecoder().decode(InputTrack.self, from: Data(contentsOf: source.appending(path: "input.json")))
		try bundle.write(input)
		try bundle.write(project)
		try await Thumbnailer.writeThumbnail(video: video, to: bundle.thumbnailURL, at: 12.6)
		print("DEMO wrote \(bundle.url.path)")
	}
}
