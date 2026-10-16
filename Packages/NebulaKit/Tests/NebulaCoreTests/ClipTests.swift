import Foundation
import Testing
@testable import NebulaCore

@Suite("Clips")
struct ClipTests {
	private func project(_ duration: Double = 10) -> Project {
		Project(name: "Clips", media: MediaInfo(duration: duration, width: 1920, height: 1080))
	}

	@Test func oneClipWithoutEdits() {
		let clips = project().clips
		#expect(clips.count == 1)
		#expect(clips[0].source == TimeRange(start: 0, end: 10))
		#expect(clips[0].output == TimeRange(start: 0, end: 10))
	}

	@Test func splitMakesTwoClipsWithoutChangingLength() {
		var p = project()
		let didSplit = p.split(atSource: 4)
		#expect(didSplit)
		#expect(p.clips.map(\.source) == [TimeRange(start: 0, end: 4), TimeRange(start: 4, end: 10)])
		#expect(p.timeMap.outputDuration == 10)
		let again = p.split(atSource: 4)
		#expect(!again, "splitting on an existing edge does nothing")
	}

	@Test func deleteRipplesLaterClipsForward() {
		var p = project()
		p.split(atSource: 4)
		p.split(atSource: 6)
		p.deleteClip(p.clips[1])
		let clips = p.clips
		#expect(clips.count == 2)
		#expect(clips[1].source.start == 6)
		#expect(clips[1].outputStart == 4)
		#expect(p.timeMap.outputDuration == 8)
		#expect(p.splits == nil, "split points at the removed clip's edges are dropped")
	}

	@Test func speedAppliesToOneClipAndKeepsItsEdges() {
		var p = project()
		p.split(atSource: 2)
		p.split(atSource: 6)
		p.setRate(2, for: p.clips[1])
		#expect(p.clips.map(\.rate) == [1, 2, 1])
		#expect(p.timeMap.outputDuration == 8)
		p.setRate(1, for: p.clips[1])
		#expect(p.clips.count == 3)
		#expect(p.speeds.isEmpty)
		#expect(p.timeMap.outputDuration == 10)
	}

	@Test func trimInRemovesMaterialAndTrimOutRestoresIt() {
		var p = project()
		p.split(atSource: 5)
		p.trim(p.clips[0], edge: .end, toSource: 3)
		#expect(p.timeMap.outputDuration == 8)
		#expect(p.clips[1].outputStart == 3)
		// Grow back past the original edge: stops where the next clip starts.
		p.trim(p.clips[0], edge: .end, toSource: 9)
		#expect(p.timeMap.outputDuration == 10)
		#expect(p.clips[0].source == TimeRange(start: 0, end: 5))
	}

	@Test func trimStartOfFirstClip() {
		var p = project()
		p.trim(p.clips[0], edge: .start, toSource: 1.5)
		#expect(p.clips[0].source.start == 1.5)
		#expect(p.clips[0].outputStart == 0)
		p.trim(p.clips[0], edge: .start, toSource: 0)
		#expect(p.timeMap.outputDuration == 10)
	}

	@Test func trimmingOutKeepsTheClipSpeed() {
		var p = project()
		p.cuts = [CutItem(range: TimeRange(start: 6, end: 10))]
		p.setRate(2, for: p.clips[0])
		p.trim(p.clips[0], edge: .end, toSource: 8)
		#expect(p.clips.count == 1)
		#expect(p.clips[0].rate == 2)
		#expect(p.clips[0].source == TimeRange(start: 0, end: 8))
	}

	@Test func outputRangeSkipsCutParts() {
		var p = project()
		p.cuts = [CutItem(range: TimeRange(start: 2, end: 4))]
		let map = p.timeMap
		#expect(map.outputRange(forSource: TimeRange(start: 1, end: 5)) == TimeRange(start: 1, end: 3))
		#expect(map.outputRange(forSource: TimeRange(start: 2.5, end: 3.5)) == nil)
	}

	@Test func oldProjectsWithoutSplitsDecode() throws {
		let data = try ProjectBundle.encoder.encode(project())
		var json = try #require(String(data: data, encoding: .utf8))
		json = json.replacingOccurrences(of: "\"splits\"", with: "\"unused\"")
		let decoded = try ProjectBundle.decoder.decode(Project.self, from: Data(json.utf8))
		#expect(decoded.splits == nil)
	}
}
