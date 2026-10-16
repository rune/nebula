import NebulaApp
import SwiftUI

@main
struct NebulaMain: App {
	@NSApplicationDelegateAdaptor(NebulaAppDelegate.self) private var delegate

	var body: some Scene {
		NebulaScenes()
	}
}
