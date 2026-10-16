import Foundation
import NebulaCore

// Compact, model-friendly JSON shapes returned by the MCP tools.

struct StatusSummary: Encodable {
	var openProjects: [String]
	var frontmost: String?
	var recording: String
	var recordingSeconds: Double
}

struct ProjectListing: Encodable {
	var name: String
	var path: String
	/// Length after edits, seconds.
	var duration: Double
	var modified: Date
}

struct EditResult: Encodable {
	var summary: String
	var project: ProjectSummary
}

struct ActivitySummary: Encodable {
	struct Click: Encodable { var time, x, y: Double; var button: String }
	struct Span: Encodable { var start, end: Double }
	struct Shortcut: Encodable { var time: Double; var keys: String }

	var clicks: [Click]
	var typing: [Span]
	var shortcuts: [Shortcut]
	var scrolls: Int
	var speech: [Span]
}

struct SourcesSummary: Encodable {
	struct Display: Encodable { var id: Int; var name: String; var width, height: Int }
	struct Window: Encodable { var id: Int; var app: String; var title: String }

	var displays: [Display]
	var windows: [Window]
	var microphones: [String]
}

@MainActor
struct ProjectSummary: Encodable {
	struct Item: Encodable {
		var id: String
		var kind: String
		var start: Double
		var end: Double
		var detail: String
		var source: String?
	}

	var name: String
	var path: String
	var duration: Double
	var outputDuration: Double
	var resolution: String
	var playhead: Double
	var items: [Item]
	var style: [String: String]
	var captions: Int
	var canUndo: Bool

	init(_ store: ProjectStore) {
		let p = store.project
		name = p.name
		path = store.bundle.url.path
		duration = rounded(p.media.duration)
		outputDuration = rounded(store.timeMap.outputDuration)
		resolution = "\(p.media.width)x\(p.media.height)"
		playhead = rounded(store.playheadSourceTime)
		canUndo = store.canUndo
		captions = p.captions?.segments.count ?? 0

		var items: [Item] = []
		for zoom in p.zooms {
			let target: String = switch zoom.target {
			case .follow: "follows cursor"
			case .point(let point): "at \(rounded(point.x, 3)),\(rounded(point.y, 3))"
			case .rect(let rect): "frames \(rounded(rect.x, 3)),\(rounded(rect.y, 3)) \(rounded(rect.width, 3))x\(rounded(rect.height, 3))"
			}
			items.append(Item(id: zoom.id.rawValue, kind: "zoom", start: rounded(zoom.range.start), end: rounded(zoom.range.end), detail: "\(zoom.scale)× \(target)\(zoom.transition == .instant ? ", instant" : "")", source: zoom.source.rawValue))
		}
		for cut in p.cuts {
			items.append(Item(id: cut.id.rawValue, kind: "cut", start: rounded(cut.range.start), end: rounded(cut.range.end), detail: "removed", source: cut.source.rawValue))
		}
		for speed in p.speeds {
			items.append(Item(id: speed.id.rawValue, kind: "speed", start: rounded(speed.range.start), end: rounded(speed.range.end), detail: "\(speed.rate)×", source: speed.source.rawValue))
		}
		for mask in p.masks {
			let kind: String = switch mask.kind {
			case .blur(let amount): "blur \(amount)"
			case .pixelate(let amount): "pixelate \(amount)"
			case .highlight(let amount): "highlight \(amount)"
			}
			items.append(Item(id: mask.id.rawValue, kind: "mask", start: rounded(mask.range.start), end: rounded(mask.range.end), detail: "\(kind) at \(rounded(mask.rect.x)),\(rounded(mask.rect.y)) \(rounded(mask.rect.width))x\(rounded(mask.rect.height))", source: mask.source.rawValue))
		}
		for note in p.annotations {
			let detail: String = switch note.kind {
			case .text(let label): "text \"\(label.text)\" at \(rounded(label.position.x)),\(rounded(label.position.y))"
			case .arrow(let arrow): "arrow \(rounded(arrow.from.x)),\(rounded(arrow.from.y)) → \(rounded(arrow.to.x)),\(rounded(arrow.to.y))"
			}
			items.append(Item(id: note.id.rawValue, kind: "annotation", start: rounded(note.range.start), end: rounded(note.range.end), detail: detail, source: note.source.rawValue))
		}
		for volume in p.audio.volumes {
			items.append(Item(id: volume.id.rawValue, kind: "volume", start: rounded(volume.range.start), end: rounded(volume.range.end), detail: "\(volume.channel.rawValue) × \(volume.gain)", source: nil))
		}
		self.items = items.sorted { $0.start < $1.start }

		let background: String = switch p.style.background {
		case .color(let color): color.hex
		case .gradient(let fill): "gradient \(fill.colors.map(\.hex).joined(separator: ","))"
		case .image(let path): path.hasSuffix(ProjectBundle.desktopFileName) ? "desktop" : "image \(path)"
		}
		style = [
			"background": background,
			"placement": p.style.placement.rawValue,
			"padding": "\(rounded(p.style.padding))",
			"corner_radius": "\(rounded(p.style.cornerRadius))",
			"shadow": "\(rounded(p.style.shadow.opacity))",
			"aspect_ratio": p.style.aspectRatio.rawValue,
			"camera": p.camera.preset.rawValue,
			"motion_blur": "\(p.camera.motionBlur)",
			"cursor_size": "\(p.cursor.size)",
			"click_effect": p.cursor.clickEffect.rawValue,
			"shortcut_keys": "\(p.shortcutOverlay.enabled)",
			"noise_reduction": "\(p.audio.noiseReduction)",
			"music": p.audio.music?.file ?? "none",
		]
	}
}
