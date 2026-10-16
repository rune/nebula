import Foundation

/// Converts an OpenScreen project (`.openscreen`, format version 2) and its cursor telemetry
/// (`<video>.cursor.json`) into a Nebula project and input track.
///
/// Pure: the caller copies the video into the bundle and supplies its `MediaInfo`.
public enum OpenScreenImporter {
	public struct Result: Sendable {
		public var project: Project
		public var input: InputTrack
		/// Absolute path of the source video referenced by the OpenScreen project.
		public var sourceVideoPath: String
	}

	public enum ImportError: LocalizedError {
		case invalidProject(String)

		public var errorDescription: String? {
			switch self {
			case .invalidProject(let reason): "This isn't a readable OpenScreen project: \(reason)"
			}
		}
	}

	/// Reads only the referenced video path, so the caller can probe and copy it first.
	public static func videoPath(inProjectData data: Data) throws -> String {
		let file = try decode(data)
		guard let path = file.media?.screenVideoPath ?? file.videoPath, !path.isEmpty else {
			throw ImportError.invalidProject("no video path")
		}
		return path
	}

	public static func convert(projectData: Data, cursorData: Data?, media: MediaInfo, name: String) throws -> Result {
		let file = try decode(projectData)
		let sourceVideoPath = try videoPath(inProjectData: projectData)
		let editor = file.editor
		let seconds: (Double?) -> Double = { ($0 ?? 0) / 1000 }

		var project = Project(name: name, media: media)
		project.cuts = (editor.trimRegions ?? []).map {
			CutItem(range: TimeRange(start: seconds($0.startMs), end: seconds($0.endMs)), source: .imported)
		}
		project.speeds = (editor.speedRegions ?? []).map {
			SpeedItem(
				range: TimeRange(start: seconds($0.startMs), end: seconds($0.endMs)),
				rate: ($0.speed ?? 1).clamped(to: SpeedItem.rateRange),
				source: .imported
			)
		}
		project.zooms = (editor.zoomRegions ?? []).map { zoom in
			let depthScales: [Int: Double] = [1: 1.25, 2: 1.5, 3: 1.8, 4: 2.2, 5: 3.5, 6: 5]
			let scale = zoom.customScale ?? depthScales[zoom.depth ?? 3] ?? 1.8
			let focus = NormPoint(x: zoom.focus?.cx ?? 0.5, y: zoom.focus?.cy ?? 0.5).clamped()
			return ZoomItem(
				range: TimeRange(start: seconds(zoom.startMs), end: seconds(zoom.endMs)),
				target: zoom.focusMode == "auto" ? .follow : .point(focus),
				scale: scale.clamped(to: ZoomItem.scaleRange),
				source: .imported
			)
		}
		for region in editor.annotationRegions ?? [] {
			let range = TimeRange(start: seconds(region.startMs), end: seconds(region.endMs))
			let x = (region.position?.x ?? 50) / 100
			let y = (region.position?.y ?? 50) / 100
			let w = (region.size?.width ?? 30) / 100
			let h = (region.size?.height ?? 20) / 100
			let box = NormRect(x: x, y: y, width: w, height: h)
			switch region.type {
			case "blur":
				let isMosaic = region.blurData?.type == "mosaic"
				project.masks.append(MaskItem(
					range: range,
					rect: box.clamped(),
					kind: isMosaic ? .pixelate(amount: 0.6) : .blur(amount: 0.6),
					source: .imported
				))
			case "figure":
				let (from, to) = arrowEndpoints(in: box, direction: region.figureData?.arrowDirection ?? "right")
				let color = region.figureData?.color.flatMap(ColorValue.init(hex:)) ?? ArrowAnnotation(from: from, to: to).color
				project.annotations.append(AnnotationItem(
					range: range,
					kind: .arrow(ArrowAnnotation(from: from, to: to, color: color)),
					anchor: .canvas,
					source: .imported
				))
			case "image":
				continue
			default:
				let text = region.textContent ?? region.content ?? ""
				guard !text.isEmpty else { continue }
				let style = region.style
				project.annotations.append(AnnotationItem(
					range: range,
					kind: .text(TextAnnotation(
						text: text,
						position: box.center,
						fontSize: ((style?.fontSize ?? 32) / 1080).clamped(to: 0.015...0.15),
						color: style?.color.flatMap(ColorValue.init(hex:)) ?? .white,
						background: style?.backgroundColor.flatMap(ColorValue.init(hex:)),
						bold: style?.fontWeight != "normal"
					)),
					anchor: .canvas,
					source: .imported
				))
			}
		}

		project.style = importStyle(editor)
		project.camera.motionBlur = (editor.motionBlurAmount ?? 0.35).clamped(to: 0...1)

		let input = importCursor(cursorData)
		return Result(project: project, input: input, sourceVideoPath: sourceVideoPath)
	}

	// MARK: - Details

	private static func importStyle(_ editor: OSEditor) -> Style {
		var style = Style()
		style.placement = .fit
		if let wallpaper = editor.wallpaper {
			if let color = ColorValue(hex: wallpaper) {
				style.background = .color(color)
			} else if wallpaper.hasPrefix("file://"), let url = URL(string: wallpaper) {
				style.background = .image(path: url.path)
			} else if wallpaper.hasPrefix("/"), !wallpaper.hasPrefix("/wallpapers/") {
				style.background = .image(path: wallpaper)
			}
			// OpenScreen's bundled wallpapers aren't available; keep the neutral default.
		}
		// OpenScreen's padding 0–100 shrinks the recording to 100–60% of the canvas.
		style.padding = ((editor.padding ?? 50) / 100 * 0.2).clamped(to: 0...0.4)
		style.cornerRadius = ((editor.borderRadius ?? 12) / 1080).clamped(to: 0...0.1)
		style.shadow.opacity = (editor.shadowIntensity ?? 0.5).clamped(to: 0...1)
		style.backgroundBlur = editor.showBlur == true ? 0.5 : 0
		style.aspectRatio = switch editor.aspectRatio {
		case "16:9": .wide
		case "9:16": .vertical
		case "1:1": .square
		case "4:3": .classic
		case "4:5": .portrait
		default: .auto
		}
		if let crop = editor.cropRegion {
			style.crop = NormRect(x: crop.x ?? 0, y: crop.y ?? 0, width: crop.width ?? 1, height: crop.height ?? 1).clamped()
		}
		return style
	}

	private static func arrowEndpoints(in box: NormRect, direction: String) -> (NormPoint, NormPoint) {
		let c = box.center
		let dx = box.width / 2
		let dy = box.height / 2
		let vector: (Double, Double) = switch direction {
		case "up": (0, -1)
		case "down": (0, 1)
		case "left": (-1, 0)
		case "up-right": (1, -1)
		case "up-left": (-1, -1)
		case "down-right": (1, 1)
		case "down-left": (-1, 1)
		default: (1, 0)
		}
		return (
			NormPoint(x: c.x - vector.0 * dx, y: c.y - vector.1 * dy),
			NormPoint(x: c.x + vector.0 * dx, y: c.y + vector.1 * dy)
		)
	}

	static func importCursor(_ data: Data?) -> InputTrack {
		guard let data, let file = try? JSONDecoder().decode(OSCursorFile.self, from: data) else { return .empty }
		let samples = (file.samples ?? []).sorted { ($0.timeMs ?? 0) < ($1.timeMs ?? 0) }
		var shapes: [CursorShape] = [CursorShape(kind: .arrow)]
		var shapeIndex: [CursorShape.Kind: Int] = [.arrow: 0]
		var input = InputTrack()
		for sample in samples {
			let t = (sample.timeMs ?? 0) / 1000
			let x = sample.cx ?? 0.5
			let y = sample.cy ?? 0.5
			let kind: CursorShape.Kind = switch sample.cursorType {
			case "pointer": .pointer
			case "text": .iBeam
			case "crosshair": .crosshair
			case "open-hand": .openHand
			case "closed-hand": .closedHand
			case "resize-ew": .resizeLeftRight
			case "resize-ns": .resizeUpDown
			case "not-allowed": .notAllowed
			default: .arrow
			}
			let index = shapeIndex[kind] ?? {
				shapes.append(CursorShape(kind: kind))
				shapeIndex[kind] = shapes.count - 1
				return shapes.count - 1
			}()
			input.cursor.append(CursorSample(t: t, x: x, y: y, shape: sample.visible == false ? -1 : index))
			switch sample.interactionType {
			case "click", "double-click", "right-click", "middle-click":
				input.clicks.append(ClickEvent(t: t, x: x, y: y, button: sample.interactionType == "right-click" ? .right : .left))
			case "mouseup":
				if let last = input.clicks.indices.last, input.clicks[last].upT == nil {
					input.clicks[last].upT = t
				}
			default:
				break
			}
		}
		input.cursorShapes = shapes
		return input
	}

	private static func decode(_ data: Data) throws -> OSProjectFile {
		do {
			let file = try JSONDecoder().decode(OSProjectFile.self, from: data)
			guard file.version != nil else { throw ImportError.invalidProject("missing version") }
			return file
		} catch let error as ImportError {
			throw error
		} catch {
			throw ImportError.invalidProject(error.localizedDescription)
		}
	}
}

// MARK: - OpenScreen file shapes (lenient: every field optional)

private struct OSProjectFile: Decodable {
	var version: Int?
	var media: OSMedia?
	var videoPath: String?
	var editor: OSEditor
}

private struct OSMedia: Decodable {
	var screenVideoPath: String?
}

struct OSEditor: Decodable {
	var wallpaper: String?
	var shadowIntensity: Double?
	var showBlur: Bool?
	var motionBlurAmount: Double?
	var borderRadius: Double?
	var padding: Double?
	var cropRegion: OSRect?
	var zoomRegions: [OSZoom]?
	var trimRegions: [OSRegion]?
	var speedRegions: [OSSpeed]?
	var annotationRegions: [OSAnnotation]?
	var aspectRatio: String?
}

struct OSRect: Decodable {
	var x: Double?
	var y: Double?
	var width: Double?
	var height: Double?
}

struct OSRegion: Decodable {
	var startMs: Double?
	var endMs: Double?
}

struct OSSpeed: Decodable {
	var startMs: Double?
	var endMs: Double?
	var speed: Double?
}

struct OSZoom: Decodable {
	var startMs: Double?
	var endMs: Double?
	var depth: Int?
	var customScale: Double?
	var focus: OSFocus?
	var focusMode: String?
}

struct OSFocus: Decodable {
	var cx: Double?
	var cy: Double?
}

struct OSAnnotation: Decodable {
	var startMs: Double?
	var endMs: Double?
	var type: String?
	var content: String?
	var textContent: String?
	var position: OSPosition?
	var size: OSSize?
	var style: OSTextStyle?
	var figureData: OSFigure?
	var blurData: OSBlur?
}

struct OSPosition: Decodable {
	var x: Double?
	var y: Double?
}

struct OSSize: Decodable {
	var width: Double?
	var height: Double?
}

struct OSTextStyle: Decodable {
	var color: String?
	var backgroundColor: String?
	var fontSize: Double?
	var fontWeight: String?
}

struct OSFigure: Decodable {
	var arrowDirection: String?
	var color: String?
}

struct OSBlur: Decodable {
	var type: String?
}

private struct OSCursorFile: Decodable {
	var samples: [OSCursorSample]?
}

private struct OSCursorSample: Decodable {
	var timeMs: Double?
	var cx: Double?
	var cy: Double?
	var visible: Bool?
	var cursorType: String?
	var interactionType: String?
}
