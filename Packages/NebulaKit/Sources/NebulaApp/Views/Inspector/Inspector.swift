import NebulaCore
import NebulaDesign
import SwiftUI

/// The right-hand panel. Shows the selected item when there is one, otherwise the tabs.
struct Inspector: View {
	let store: ProjectStore
	@State private var tab: Tab = .look

	enum Tab: String, CaseIterable {
		case look, camera, cursor, captions, audio

		var symbol: String {
			switch self {
			case .look: "photo"
			case .camera: "plus.magnifyingglass"
			case .cursor: "cursorarrow"
			case .captions: "captions.bubble"
			case .audio: "waveform"
			}
		}

		var title: String { rawValue.capitalized }
	}

	var body: some View {
		VStack(spacing: 0) {
			if store.selection.isEmpty, let clip = store.selectedClip {
				ClipInspector(store: store, clip: clip)
			} else if store.selection.isEmpty {
				tabBar
				Hairline()
				ScrollView {
					Group {
						switch tab {
						case .look: LookInspector(store: store)
						case .camera: CameraInspector(store: store)
						case .cursor: CursorInspector(store: store)
						case .captions: CaptionsInspector(store: store)
						case .audio: AudioInspector(store: store)
						}
					}
					.padding(18)
				}
				.scrollIndicators(.never)
			} else {
				SelectionInspector(store: store)
			}
		}
		.frame(width: 300)
		.background(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).fill(Theme.surface1))
		.overlay(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).strokeBorder(Theme.hairline))
		.clipShape(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
	}

	private var tabBar: some View {
		HStack(spacing: 4) {
			ForEach(Tab.allCases, id: \.self) { item in
				Button {
					withAnimation(Theme.snappy) { tab = item }
				} label: {
					Image(systemName: item.symbol)
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(tab == item ? Theme.text1 : Theme.text3)
						.frame(maxWidth: .infinity)
						.frame(height: 32)
						.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tab == item ? Theme.surface3 : .clear))
						.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tab == item ? Theme.hairlineStrong : .clear))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help(item.title)
			}
		}
		.padding(10)
	}
}

/// A titled group of controls inside an inspector tab.
struct InspectorSection<Content: View>: View {
	let title: String
	var trailing: String?
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SectionHeader(title, trailing: trailing)
			content
		}
		.padding(.bottom, 22)
	}
}

extension ProjectStore {
	/// A binding that edits the project through `apply`, merging a drag into one undo step.
	func binding<Value: Equatable>(_ label: String, _ keyPath: WritableKeyPath<Project, Value>) -> Binding<Value> {
		Binding(
			get: { self.project[keyPath: keyPath] },
			set: { value in self.apply(label, coalescing: label) { $0[keyPath: keyPath] = value } }
		)
	}
}
