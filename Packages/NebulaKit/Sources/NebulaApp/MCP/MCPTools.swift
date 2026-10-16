import AppKit
import Foundation
import NebulaCaptions
import NebulaCapture
import NebulaCore
import NebulaMCP
import NebulaPolish
import NebulaRender

/// Nebula's MCP tools. Every tool runs on the main actor through the same `ProjectStore`
/// edits as the UI, so changes appear live, toast as "Claude", and undo with ⌘Z.
enum MCPTools {
	static let instructions = """
		Nebula is a macOS screen recorder and editor for polished product demos. Tools act on the project \
		open in the frontmost editor unless you pass "project" (a project name or .nebula path).
		- Times are seconds of the original recording. Positions are fractions 0–1 of the recorded frame \
		(x left→right, y top→bottom), the same space get_frame shows.
		- Look before editing: get_project (timeline + ids), get_activity (clicks, typing, idle), get_frame \
		(raw recording) and preview_frame (the edited result).
		- polish does smart zooms, dead-air cuts, typing speed-ups and cursor smoothing in one step; refine afterwards.
		- Every edit is one undo step for the user and is saved automatically.
		"""

	@MainActor
	static func all(controller: MCPController) -> [MCPTool] {
		let tools: [MCPTool] = [
			status, listProjects, openProject, importFile, getProject, getActivity, getFrame, previewFrame, seek,
			polish, addZoom, addCut, addSpeed, addMask, addText, addArrow, setVolume, updateItem, removeItems,
			setStyle, listPresets, applyPreset, savePreset, captions, audio, export, listSources,
			startRecording, pauseRecording, stopRecording, undo, redo,
		]
		return tools.map { tool in
			var tool = tool
			let handler = tool.handler
			let name = tool.name
			tool.handler = { [weak controller] args in
				await MainActor.run { controller?.record(name) }
				return try await handler(args)
			}
			return tool
		}
	}

	// MARK: - Helpers

	struct ToolError: LocalizedError {
		let message: String
		init(_ message: String) { self.message = message }
		var errorDescription: String? { message }
	}

	@MainActor static var app: AppModel { AppModel.shared }

	@MainActor
	static func store(_ args: JSONValue) throws -> ProjectStore {
		if let name = args["project"]?.stringValue, !name.isEmpty {
			let url: URL
			if name.hasSuffix(".nebula") || name.hasPrefix("/") {
				url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
			} else if let entry = app.entries.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
				url = entry.bundle.url
			} else {
				throw ToolError("No project named \"\(name)\". Use list_projects to see them.")
			}
			return try app.store(for: url)
		}
		guard let store = app.activeStore ?? app.stores.values.first else {
			throw ToolError("No project is open in Nebula. Pass \"project\" or call open_project first.")
		}
		return store
	}

	@MainActor
	static func range(_ args: JSONValue, in store: ProjectStore) throws -> TimeRange {
		guard let start = args["start"]?.doubleValue, let end = args["end"]?.doubleValue, end > start else {
			throw ToolError("Pass start and end (seconds), with end after start.")
		}
		return TimeRange(start: max(0, start), end: min(end, store.project.media.duration))
	}

	static func point(_ args: JSONValue, _ x: String = "x", _ y: String = "y", default value: NormPoint = .center) -> NormPoint {
		NormPoint(x: args[x]?.doubleValue ?? value.x, y: args[y]?.doubleValue ?? value.y).clamped()
	}

	static let projectArg = JSONSchema.string("Project name or .nebula path. Leave out for the project open in the frontmost editor.")
	static let timeArgs: [String: JSONValue] = [
		"start": JSONSchema.number("Seconds of the recording", minimum: 0),
		"end": JSONSchema.number("Seconds of the recording", minimum: 0),
	]

	static func merge(_ a: [String: JSONValue], _ b: [String: JSONValue]) -> [String: JSONValue] {
		a.merging(b) { $1 }
	}

	// MARK: - Reading

	static let status = MCPTool(name: "status", title: "Status", description: "What Nebula is doing: open projects, the frontmost editor, recording state.", readOnly: true) { _ in
		try await MainActor.run {
			.json(StatusSummary(
				openProjects: app.stores.values.map(\.project.name),
				frontmost: app.activeStore?.project.name,
				recording: "\(app.recorder.phase)",
				recordingSeconds: app.recorder.elapsed
			))
		}
	}

	static let listProjects = MCPTool(name: "list_projects", title: "List projects", description: "Projects in the Nebula library, newest first.", readOnly: true) { _ in
		await MainActor.run {
			.json(app.entries.map { ProjectListing(name: $0.name, path: $0.bundle.url.path, duration: rounded($0.duration), modified: $0.modifiedAt) })
		}
	}

	static let openProject = MCPTool(
		name: "open_project", title: "Open project", description: "Opens a project in an editor window so edits show live.",
		inputSchema: JSONSchema.object(["project": projectArg], required: ["project"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			app.open(store.bundle.url)
			return .json(ProjectSummary(store))
		}
	}

	static let importFile = MCPTool(
		name: "import", title: "Import", description: "Imports a video file (.mp4/.mov) or an OpenScreen project (.openscreen) as a new Nebula project and opens it.",
		inputSchema: JSONSchema.object(["path": JSONSchema.string("File path")], required: ["path"])
	) { args in
		guard let path = args["path"]?.stringValue else { throw ToolError("Pass path.") }
		let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
		guard let bundle = await app.importFile(url) else { throw ToolError("Import failed: \(await app.lastError ?? "unknown error")") }
		return try await MainActor.run { .json(ProjectSummary(try app.store(for: bundle))) }
	}

	static let getProject = MCPTool(
		name: "get_project", title: "Get project",
		description: "The timeline with item ids (zooms, cuts, speed changes, masks, annotations, volume), style, camera, cursor, captions, and lengths before/after edits.",
		inputSchema: JSONSchema.object(["project": projectArg]), readOnly: true
	) { args in
		try await MainActor.run { .json(ProjectSummary(try store(args))) }
	}

	static let getActivity = MCPTool(
		name: "get_activity", title: "Get activity",
		description: "What happened while recording: clicks (time, position), typing runs, keyboard shortcuts, scrolls, idle stretches, and when someone spoke.",
		inputSchema: JSONSchema.object(merge(["project": projectArg], [
			"start": JSONSchema.number("Only from this time", minimum: 0),
			"end": JSONSchema.number("Only up to this time", minimum: 0),
		])), readOnly: true
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let window = TimeRange(start: args["start"]?.doubleValue ?? 0, end: args["end"]?.doubleValue ?? store.project.media.duration)
			let input = store.input
			let typing = PolishPlanner.typingBursts(input: input, maxGap: 1.1).filter { $0.overlaps(window) }
			return .json(ActivitySummary(
				clicks: input.clicks.filter { window.contains($0.t) }.prefix(400).map { .init(time: rounded($0.t), x: rounded($0.x, 4), y: rounded($0.y, 4), button: $0.button.rawValue) },
				typing: typing.map { .init(start: rounded($0.start), end: rounded($0.end)) },
				shortcuts: input.keys.filter { $0.kind == .shortcut && window.contains($0.t) }.prefix(200).map { .init(time: rounded($0.t), keys: $0.keys.joined()) },
				scrolls: input.scrolls.filter { window.contains($0.t) }.count,
				speech: store.speech.filter { $0.overlaps(window) }.map { .init(start: rounded($0.start), end: rounded($0.end)) }
			))
		}
	}

	static let getFrame = MCPTool(
		name: "get_frame", title: "Get frame", description: "A still of the raw recording at a time (before any styling), to see what's on screen.",
		inputSchema: JSONSchema.object(["project": projectArg, "time": JSONSchema.number("Seconds of the recording", minimum: 0)], required: ["time"]),
		readOnly: true
	) { args in
		let (video, time) = try await MainActor.run { () -> (URL, Double) in
			let store = try store(args)
			return (store.videoURL, args["time"]?.doubleValue ?? 0)
		}
		let image = try await FrameGrabber.sourceFrame(video: video, at: time, maxWidth: 1440)
		guard let jpeg = FrameGrabber.jpegData(image) else { throw ToolError("Couldn't encode the frame.") }
		return MCPToolResult(content: [.text("Recording at \(time)s"), .image(data: jpeg, mimeType: "image/jpeg")])
	}

	static let previewFrame = MCPTool(
		name: "preview_frame", title: "Preview frame",
		description: "The edited result (background, zoom, cursor, overlays, captions) at a time on the recording's timeline. Leave out time for the playhead.",
		inputSchema: JSONSchema.object(["project": projectArg, "time": JSONSchema.number("Seconds of the recording", minimum: 0)]),
		readOnly: true
	) { args in
		let (scene, media, outputTime) = try await MainActor.run { () -> (RenderScene, CompositionBuilder.Media, Double) in
			let store = try store(args)
			let output = args["time"]?.doubleValue.flatMap { store.timeMap.outputTime(forSource: store.timeMap.nearestKeptSourceTime(to: $0)) } ?? store.preview.currentTime
			return (store.makeScene(), store.media, output)
		}
		let canvas = SceneLayout.canvasSize(for: scene.project, shortSide: 900)
		let playable = try await CompositionBuilder.build(scene: scene, media: media, renderSize: canvas, quality: .export)
		let image = try await FrameGrabber.renderedFrame(playable, at: outputTime)
		guard let jpeg = FrameGrabber.jpegData(image) else { throw ToolError("Couldn't encode the frame.") }
		return MCPToolResult(content: [.text("Edited preview at output \(rounded(outputTime))s"), .image(data: jpeg, mimeType: "image/jpeg")])
	}

	static let seek = MCPTool(
		name: "seek", title: "Move playhead", description: "Moves the editor playhead to a time of the recording (to show the user something).",
		inputSchema: JSONSchema.object(["project": projectArg, "time": JSONSchema.number("Seconds of the recording", minimum: 0)], required: ["time"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let source = store.timeMap.nearestKeptSourceTime(to: args["time"]?.doubleValue ?? 0)
			store.preview.seek(to: store.timeMap.outputTime(forSource: source) ?? 0)
			return .text("Playhead at \(rounded(source))s")
		}
	}

	// MARK: - Editing

	static let polish = MCPTool(
		name: "polish", title: "Polish",
		description: "Analyses clicks, typing, the picture and speech, then adds smart zooms, cuts dead air, trims the ends, speeds up typing and smooths the cursor. Replaces earlier Polish items only.",
		inputSchema: JSONSchema.object([
			"project": projectArg,
			"auto_zoom": JSONSchema.boolean(), "cut_dead_air": JSONSchema.boolean(), "speed_up_typing": JSONSchema.boolean(),
			"trim_ends": JSONSchema.boolean(), "polish_cursor": JSONSchema.boolean(),
			"max_zoom": JSONSchema.number("1.2–4", minimum: 1.2, maximum: 4),
			"dead_air_minimum": JSONSchema.number("Shortest idle stretch to cut, seconds", minimum: 0.5),
			"typing_speed": JSONSchema.number("Speed for typing runs", minimum: 1.25, maximum: 8),
		])
	) { args in
		let store = try await MainActor.run { try MCPTools.store(args) }
		var options = await MainActor.run { app.settings.polishOptions }
		options.autoZoom = args["auto_zoom"]?.boolValue ?? options.autoZoom
		options.cutDeadAir = args["cut_dead_air"]?.boolValue ?? options.cutDeadAir
		options.speedUpTyping = args["speed_up_typing"]?.boolValue ?? options.speedUpTyping
		options.trimEnds = args["trim_ends"]?.boolValue ?? options.trimEnds
		options.polishCursor = args["polish_cursor"]?.boolValue ?? options.polishCursor
		options.maxZoom = args["max_zoom"]?.doubleValue ?? options.maxZoom
		options.deadAirMinimum = args["dead_air_minimum"]?.doubleValue ?? options.deadAirMinimum
		options.typingSpeed = args["typing_speed"]?.doubleValue ?? options.typingSpeed
		let plan = try await store.polish(options: options, source: .assistant)
		return try await MainActor.run { .json(EditResult(summary: "Polish: \(plan.summary)", project: ProjectSummary(store))) }
	}

	static let addZoom = MCPTool(
		name: "add_zoom", title: "Add zoom",
		description: "Zooms in between two times. target: 'follow' (pans with the cursor), 'point' (fixed x/y), or 'rect' (frames x/y/width/height). scale 1–5.",
		inputSchema: JSONSchema.object(merge(timeArgs, [
			"project": projectArg,
			"target": JSONSchema.string(nil, enum: ["follow", "point", "rect"]),
			"x": JSONSchema.number(nil, minimum: 0, maximum: 1), "y": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"width": JSONSchema.number(nil, minimum: 0.02, maximum: 1), "height": JSONSchema.number(nil, minimum: 0.02, maximum: 1),
			"scale": JSONSchema.number(nil, minimum: 1, maximum: 5),
			"instant": JSONSchema.boolean("Cut in/out instead of animating"),
		]), required: ["start", "end"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let target: ZoomItem.Target = switch args["target"]?.stringValue {
			case "point": .point(point(args))
			case "rect": .rect(NormRect(x: args["x"]?.doubleValue ?? 0.3, y: args["y"]?.doubleValue ?? 0.3, width: args["width"]?.doubleValue ?? 0.4, height: args["height"]?.doubleValue ?? 0.2).clamped())
			default: .follow
			}
			let zoom = ZoomItem(
				range: try range(args, in: store), target: target,
				scale: (args["scale"]?.doubleValue ?? 1.8).clamped(to: ZoomItem.scaleRange),
				transition: args["instant"]?.boolValue == true ? .instant : .spring
			)
			store.apply("Add zoom", source: .assistant) { $0.zooms.append(zoom) }
			return .json(EditResult(summary: "Added \(zoom.id)", project: ProjectSummary(store)))
		}
	}

	static let addCut = MCPTool(
		name: "add_cut", title: "Cut a section", description: "Removes a section from the video.",
		inputSchema: JSONSchema.object(merge(timeArgs, ["project": projectArg]), required: ["start", "end"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let cut = CutItem(range: try range(args, in: store))
			store.apply("Cut a section", source: .assistant) { $0.cuts.append(cut) }
			return .json(EditResult(summary: "Added \(cut.id)", project: ProjectSummary(store)))
		}
	}

	static let addSpeed = MCPTool(
		name: "add_speed", title: "Change speed", description: "Plays a section faster or slower (rate 0.25–16).",
		inputSchema: JSONSchema.object(merge(timeArgs, ["project": projectArg, "rate": JSONSchema.number(nil, minimum: 0.25, maximum: 16)]), required: ["start", "end", "rate"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let item = SpeedItem(range: try range(args, in: store), rate: (args["rate"]?.doubleValue ?? 2).clamped(to: SpeedItem.rateRange))
			store.apply("Set \(item.rate)× speed", source: .assistant) { $0.speeds.append(item) }
			return .json(EditResult(summary: "Added \(item.id)", project: ProjectSummary(store)))
		}
	}

	static let addMask = MCPTool(
		name: "add_mask", title: "Add mask",
		description: "Blurs or pixelates a rectangle (to hide private info), or highlights it by dimming everything else. Masks move with zooms.",
		inputSchema: JSONSchema.object(merge(timeArgs, [
			"project": projectArg, "kind": JSONSchema.string(nil, enum: ["blur", "pixelate", "highlight"]),
			"x": JSONSchema.number(nil, minimum: 0, maximum: 1), "y": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"width": JSONSchema.number(nil, minimum: 0.01, maximum: 1), "height": JSONSchema.number(nil, minimum: 0.01, maximum: 1),
			"amount": JSONSchema.number("0–1", minimum: 0, maximum: 1),
		]), required: ["start", "end", "x", "y", "width", "height"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let amount = args["amount"]?.doubleValue ?? 0.6
			let kind: MaskItem.Kind = switch args["kind"]?.stringValue {
			case "pixelate": .pixelate(amount: amount)
			case "highlight": .highlight(amount: amount)
			default: .blur(amount: amount)
			}
			let rect = NormRect(x: args["x"]?.doubleValue ?? 0, y: args["y"]?.doubleValue ?? 0, width: args["width"]?.doubleValue ?? 0.2, height: args["height"]?.doubleValue ?? 0.1).clamped()
			let mask = MaskItem(range: try range(args, in: store), rect: rect, kind: kind)
			store.apply("Add mask", source: .assistant) { $0.masks.append(mask) }
			return .json(EditResult(summary: "Added \(mask.id)", project: ProjectSummary(store)))
		}
	}

	static let addText = MCPTool(
		name: "add_text", title: "Add text",
		description: "Adds a text label centred at x/y. anchor 'screen' moves with zooms, 'canvas' stays put. size is relative to video height (0.04 ≈ 43 px at 1080p).",
		inputSchema: JSONSchema.object(merge(timeArgs, [
			"project": projectArg, "text": JSONSchema.string(),
			"x": JSONSchema.number(nil, minimum: 0, maximum: 1), "y": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"size": JSONSchema.number(nil, minimum: 0.015, maximum: 0.2), "color": JSONSchema.string("#RRGGBB"),
			"background": JSONSchema.string("#RRGGBBAA or 'none'"),
			"anchor": JSONSchema.string(nil, enum: ["screen", "canvas"]),
			"animation": JSONSchema.string(nil, enum: TextAnimation.allCases.map(\.rawValue)),
		]), required: ["start", "end", "text"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			var label = TextAnnotation(text: args["text"]?.stringValue ?? "", position: point(args, default: NormPoint(x: 0.5, y: 0.15)))
			if let size = args["size"]?.doubleValue { label.fontSize = size }
			if let color = args["color"]?.stringValue.flatMap(ColorValue.init(hex:)) { label.color = color }
			if let background = args["background"]?.stringValue { label.background = background == "none" ? nil : ColorValue(hex: background) }
			if let animation = args["animation"]?.stringValue.flatMap(TextAnimation.init(rawValue:)) { label.animation = animation }
			let item = AnnotationItem(range: try range(args, in: store), kind: .text(label), anchor: args["anchor"]?.stringValue == "screen" ? .screen : .canvas)
			store.apply("Add text", source: .assistant) { $0.annotations.append(item) }
			return .json(EditResult(summary: "Added \(item.id)", project: ProjectSummary(store)))
		}
	}

	static let addArrow = MCPTool(
		name: "add_arrow", title: "Add arrow", description: "Adds an arrow from (from_x, from_y) to (to_x, to_y) on the recording.",
		inputSchema: JSONSchema.object(merge(timeArgs, [
			"project": projectArg,
			"from_x": JSONSchema.number(nil, minimum: 0, maximum: 1), "from_y": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"to_x": JSONSchema.number(nil, minimum: 0, maximum: 1), "to_y": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"color": JSONSchema.string("#RRGGBB"),
		]), required: ["start", "end", "from_x", "from_y", "to_x", "to_y"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			var arrow = ArrowAnnotation(from: point(args, "from_x", "from_y"), to: point(args, "to_x", "to_y"))
			if let color = args["color"]?.stringValue.flatMap(ColorValue.init(hex:)) { arrow.color = color }
			let item = AnnotationItem(range: try range(args, in: store), kind: .arrow(arrow))
			store.apply("Add arrow", source: .assistant) { $0.annotations.append(item) }
			return .json(EditResult(summary: "Added \(item.id)", project: ProjectSummary(store)))
		}
	}

	static let setVolume = MCPTool(
		name: "set_volume", title: "Set volume", description: "Changes volume for a section (gain 0 = mute, 1 = unchanged, up to 2) on all audio, the microphone or system audio.",
		inputSchema: JSONSchema.object(merge(timeArgs, [
			"project": projectArg, "gain": JSONSchema.number(nil, minimum: 0, maximum: 2),
			"channel": JSONSchema.string(nil, enum: VolumeItem.Channel.allCases.map(\.rawValue)),
		]), required: ["start", "end", "gain"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let item = VolumeItem(
				range: try range(args, in: store), gain: (args["gain"]?.doubleValue ?? 1).clamped(to: 0...2),
				channel: VolumeItem.Channel(rawValue: args["channel"]?.stringValue ?? "") ?? .all
			)
			store.apply("Set volume", source: .assistant) { $0.audio.volumes.append(item) }
			return .json(EditResult(summary: "Added \(item.id)", project: ProjectSummary(store)))
		}
	}

	static let updateItem = MCPTool(
		name: "update_item", title: "Update item",
		description: "Changes an item by id (from get_project). Pass only what changes: start/end for any item; scale/x/y for zooms (x/y make it a fixed point); rate for speed; gain for volume; text for labels; x/y/width/height/amount for masks.",
		inputSchema: JSONSchema.object([
			"project": projectArg, "id": JSONSchema.string(),
			"start": JSONSchema.number(nil, minimum: 0), "end": JSONSchema.number(nil, minimum: 0),
			"scale": JSONSchema.number(nil, minimum: 1, maximum: 5), "rate": JSONSchema.number(nil, minimum: 0.25, maximum: 16),
			"gain": JSONSchema.number(nil, minimum: 0, maximum: 2), "text": JSONSchema.string(),
			"x": JSONSchema.number(nil, minimum: 0, maximum: 1), "y": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"width": JSONSchema.number(nil, minimum: 0.01, maximum: 1), "height": JSONSchema.number(nil, minimum: 0.01, maximum: 1),
			"amount": JSONSchema.number(nil, minimum: 0, maximum: 1),
		], required: ["id"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			guard let raw = args["id"]?.stringValue, let current = store.item(ItemID(raw)) else { throw ToolError("No item with that id.") }
			let id = ItemID(raw)
			let newRange = TimeRange(start: args["start"]?.doubleValue ?? current.range.start, end: args["end"]?.doubleValue ?? current.range.end)
			guard newRange.end > newRange.start else { throw ToolError("end must be after start.") }
			store.apply("Update \(raw)", source: .assistant) { p in
				if let i = p.zooms.firstIndex(where: { $0.id == id }) {
					p.zooms[i].range = newRange
					if let scale = args["scale"]?.doubleValue { p.zooms[i].scale = scale.clamped(to: ZoomItem.scaleRange) }
					if args["x"] != nil || args["y"] != nil { p.zooms[i].target = .point(point(args)) }
					p.zooms[i].source = .user
				}
				if let i = p.cuts.firstIndex(where: { $0.id == id }) { p.cuts[i].range = newRange }
				if let i = p.speeds.firstIndex(where: { $0.id == id }) {
					p.speeds[i].range = newRange
					if let rate = args["rate"]?.doubleValue { p.speeds[i].rate = rate.clamped(to: SpeedItem.rateRange) }
				}
				if let i = p.audio.volumes.firstIndex(where: { $0.id == id }) {
					p.audio.volumes[i].range = newRange
					if let gain = args["gain"]?.doubleValue { p.audio.volumes[i].gain = gain.clamped(to: 0...2) }
				}
				if let i = p.masks.firstIndex(where: { $0.id == id }) {
					p.masks[i].range = newRange
					var rect = p.masks[i].rect
					if let x = args["x"]?.doubleValue { rect.x = x }
					if let y = args["y"]?.doubleValue { rect.y = y }
					if let w = args["width"]?.doubleValue { rect.width = w }
					if let h = args["height"]?.doubleValue { rect.height = h }
					p.masks[i].rect = rect.clamped()
					if let amount = args["amount"]?.doubleValue {
						p.masks[i].kind = switch p.masks[i].kind {
						case .blur: .blur(amount: amount)
						case .pixelate: .pixelate(amount: amount)
						case .highlight: .highlight(amount: amount)
						}
					}
				}
				if let i = p.annotations.firstIndex(where: { $0.id == id }) {
					p.annotations[i].range = newRange
					if case .text(var label) = p.annotations[i].kind {
						if let text = args["text"]?.stringValue { label.text = text }
						if args["x"] != nil || args["y"] != nil { label.position = point(args, default: label.position) }
						p.annotations[i].kind = .text(label)
					}
				}
			}
			return .json(EditResult(summary: "Updated \(raw)", project: ProjectSummary(store)))
		}
	}

	static let removeItems = MCPTool(
		name: "remove_items", title: "Remove items", description: "Removes items by id, or every item of a kind (zoom, cut, speed, mask, annotation, volume, all). only_polish keeps the user's own items.",
		inputSchema: JSONSchema.object([
			"project": projectArg, "ids": JSONSchema.array(of: JSONSchema.string()),
			"kind": JSONSchema.string(nil, enum: ["zoom", "cut", "speed", "mask", "annotation", "volume", "all"]),
			"only_polish": JSONSchema.boolean(),
		]), destructive: true
	) { args in
		try await MainActor.run {
			let store = try store(args)
			var ids = Set((args["ids"]?.arrayValue ?? []).compactMap(\.stringValue).map { ItemID($0) })
			let kind = args["kind"]?.stringValue
			let polishOnly = args["only_polish"]?.boolValue == true
			let p = store.project
			func pick<T: TimelineItem>(_ items: [T], _ name: String, source: (T) -> ItemSource?) {
				guard kind == name || kind == "all" else { return }
				for item in items where !polishOnly || source(item) == .polish { ids.insert(item.id) }
			}
			pick(p.zooms, "zoom") { $0.source }
			pick(p.cuts, "cut") { $0.source }
			pick(p.speeds, "speed") { $0.source }
			pick(p.masks, "mask") { $0.source }
			pick(p.annotations, "annotation") { $0.source }
			pick(p.audio.volumes, "volume") { _ in nil }
			guard !ids.isEmpty else { throw ToolError("Nothing matched.") }
			store.delete(ids)
			return .json(EditResult(summary: "Removed \(ids.count) item(s)", project: ProjectSummary(store)))
		}
	}

	static let setStyle = MCPTool(
		name: "set_style", title: "Set style",
		description: "Changes the look. background: 'desktop' (the wallpaper captured while recording), '#RRGGBB', 'gradient:#A,#B', or an image path (e.g. a macOS wallpaper from /System/Library/Desktop Pictures). placement: 'original' keeps a window/area at its on-screen size on a screen-shaped frame; 'fit' fits it with padding. Other fields: padding 0–0.4, corner_radius 0–0.1, shadow 0–1, aspect_ratio, camera (slow/mellow/quick/rapid), motion_blur 0–1, cursor_size 0.5–4, cursor_smoothing 0–1, hide_idle_cursor, click_effect, shortcut_keys.",
		inputSchema: JSONSchema.object([
			"project": projectArg, "background": JSONSchema.string(),
			"background_blur": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"placement": JSONSchema.string(nil, enum: Style.Placement.allCases.map(\.rawValue)),
			"padding": JSONSchema.number(nil, minimum: 0, maximum: 0.4), "corner_radius": JSONSchema.number(nil, minimum: 0, maximum: 0.1),
			"shadow": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"aspect_ratio": JSONSchema.string(nil, enum: AspectRatio.allCases.map(\.rawValue)),
			"camera": JSONSchema.string(nil, enum: ["slow", "mellow", "quick", "rapid"]),
			"motion_blur": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"cursor_size": JSONSchema.number(nil, minimum: 0.5, maximum: 4), "cursor_smoothing": JSONSchema.number(nil, minimum: 0, maximum: 1),
			"hide_idle_cursor": JSONSchema.boolean(),
			"click_effect": JSONSchema.string(nil, enum: CursorSettings.ClickEffect.allCases.map(\.rawValue)),
			"shortcut_keys": JSONSchema.boolean("Show pressed shortcuts as keycaps"),
		])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			store.apply("Change style", source: .assistant) { p in
				if let value = args["background"]?.stringValue {
					if value == "desktop" { p.style.background = .desktop }
					else if value.hasPrefix("gradient:") {
						let colors = value.dropFirst(9).split(separator: ",").compactMap { ColorValue(hex: String($0)) }
						if colors.count >= 2 { p.style.background = .gradient(GradientFill(colors: colors)) }
					} else if let color = ColorValue(hex: value) { p.style.background = .color(color) }
					else if value.hasPrefix("/") || value.hasPrefix("~") { p.style.background = .image(path: (value as NSString).expandingTildeInPath) }
				}
				if let v = args["background_blur"]?.doubleValue { p.style.backgroundBlur = v }
				if let v = args["placement"]?.stringValue.flatMap(Style.Placement.init(rawValue:)) { p.style.placement = v }
				if let v = args["padding"]?.doubleValue { p.style.padding = v.clamped(to: 0...0.4) }
				if let v = args["corner_radius"]?.doubleValue { p.style.cornerRadius = v.clamped(to: 0...0.1) }
				if let v = args["shadow"]?.doubleValue { p.style.shadow.opacity = v.clamped(to: 0...1) }
				if let v = args["aspect_ratio"]?.stringValue.flatMap(AspectRatio.init(rawValue:)) { p.style.aspectRatio = v }
				if let v = args["camera"]?.stringValue.flatMap(CameraSettings.Preset.init(rawValue:)) { p.camera.preset = v }
				if let v = args["motion_blur"]?.doubleValue { p.camera.motionBlur = v.clamped(to: 0...1) }
				if let v = args["cursor_size"]?.doubleValue { p.cursor.size = v.clamped(to: 0.5...4) }
				if let v = args["cursor_smoothing"]?.doubleValue { p.cursor.smoothing = v.clamped(to: 0...1) }
				if let v = args["hide_idle_cursor"]?.boolValue { p.cursor.hideWhenIdle = v }
				if let v = args["click_effect"]?.stringValue.flatMap(CursorSettings.ClickEffect.init(rawValue:)) { p.cursor.clickEffect = v }
				if let v = args["shortcut_keys"]?.boolValue { p.shortcutOverlay.enabled = v }
			}
			return .json(EditResult(summary: "Style updated", project: ProjectSummary(store)))
		}
	}

	static let listPresets = MCPTool(name: "list_presets", title: "List style presets", description: "Built-in and saved looks.", readOnly: true) { _ in
		await MainActor.run { .json(app.presets.all.map(\.name)) }
	}

	static let applyPreset = MCPTool(
		name: "apply_preset", title: "Apply style preset", description: "Applies a saved look (background, frame, camera, cursor, keycaps, caption style).",
		inputSchema: JSONSchema.object(["project": projectArg, "name": JSONSchema.string()], required: ["name"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			guard let name = args["name"]?.stringValue, let preset = app.presets.all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
				throw ToolError("No preset with that name. Use list_presets.")
			}
			store.apply("Apply style \(preset.name)", source: .assistant) { preset.apply(to: &$0) }
			return .text("Applied \(preset.name)")
		}
	}

	static let savePreset = MCPTool(
		name: "save_preset", title: "Save style preset", description: "Saves the project's current look as a preset.",
		inputSchema: JSONSchema.object(["project": projectArg, "name": JSONSchema.string()], required: ["name"])
	) { args in
		try await MainActor.run {
			let store = try store(args)
			let preset = StylePreset(name: args["name"]?.stringValue ?? "Preset", from: store.project)
			app.presets.save(preset)
			return .text("Saved preset \(preset.name)")
		}
	}

	static let captions = MCPTool(
		name: "captions", title: "Captions",
		description: "action 'generate' transcribes speech on-device (first run downloads a model); 'remove' deletes captions; 'style' sets mode (line/word) and position (bottom/top).",
		inputSchema: JSONSchema.object([
			"project": projectArg, "action": JSONSchema.string(nil, enum: ["generate", "remove", "style"]),
			"model": JSONSchema.string(nil, enum: CaptionModel.allCases.map(\.rawValue)),
			"mode": JSONSchema.string(nil, enum: CaptionStyle.Mode.allCases.map(\.rawValue)),
			"position": JSONSchema.string(nil, enum: CaptionStyle.Position.allCases.map(\.rawValue)),
		], required: ["action"])
	) { args in
		let store = try await MainActor.run { try MCPTools.store(args) }
		switch args["action"]?.stringValue {
		case "generate":
			let model = CaptionModel(rawValue: args["model"]?.stringValue ?? "") ?? .base
			try await app.generateCaptions(for: store, model: model, source: .assistant) { _ in }
			let count = await MainActor.run { store.project.captions?.segments.count ?? 0 }
			return .text("Generated \(count) caption lines")
		case "remove":
			await MainActor.run { store.apply("Remove captions", source: .assistant) { $0.captions = nil } }
			return .text("Captions removed")
		default:
			await MainActor.run {
				store.apply("Caption style", source: .assistant) { p in
					guard p.captions != nil else { return }
					if let mode = args["mode"]?.stringValue.flatMap(CaptionStyle.Mode.init(rawValue:)) { p.captions?.style.mode = mode }
					if let position = args["position"]?.stringValue.flatMap(CaptionStyle.Position.init(rawValue:)) { p.captions?.style.position = position }
				}
			}
			return .text("Caption style updated")
		}
	}

	static let audio = MCPTool(
		name: "audio", title: "Audio",
		description: "noise_reduction on/off for the microphone; music: a file path to add as background music (ducked under speech) or 'none'; microphone_volume / system_volume 0–2.",
		inputSchema: JSONSchema.object([
			"project": projectArg, "noise_reduction": JSONSchema.boolean(), "music": JSONSchema.string(),
			"microphone_volume": JSONSchema.number(nil, minimum: 0, maximum: 2), "system_volume": JSONSchema.number(nil, minimum: 0, maximum: 2),
		])
	) { args in
		let store = try await MainActor.run { try MCPTools.store(args) }
		if let enabled = args["noise_reduction"]?.boolValue { await store.setNoiseReduction(enabled) }
		try await MainActor.run {
			if let music = args["music"]?.stringValue {
				try store.setMusic(from: music == "none" ? nil : URL(fileURLWithPath: (music as NSString).expandingTildeInPath))
			}
			if args["microphone_volume"] != nil || args["system_volume"] != nil {
				store.apply("Audio levels", source: .assistant) { p in
					if let v = args["microphone_volume"]?.doubleValue { p.audio.microphoneVolume = v }
					if let v = args["system_volume"]?.doubleValue { p.audio.systemVolume = v }
				}
			}
		}
		return .text("Audio updated")
	}

	static let export = MCPTool(
		name: "export", title: "Export",
		description: "Renders the video. format mp4/gif; resolution 720p/1080p/1440p/4K; fps 30/60; codec h264/hevc; quality studio/social/web. Returns the file path. Default folder ~/Movies/Nebula Exports.",
		inputSchema: JSONSchema.object([
			"project": projectArg, "format": JSONSchema.string(nil, enum: ["mp4", "gif"]),
			"resolution": JSONSchema.string(nil, enum: ExportSettings.Resolution.allCases.map(\.rawValue)),
			"fps": JSONSchema.integer(nil, minimum: 10, maximum: 60), "codec": JSONSchema.string(nil, enum: ["h264", "hevc"]),
			"quality": JSONSchema.string(nil, enum: ExportSettings.Quality.allCases.map(\.rawValue)),
			"path": JSONSchema.string("Output file path"),
		])
	) { args in
		let store = try await MainActor.run { try MCPTools.store(args) }
		var settings = await MainActor.run { store.project.export }
		if let v = args["format"]?.stringValue.flatMap(ExportSettings.Format.init(rawValue:)) { settings.format = v }
		if let v = args["resolution"]?.stringValue.flatMap(ExportSettings.Resolution.init(rawValue:)) { settings.resolution = v }
		if let v = args["fps"]?.intValue { settings.fps = v; settings.gifFPS = min(v, 30) }
		if let v = args["codec"]?.stringValue.flatMap(ExportSettings.Codec.init(rawValue:)) { settings.codec = v }
		if let v = args["quality"]?.stringValue.flatMap(ExportSettings.Quality.init(rawValue:)) { settings.quality = v }
		let path = args["path"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
		let url = try await app.exports.export(store, settings: settings, to: path)
		return .text("Exported to \(url.path)")
	}

	// MARK: - Recording

	static let listSources = MCPTool(name: "list_sources", title: "List sources", description: "Displays, windows and microphones that can be recorded.", readOnly: true) { _ in
		let displays = (try? await CaptureSources.displays()) ?? []
		let windows = (try? await CaptureSources.windows()) ?? []
		return .json(SourcesSummary(
			displays: displays.map { .init(id: Int($0.id), name: $0.name, width: Int($0.frame.width), height: Int($0.frame.height)) },
			windows: windows.map { .init(id: Int($0.id), app: $0.appName, title: $0.title) },
			microphones: CaptureSources.microphones().map(\.name)
		))
	}

	static let startRecording = MCPTool(
		name: "start_recording", title: "Start recording",
		description: "Starts recording after the countdown: mode display (display_id), window (window_id or window_title), or area (display_id plus x/y/width/height in points). Depending on settings, the user is asked first.",
		inputSchema: JSONSchema.object([
			"mode": JSONSchema.string(nil, enum: ["display", "window", "area"]),
			"display_id": JSONSchema.integer(), "window_id": JSONSchema.integer(), "window_title": JSONSchema.string(),
			"x": JSONSchema.number(), "y": JSONSchema.number(), "width": JSONSchema.number(), "height": JSONSchema.number(),
		])
	) { args in
		let windows = (try? await CaptureSources.windows()) ?? []
		return try await MainActor.run {
			guard !app.recorder.isRecording else { throw ToolError("Already recording.") }
			switch app.settings.mcpRecording {
			case .never: throw ToolError("The user has turned off recording from AI assistants in Nebula's settings.")
			case .ask:
				NSApp.activate()
				let alert = NSAlert()
				alert.messageText = "Claude wants to start a screen recording"
				alert.informativeText = "Nebula will record after a short countdown. You can stop it any time."
				alert.addButton(withTitle: "Allow")
				alert.addButton(withTitle: "Don't Allow")
				guard alert.runModal() == .alertFirstButtonReturn else { throw ToolError("The user declined the recording.") }
			case .always: break
			}
			let recorder = app.recorder
			recorder.mode = RecorderController.Mode(rawValue: args["mode"]?.stringValue ?? "display") ?? .display
			if let id = args["display_id"]?.intValue { recorder.displayID = CGDirectDisplayID(id) }
			if recorder.displayID == nil { recorder.displayID = CGMainDisplayID() }
			if let id = args["window_id"]?.intValue { recorder.windowID = CGWindowID(id) }
			if let title = args["window_title"]?.stringValue {
				recorder.windowID = windows.first { $0.title.localizedCaseInsensitiveContains(title) || $0.appName.localizedCaseInsensitiveContains(title) }?.id
			}
			if recorder.mode == .area {
				recorder.area = CGRect(x: args["x"]?.doubleValue ?? 0, y: args["y"]?.doubleValue ?? 0, width: args["width"]?.doubleValue ?? 1280, height: args["height"]?.doubleValue ?? 720)
			}
			recorder.start(assistant: true)
			if let message = recorder.errorMessage { throw ToolError(message) }
			return .text("Recording starts after a \(app.settings.countdown)s countdown. Call stop_recording when done.")
		}
	}

	static let pauseRecording = MCPTool(name: "pause_recording", title: "Pause or resume", description: "Pauses or resumes the current recording.") { _ in
		try await MainActor.run {
			guard app.recorder.isRecording else { throw ToolError("Not recording.") }
			app.recorder.togglePause()
			return .text(app.recorder.phase == .paused ? "Paused" : "Recording")
		}
	}

	static let stopRecording = MCPTool(name: "stop_recording", title: "Stop recording", description: "Finishes the recording and opens it as a project. Returns the project summary.") { _ in
		guard await app.recorder.isRecording else { throw ToolError("Not recording.") }
		guard let bundle = await app.recorder.finish() else { throw ToolError(await app.recorder.errorMessage ?? "Recording failed.") }
		return try await MainActor.run { .json(ProjectSummary(try app.store(for: bundle.url))) }
	}

	static let undo = MCPTool(name: "undo", title: "Undo", description: "Undoes the last edit (the user's or yours).", inputSchema: JSONSchema.object(["project": projectArg])) { args in
		try await MainActor.run {
			let store = try store(args)
			store.undo()
			return .json(ProjectSummary(store))
		}
	}

	static let redo = MCPTool(name: "redo", title: "Redo", description: "Redoes the last undone edit.", inputSchema: JSONSchema.object(["project": projectArg])) { args in
		try await MainActor.run {
			let store = try store(args)
			store.redo()
			return .json(ProjectSummary(store))
		}
	}
}

func rounded(_ value: Double, _ places: Int = 3) -> Double {
	let factor = pow(10, Double(places))
	return (value * factor).rounded() / factor
}
