import SwiftUI

// MARK: - Buttons

public struct NebulaButtonStyle: ButtonStyle {
	public enum Kind {
		case primary
		case secondary
		case ghost
		/// Violet-tinted secondary, for AI actions like Polish.
		case accent
		case destructive
	}

	let kind: Kind
	let size: CGFloat

	public init(_ kind: Kind = .secondary, height: CGFloat = 30) {
		self.kind = kind
		self.size = height
	}

	public func makeBody(configuration: Configuration) -> some View {
		NebulaButtonBody(configuration: configuration, kind: kind, height: size)
	}
}

private struct NebulaButtonBody: View {
	let configuration: ButtonStyleConfiguration
	let kind: NebulaButtonStyle.Kind
	let height: CGFloat
	@Environment(\.isEnabled) private var isEnabled
	@State private var hovering = false

	var body: some View {
		configuration.label
			.font(.nebula(height > 34 ? 13.5 : 12.5, 650))
			.foregroundStyle(foreground)
			.padding(.horizontal, height > 34 ? 16 : 12)
			.frame(height: height)
			.background(background)
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
			.opacity(isEnabled ? 1 : 0.4)
			.scaleEffect(configuration.isPressed ? 0.97 : 1)
			.animation(Theme.snappy, value: configuration.isPressed)
			.onHover { hovering = $0 }
			.contentShape(Rectangle())
	}

	private var foreground: Color {
		switch kind {
		case .primary: .white
		case .ghost: hovering ? Theme.text1 : Theme.text2
		case .accent: Color(hex: 0xE9DCFF)
		case .destructive: Color(hex: 0xFF8FA3)
		case .secondary: Theme.text1
		}
	}

	@ViewBuilder private var background: some View {
		switch kind {
		case .primary:
			Theme.gradient.brightness(hovering ? 0.05 : 0)
		case .secondary:
			hovering ? Theme.surface3 : Theme.surface2
		case .ghost:
			hovering ? Theme.surface2 : Color.clear
		case .accent:
			Theme.violet.opacity(hovering ? 0.18 : 0.10)
		case .destructive:
			Color(hex: 0xFF3B5C).opacity(hovering ? 0.18 : 0.10)
		}
	}

	private var border: Color {
		switch kind {
		case .primary: Color.white.opacity(0.12)
		case .secondary: Theme.hairlineStrong
		case .ghost: .clear
		case .accent: Color(hex: 0xA05FFF).opacity(0.32)
		case .destructive: Color(hex: 0xFF3B5C).opacity(0.3)
		}
	}
}

/// A square icon button used in toolbars.
public struct IconButton: View {
	let systemName: String
	let help: String
	let action: () -> Void
	var isOn = false
	@State private var hovering = false

	public init(_ systemName: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
		self.systemName = systemName
		self.help = help
		self.isOn = isOn
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(isOn ? Theme.text1 : hovering ? Theme.text1 : Theme.text2)
				.frame(width: 30, height: 30)
				.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Theme.surface3 : hovering ? Theme.surface2 : .clear))
				.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isOn ? Theme.hairlineStrong : .clear))
		}
		.buttonStyle(.plain)
		.help(help)
		.onHover { hovering = $0 }
	}
}

// MARK: - Segmented control

public struct SegmentedPicker<Value: Hashable>: View {
	@Binding var selection: Value
	let options: [(Value, String)]
	@Namespace private var namespace

	public init(selection: Binding<Value>, options: [(Value, String)]) {
		self._selection = selection
		self.options = options
	}

	public var body: some View {
		HStack(spacing: 0) {
			ForEach(options, id: \.0) { value, title in
				let selected = value == selection
				Text(title)
					.font(.nebula(12, 650))
					.lineLimit(1)
					.minimumScaleFactor(0.75)
					.foregroundStyle(selected ? Theme.text1 : Theme.text3)
					.padding(.horizontal, 3)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 6)
					.background {
						if selected {
							RoundedRectangle(cornerRadius: 6, style: .continuous)
								.fill(Theme.surface3)
								.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineStrong))
								.shadow(color: .black.opacity(0.5), radius: 1, y: 1)
								.matchedGeometryEffect(id: "segment", in: namespace)
						}
					}
					.contentShape(Rectangle())
					.onTapGesture { withAnimation(Theme.snappy) { selection = value } }
			}
		}
		.padding(3)
		.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface2))
		.overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
	}
}

/// Pill choices that wrap, e.g. aspect ratios.
public struct ChipPicker<Value: Hashable>: View {
	@Binding var selection: Value
	let options: [(Value, String)]

	public init(selection: Binding<Value>, options: [(Value, String)]) {
		self._selection = selection
		self.options = options
	}

	public var body: some View {
		FlowLayout(spacing: 6) {
			ForEach(options, id: \.0) { value, title in
				let selected = value == selection
				Text(title)
					.font(.nebula(12, 650))
					.foregroundStyle(selected ? .white : Theme.text2)
					.padding(.horizontal, 10)
					.padding(.vertical, 6)
					.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.violetSoft : .clear))
					.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.violetLine : Theme.hairlineStrong))
					.contentShape(Rectangle())
					.onTapGesture { withAnimation(Theme.snappy) { selection = value } }
			}
		}
	}
}

// MARK: - Slider

/// A labelled slider: title and formatted value above a thin track with a violet fill.
public struct NebulaSlider: View {
	let title: String
	@Binding var value: Double
	let range: ClosedRange<Double>
	let format: (Double) -> String
	var onEditingChanged: (Bool) -> Void = { _ in }
	@State private var dragging = false

	public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: @escaping (Double) -> String, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
		self.title = title
		self._value = value
		self.range = range
		self.format = format
		self.onEditingChanged = onEditingChanged
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 9) {
			HStack {
				Text(title).font(.nebula(12.5, 600)).foregroundStyle(Theme.text2)
				Spacer()
				Text(format(value)).font(.nebula(12.5, 700)).foregroundStyle(Theme.text1).monospacedDigit()
			}
			GeometryReader { proxy in
				let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
				let x = proxy.size.width * fraction.clamped01
				ZStack(alignment: .leading) {
					Capsule().fill(Theme.surface3).frame(height: 4)
					Capsule().fill(Theme.sliderGradient).frame(width: max(4, x), height: 4)
					Circle()
						.fill(.white)
						.frame(width: dragging ? 16 : 14, height: dragging ? 16 : 14)
						.shadow(color: .black.opacity(0.6), radius: 2, y: 1)
						.offset(x: x - (dragging ? 8 : 7))
				}
				.frame(height: 16)
				.contentShape(Rectangle())
				.gesture(DragGesture(minimumDistance: 0)
					.onChanged { drag in
						if !dragging { dragging = true; onEditingChanged(true) }
						let f = (drag.location.x / max(proxy.size.width, 1)).clamped01
						value = range.lowerBound + f * (range.upperBound - range.lowerBound)
					}
					.onEnded { _ in dragging = false; onEditingChanged(false) })
			}
			.frame(height: 16)
			.animation(Theme.snappy, value: dragging)
		}
	}
}

// MARK: - Toggle

public struct NebulaToggleStyle: ToggleStyle {
	public init() {}

	public func makeBody(configuration: Configuration) -> some View {
		HStack {
			configuration.label.font(.nebula(12.5, 600)).foregroundStyle(Theme.text2)
			Spacer()
			ZStack(alignment: configuration.isOn ? .trailing : .leading) {
				Capsule().fill(configuration.isOn ? Theme.violet : Theme.surface3).frame(width: 30, height: 18)
				Circle().fill(configuration.isOn ? .white : Color(hex: 0x8B8996)).frame(width: 14, height: 14).padding(2)
			}
			.onTapGesture { withAnimation(Theme.snappy) { configuration.isOn.toggle() } }
		}
	}
}

// MARK: - Containers

/// A floating panel: surface 1, hairline border, large radius, neutral shadow.
public struct PanelModifier: ViewModifier {
	let radius: CGFloat

	public func body(content: Content) -> some View {
		content
			.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface1))
			.overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
			.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
			.shadow(color: .black.opacity(0.55), radius: 30, y: 20)
	}
}

extension View {
	public func nebulaPanel(radius: CGFloat = Theme.radiusL) -> some View {
		modifier(PanelModifier(radius: radius))
	}
}

/// Small uppercase section heading used in inspectors.
public struct SectionHeader: View {
	let title: String
	let trailing: String?

	public init(_ title: String, trailing: String? = nil) {
		self.title = title
		self.trailing = trailing
	}

	public var body: some View {
		HStack {
			Text(title.uppercased()).font(.nebula(11, 750)).tracking(0.66).foregroundStyle(Theme.text3)
			Spacer()
			if let trailing { Text(trailing).font(.nebula(11, 650)).foregroundStyle(Theme.text3) }
		}
	}
}

/// A keyboard-shortcut hint like `⌘K`.
public struct KeyHint: View {
	let keys: String

	public init(_ keys: String) {
		self.keys = keys
	}

	public var body: some View {
		Text(keys)
			.font(.nebula(10.5, 700))
			.foregroundStyle(Theme.text3)
			.padding(.horizontal, 5)
			.padding(.vertical, 1)
			.overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairlineStrong))
	}
}

public struct Hairline: View {
	public init() {}
	public var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

// MARK: - Layout

/// Wrapping horizontal layout for chips.
public struct FlowLayout: Layout {
	let spacing: CGFloat

	public init(spacing: CGFloat = 6) {
		self.spacing = spacing
	}

	public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? .infinity
		var x: CGFloat = 0
		var y: CGFloat = 0
		var row: CGFloat = 0
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			if x + size.width > width, x > 0 {
				x = 0
				y += row + spacing
				row = 0
			}
			x += size.width + spacing
			row = max(row, size.height)
		}
		return CGSize(width: proposal.width ?? x, height: y + row)
	}

	public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = bounds.minX
		var y = bounds.minY
		var row: CGFloat = 0
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			if x + size.width > bounds.maxX, x > bounds.minX {
				x = bounds.minX
				y += row + spacing
				row = 0
			}
			view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
			x += size.width + spacing
			row = max(row, size.height)
		}
	}
}

extension Double {
	var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
