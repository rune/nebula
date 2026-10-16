import AppKit
import NebulaCore
import NebulaDesign
import SwiftUI

/// Time and size formatting shared by the views.
enum Format {
	/// `0:18.2`
	static func time(_ seconds: Double, tenths: Bool = true) -> String {
		let s = max(0, seconds.isFinite ? seconds : 0)
		let minutes = Int(s) / 60
		if tenths {
			let rest = s - Double(minutes * 60)
			return String(format: "%d:%04.1f", minutes, rest)
		}
		return String(format: "%d:%02d", minutes, Int(s) % 60)
	}

	/// `1:05` for library cards.
	static func duration(_ seconds: Double) -> String {
		time(seconds.rounded(), tenths: false)
	}

	static func percent(_ value: Double) -> String {
		"\(Int((value * 100).rounded()))%"
	}

	static func rate(_ value: Double) -> String {
		value == value.rounded() ? "\(Int(value))×" : String(format: "%.2g×", value)
	}

	static func bytes(_ value: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
	}

	@MainActor static let relative: RelativeDateTimeFormatter = {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .short
		return formatter
	}()
}

extension ColorValue {
	var color: Color {
		Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
	}

	init(_ color: Color) {
		let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
		self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
	}
}

/// A label + content row used throughout the inspector.
struct InspectorRow<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	var body: some View {
		HStack {
			Text(title).font(.nebula(12.5, 600)).foregroundStyle(Theme.text2)
			Spacer(minLength: 12)
			content
		}
	}
}

/// A Toggle styled for the inspector.
struct InspectorToggle: View {
	let title: String
	@Binding var isOn: Bool

	init(_ title: String, isOn: Binding<Bool>) {
		self.title = title
		self._isOn = isOn
	}

	var body: some View {
		Toggle(title, isOn: $isOn).toggleStyle(NebulaToggleStyle())
	}
}

/// A compact menu button styled like the rest of the controls.
struct MenuChip<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	var body: some View {
		Menu {
			content
		} label: {
			HStack(spacing: 5) {
				Text(title).font(.nebula(12, 650)).foregroundStyle(Theme.text1)
				Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
			}
			.padding(.horizontal, 10)
			.frame(height: 26)
			.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface2))
			.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairlineStrong))
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
	}
}

/// Playback-rate choices in one row of equal-width chips.
struct RateChips: View {
	let rate: Double
	var options: [Double] = [0.5, 1, 1.5, 2, 3, 4, 8]
	let onSelect: (Double) -> Void

	var body: some View {
		HStack(spacing: 4) {
			ForEach(options, id: \.self) { option in
				let selected = abs(option - rate) < 0.001
				Text(Format.rate(option))
					.font(.nebula(11.5, 650))
					.lineLimit(1)
					.minimumScaleFactor(0.8)
					.foregroundStyle(selected ? .white : Theme.text2)
					.frame(maxWidth: .infinity)
					.frame(height: 28)
					.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(selected ? Theme.violetSoft : .clear))
					.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(selected ? Theme.violetLine : Theme.hairlineStrong))
					.contentShape(Rectangle())
					.onTapGesture { onSelect(option) }
			}
		}
	}
}

/// Text field styled for dark surfaces.
struct NebulaTextField: View {
	let placeholder: String
	@Binding var text: String
	var onCommit: () -> Void = {}

	var body: some View {
		TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.text3))
			.textFieldStyle(.plain)
			.font(.nebula(12.5, 600))
			.foregroundStyle(Theme.text1)
			.padding(.horizontal, 10)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface2))
			.overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairlineStrong))
			.onSubmit(onCommit)
	}
}

/// Gives SwiftUI access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
	let onWindow: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = WindowReportingView()
		view.onWindow = onWindow
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {}

	final class WindowReportingView: NSView {
		var onWindow: ((NSWindow) -> Void)?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let window { onWindow?(window) }
		}
	}
}

/// Loads small images off the main thread and caches them.
@MainActor
final class ImageCache {
	static let shared = ImageCache()
	private let cache = NSCache<NSString, NSImage>()

	func image(for url: URL, maxPixel: Int = 480) async -> NSImage? {
		let nsKey = "\(url.path)#\(maxPixel)" as NSString
		if let hit = cache.object(forKey: nsKey) { return hit }
		let cg = await Task.detached(priority: .utility) { () -> CGImage? in
			guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
			let options: [CFString: Any] = [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceThumbnailMaxPixelSize: maxPixel,
				kCGImageSourceCreateThumbnailWithTransform: true,
			]
			return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
		}.value
		guard let cg else { return nil }
		let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
		cache.setObject(image, forKey: nsKey)
		return image
	}

	/// Drops cached images, e.g. after a thumbnail was rewritten.
	func removeAll() {
		cache.removeAllObjects()
	}
}

/// An image loaded from disk with a placeholder.
struct AsyncFileImage: View {
	let url: URL?
	var maxPixel = 480
	var contentMode: ContentMode = .fill
	@State private var image: NSImage?

	var body: some View {
		ZStack {
			if let image {
				Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
			} else {
				Theme.surface2
			}
		}
		.task(id: url) {
			guard let url else { return }
			image = await ImageCache.shared.image(for: url, maxPixel: maxPixel)
		}
	}
}
