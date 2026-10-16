import Foundation
import Observation

/// Transient notices at the bottom of the editor ("Claude added 4 zooms · Undo").
@MainActor
@Observable
public final class ToastCenter {
	public struct Toast: Identifiable, Equatable {
		public let id = UUID()
		public var title: String
		public var detail: String?
		public var isAssistant: Bool
		public var showsUndo: Bool
	}

	public private(set) var current: Toast?
	@ObservationIgnored private var dismissTask: Task<Void, Never>?

	public init() {}

	public func show(_ title: String, detail: String? = nil, isAssistant: Bool = false, showsUndo: Bool = false, duration: Double = 4) {
		current = Toast(title: title, detail: detail, isAssistant: isAssistant, showsUndo: showsUndo)
		dismissTask?.cancel()
		dismissTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(duration))
			guard !Task.isCancelled else { return }
			self?.current = nil
		}
	}

	public func dismiss() {
		current = nil
	}
}
