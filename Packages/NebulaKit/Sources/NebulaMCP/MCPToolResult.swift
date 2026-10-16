import Foundation

/// The result of a tool call.
///
/// A result with `isError == true` is reported to the model as a failed tool call (not as a
/// protocol error), so the model can read the message and try again.
public struct MCPToolResult: Sendable, Hashable {
	/// The content blocks returned to the client.
	public var content: [MCPContent]
	/// Whether the tool call failed.
	public var isError: Bool

	/// Creates a result from content blocks.
	public init(content: [MCPContent], isError: Bool = false) {
		self.content = content
		self.isError = isError
	}

	/// A successful result with one text block.
	public static func text(_ text: String) -> MCPToolResult {
		MCPToolResult(content: [.text(text)])
	}

	/// A successful result with one text block holding `value` as pretty-printed JSON with sorted keys.
	///
	/// If the value cannot be encoded, an error result describing the failure is returned instead.
	public static func json(_ value: some Encodable) -> MCPToolResult {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		do {
			let data = try encoder.encode(value)
			return .text(String(decoding: data, as: UTF8.self))
		} catch {
			return .error("Could not encode the result as JSON: \(error.localizedDescription)")
		}
	}

	/// A successful result with one image block.
	public static func image(_ data: Data, mimeType: String) -> MCPToolResult {
		MCPToolResult(content: [.image(data: data, mimeType: mimeType)])
	}

	/// A failed result with one text block describing the problem.
	public static func error(_ message: String) -> MCPToolResult {
		MCPToolResult(content: [.text(message)], isError: true)
	}

	/// The MCP wire representation of this result.
	var jsonValue: JSONValue {
		["content": .array(content.map(\.jsonValue)), "isError": .bool(isError)]
	}
}
