import NebulaCore
import NebulaDesign
import SwiftUI

/// Settings for the selected clip on the video track.
struct ClipInspector: View {
	let store: ProjectStore
	let clip: Clip

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Clip \(clip.index + 1) of \(store.project.clips.count)").font(.nebula(13.5, 750)).foregroundStyle(Theme.text1)
				Spacer()
				Button("Done") { store.selectClip(nil) }
					.buttonStyle(NebulaButtonStyle(.ghost, height: 26))
			}
			.padding(.horizontal, 18)
			.frame(height: 52)
			Hairline()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					HStack(spacing: 18) {
						stat("Starts", Format.time(clip.outputStart))
						stat("Length", Format.time(clip.outputDuration))
						stat("From recording", "\(Format.time(clip.source.start, tenths: false))–\(Format.time(clip.source.end, tenths: false))")
					}
					.padding(.bottom, 22)

					InspectorSection(title: "Speed") {
						RateChips(rate: clip.rate) { store.setRate($0, for: clip) }
						NebulaSlider("Rate", value: Binding(
							// Log scale: equal steps from 0.25× to 16×.
							get: { log2(clip.rate) },
							set: { store.setRate((pow(2, $0) * 4).rounded() / 4, for: clip, coalescing: "clip-speed-\(clip.index)") }
						), in: -2...4) { Format.rate(pow(2, $0)) }
						if clip.rate != 1 {
							Text("Saves \(Format.time(clip.source.duration - clip.outputDuration)).")
								.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
						}
					}

					InspectorSection(title: "Edit") {
						SplitButton(store: store, clip: clip, styled: true)
						Text("Drag either edge of the clip on the timeline to trim it. Dragging outward brings back what was trimmed.")
							.font(.nebula(11.5, 550)).foregroundStyle(Theme.text3)
							.fixedSize(horizontal: false, vertical: true)
					}

					Button(role: .destructive) {
						store.deleteClip(clip)
					} label: {
						Label("Delete clip", systemImage: "rectangle.badge.minus").frame(maxWidth: .infinity)
					}
					.buttonStyle(NebulaButtonStyle(.destructive, height: 32))
					.disabled(store.project.clips.count <= 1)
				}
				.padding(18)
			}
			.scrollIndicators(.never)
		}
	}

	private func stat(_ title: String, _ value: String) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title.uppercased()).font(.nebula(10, 750)).tracking(0.6).foregroundStyle(Theme.text3)
			Text(value).font(.nebula(13, 700)).monospacedDigit().foregroundStyle(Theme.text1)
		}
	}
}
