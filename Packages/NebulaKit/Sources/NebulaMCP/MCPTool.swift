import Foundation

/// A tool exposed to MCP clients.
public struct MCPTool: Sendable {
	/// The unique, machine-readable name (for example `add_zoom`).
	public var name: String
	/// A short human-readable title.
	public var title: String
	/// What the tool does, written for the model.
	public var description: String
	/// A JSON Schema object describing the `arguments` the tool accepts. See ``JSONSchema``.
	public var inputSchema: JSONValue
	/// Whether the tool only reads state. Sent as the `readOnlyHint` annotation.
	public var readOnly: Bool
	/// Whether the tool may destroy data. Sent as the `destructiveHint` annotation.
	public var destructive: Bool
	/// Runs the tool with the call's `arguments` (an object; `{}` when the client sends none).
	///
	/// The handler is called from a background task, never on the main actor. Hop to the main actor
	/// inside the handler (for example `await MainActor.run { ... }`) to touch UI state. Throwing
	/// produces an error result carrying the error's `localizedDescription`.
	public var handler: @Sendable (JSONValue) async throws -> MCPToolResult

	/// Creates a tool.
	public init(
		name: String,
		title: String,
		description: String,
		inputSchema: JSONValue = JSONSchema.object([:]),
		readOnly: Bool = false,
		destructive: Bool = false,
		handler: @escaping @Sendable (JSONValue) async throws -> MCPToolResult
	) {
		self.name = name
		self.title = title
		self.description = description
		self.inputSchema = inputSchema
		self.readOnly = readOnly
		self.destructive = destructive
		self.handler = handler
	}

	/// The `tools/list` entry for this tool.
	var listing: JSONValue {
		[
			"name": .string(name),
			"title": .string(title),
			"description": .string(description),
			"inputSchema": inputSchema,
			"annotations": [
				"title": .string(title),
				"readOnlyHint": .bool(readOnly),
				"destructiveHint": .bool(destructive),
			],
		]
	}
}
