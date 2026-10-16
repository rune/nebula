import Foundation

/// Handles one JSON-RPC 2.0 message carrying an MCP request or notification.
///
/// Stateless: every POST is self-contained, so no session is created or tracked.
struct MCPDispatcher: Sendable {
	/// Protocol revisions this server speaks, newest first.
	static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

	/// JSON-RPC error codes.
	enum ErrorCode {
		static let parseError = -32700
		static let invalidRequest = -32600
		static let methodNotFound = -32601
		static let invalidParams = -32602
	}

	/// What to send back over HTTP.
	enum Outcome: Sendable, Hashable {
		/// A JSON-RPC response body with the HTTP status to use.
		case reply(JSONValue, status: Int)
		/// The message was a notification or a response; answer `202 Accepted` with no body.
		case accepted
	}

	let name: String
	let version: String
	let instructions: String
	let tools: [MCPTool]
	private let toolsByName: [String: MCPTool]

	init(name: String, version: String, instructions: String, tools: [MCPTool]) {
		self.name = name
		self.version = version
		self.instructions = instructions
		self.tools = tools
		self.toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
	}

	/// Handles one POST body.
	func handle(_ body: Data) async -> Outcome {
		guard let message = try? JSONValue(data: body) else {
			return .reply(Self.error(id: .null, code: ErrorCode.parseError, message: "Parse error"), status: 400)
		}
		if case .array = message {
			return .reply(
				Self.error(id: .null, code: ErrorCode.invalidRequest, message: "Batch requests are not supported"),
				status: 400
			)
		}
		guard case .object(let object) = message else {
			return invalidRequest(id: .null, "Message must be a JSON object")
		}

		let id = object["id"]
		let echoID: JSONValue = switch id {
		case .string, .number: id ?? .null
		default: .null
		}
		guard object["jsonrpc"] == "2.0" else {
			return invalidRequest(id: echoID, "jsonrpc must be \"2.0\"")
		}
		guard let methodValue = object["method"] else {
			if object["result"] != nil || object["error"] != nil {
				// A response to a server-initiated request. This server never sends any, so just accept it.
				return .accepted
			}
			return invalidRequest(id: echoID, "Missing method")
		}
		guard let method = methodValue.stringValue else {
			return invalidRequest(id: echoID, "method must be a string")
		}
		guard let id else {
			MCPLog.logger.debug("Notification \(method, privacy: .public)")
			return .accepted
		}
		switch id {
		case .string, .number:
			break
		default:
			return invalidRequest(id: .null, "id must be a string or a number")
		}

		let params: [String: JSONValue]
		switch object["params"] {
		case nil, .null:
			params = [:]
		case .object(let value):
			params = value
		default:
			return .reply(Self.error(id: id, code: ErrorCode.invalidParams, message: "params must be an object"), status: 200)
		}

		switch await result(method: method, params: params) {
		case .success(let result):
			return .reply(["jsonrpc": "2.0", "id": id, "result": result], status: 200)
		case .failure(let failure):
			return .reply(Self.error(id: id, code: failure.code, message: failure.message), status: 200)
		}
	}

	// MARK: Methods

	private struct Failure: Error {
		var code: Int
		var message: String
	}

	private func result(method: String, params: [String: JSONValue]) async -> Result<JSONValue, Failure> {
		switch method {
		case "initialize":
			return .success(initializeResult(params: params))
		case "ping":
			return .success([:])
		case "tools/list":
			return .success(["tools": .array(tools.map(\.listing))])
		case "tools/call":
			return await callTool(params: params)
		default:
			MCPLog.logger.notice("Unknown method \(method, privacy: .public)")
			return .failure(Failure(code: ErrorCode.methodNotFound, message: "Method not found: \(method)"))
		}
	}

	private func initializeResult(params: [String: JSONValue]) -> JSONValue {
		let requested = params["protocolVersion"]?.stringValue
		let negotiated = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
			?? Self.supportedProtocolVersions[0]
		let client = params["clientInfo"]?["name"]?.stringValue ?? "unknown"
		MCPLog.logger.info("Client \(client, privacy: .public) initialized with protocol \(negotiated, privacy: .public)")
		var result: [String: JSONValue] = [
			"protocolVersion": .string(negotiated),
			"capabilities": ["tools": ["listChanged": false]],
			"serverInfo": ["name": .string(name), "version": .string(version)],
		]
		if !instructions.isEmpty {
			result["instructions"] = .string(instructions)
		}
		return .object(result)
	}

	private func callTool(params: [String: JSONValue]) async -> Result<JSONValue, Failure> {
		guard let toolName = params["name"]?.stringValue else {
			return .failure(Failure(code: ErrorCode.invalidParams, message: "Missing tool name"))
		}
		guard let tool = toolsByName[toolName] else {
			return .failure(Failure(code: ErrorCode.invalidParams, message: "Unknown tool: \(toolName)"))
		}
		let arguments: JSONValue
		switch params["arguments"] {
		case nil, .null:
			arguments = [:]
		case .object(let value):
			arguments = .object(value)
		default:
			return .failure(Failure(code: ErrorCode.invalidParams, message: "arguments must be an object"))
		}

		let clock = ContinuousClock()
		let start = clock.now
		let result: MCPToolResult
		do {
			result = try await tool.handler(arguments)
		} catch {
			MCPLog.logger.error("Tool \(toolName, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
			result = .error(error.localizedDescription)
		}
		let elapsed = clock.now - start
		MCPLog.logger.info("Tool \(toolName, privacy: .public) finished in \(elapsed.description, privacy: .public) (error: \(result.isError))")
		return .success(result.jsonValue)
	}

	// MARK: Errors

	private func invalidRequest(id: JSONValue, _ message: String) -> Outcome {
		.reply(Self.error(id: id, code: ErrorCode.invalidRequest, message: message), status: 400)
	}

	static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
		["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
	}
}
