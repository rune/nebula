import Foundation

/// A convenience error for tool handlers.
///
/// Throwing it from a handler turns into an error result whose text is `message`.
public struct MCPToolError: LocalizedError, Sendable, Hashable {
	/// The message shown to the model.
	public var message: String

	/// Creates an error with a message.
	public init(_ message: String) {
		self.message = message
	}

	/// The message shown to the model.
	public var errorDescription: String? {
		message
	}
}
