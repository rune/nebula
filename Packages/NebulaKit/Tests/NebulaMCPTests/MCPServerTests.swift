import Foundation
import Testing
@testable import NebulaMCP

/// End-to-end tests over real loopback HTTP.
@Suite("MCPServer end to end")
struct MCPServerTests {
	private struct Reply {
		var status: Int
		var headers: [String: String]
		var body: Data

		var json: JSONValue? {
			try? JSONValue(data: body)
		}
	}

	private static let tools: [MCPTool] = [
		MCPTool(
			name: "echo",
			title: "Echo",
			description: "Returns the message.",
			inputSchema: JSONSchema.object(["message": JSONSchema.string("Text to echo")], required: ["message"]),
			readOnly: true
		) { arguments in
			.text(arguments["message"]?.stringValue ?? "<none>")
		},
		MCPTool(name: "fail", title: "Fail", description: "Always throws.", destructive: true) { _ in
			throw MCPToolError("Something broke")
		},
		MCPTool(name: "picture", title: "Picture", description: "Returns an image and JSON.") { _ in
			var result = MCPToolResult.image(Data([1, 2, 3]), mimeType: "image/png")
			result.content += MCPToolResult.json(["b": 2, "a": 1]).content
			return result
		},
		MCPTool(name: "slow", title: "Slow", description: "Sleeps for two seconds.") { _ in
			try await Task.sleep(for: .seconds(2))
			return .text("done")
		},
	]

	private static func makeServer() throws -> MCPServer {
		let server = MCPServer(name: "Test", version: "9.9", instructions: "Be nice.", tools: tools)
		try server.start(port: 0)
		return server
	}

	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 10
		return URLSession(configuration: configuration)
	}()

	private func send(
		port: UInt16,
		method: String = "POST",
		path: String = "/mcp",
		body: Data? = nil,
		headers: [String: String] = [:]
	) async throws -> Reply {
		let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.httpBody = body
		request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
		if body != nil {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		for (name, value) in headers {
			request.setValue(value, forHTTPHeaderField: name)
		}
		let (data, response) = try await Self.session.data(for: request)
		let http = try #require(response as? HTTPURLResponse)
		var replyHeaders: [String: String] = [:]
		for (name, value) in http.allHeaderFields {
			if let name = name as? String, let value = value as? String {
				replyHeaders[name.lowercased()] = value
			}
		}
		return Reply(status: http.statusCode, headers: replyHeaders, body: data)
	}

	private func rpc(port: UInt16, id: Int = 1, method: String, params: JSONValue? = nil, headers: [String: String] = [:]) async throws -> Reply {
		var message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
		if let params {
			message["params"] = params
		}
		return try await send(port: port, body: try message.jsonData(), headers: headers)
	}

	@Test func startAndStop() throws {
		let server = try Self.makeServer()
		#expect(server.isRunning)
		#expect(server.port >= 1024)
		#expect(server.endpointURL?.absoluteString == "http://127.0.0.1:\(server.port)/mcp")
		#expect(throws: MCPServerError.alreadyRunning) { try server.start(port: 0) }
		server.stop()
		#expect(!server.isRunning)
		server.stop()
	}

	@Test func portInUseThrows() throws {
		let first = try Self.makeServer()
		defer { first.stop() }
		let second = MCPServer(name: "Other", version: "1", instructions: "", tools: [])
		#expect(throws: MCPServerError.self) { try second.start(port: first.port) }
		#expect(!second.isRunning)
	}

	@Test func restartsOnSamePortAfterTraffic() async throws {
		let server = try Self.makeServer()
		let port = server.port
		_ = try await rpc(port: port, method: "ping")
		server.stop()
		try server.start(port: port)
		defer { server.stop() }
		#expect(server.port == port)
		let reply = try await rpc(port: port, method: "ping")
		#expect(reply.status == 200)
	}

	@Test func initialize() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let params: JSONValue = [
			"protocolVersion": "2025-03-26",
			"capabilities": [:],
			"clientInfo": ["name": "tests", "version": "1"],
		]
		let reply = try await rpc(port: server.port, id: 7, method: "initialize", params: params)
		#expect(reply.status == 200)
		#expect(reply.headers["content-type"] == "application/json")
		#expect(reply.headers["content-length"] == String(reply.body.count))
		let json = try #require(reply.json)
		#expect(json["jsonrpc"] == "2.0")
		#expect(json["id"] == 7)
		let result = try #require(json["result"])
		#expect(result["protocolVersion"] == "2025-03-26")
		#expect(result["capabilities"] == ["tools": ["listChanged": false]])
		#expect(result["serverInfo"] == ["name": "Test", "version": "9.9"])
		#expect(result["instructions"] == "Be nice.")

		let fallback = try await rpc(port: server.port, method: "initialize", params: ["protocolVersion": "2099-01-01"])
		#expect(fallback.json?["result"]?["protocolVersion"] == "2025-06-18")
	}

	@Test func stringIDsAndPing() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let body = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
		let reply = try await send(port: server.port, body: body)
		#expect(reply.json == ["jsonrpc": "2.0", "id": "abc", "result": [:]])
	}

	@Test func notificationIsAccepted() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
		let reply = try await send(port: server.port, body: body)
		#expect(reply.status == 202)
		#expect(reply.body.isEmpty)
	}

	@Test func listTools() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let reply = try await rpc(port: server.port, method: "tools/list")
		let tools = try #require(reply.json?["result"]?["tools"]?.arrayValue)
		#expect(tools.compactMap { $0["name"]?.stringValue } == ["echo", "fail", "picture", "slow"])
		let echo = tools[0]
		#expect(echo["title"] == "Echo")
		#expect(echo["description"] == "Returns the message.")
		#expect(echo["inputSchema"]?["required"] == ["message"])
		#expect(echo["annotations"]?["readOnlyHint"] == true)
		#expect(echo["annotations"]?["destructiveHint"] == false)
		#expect(tools[1]["annotations"]?["destructiveHint"] == true)
	}

	@Test func callToolSuccess() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let reply = try await rpc(port: server.port, method: "tools/call", params: ["name": "echo", "arguments": ["message": "hi"]])
		#expect(reply.status == 200)
		#expect(reply.json?["result"] == ["content": [["type": "text", "text": "hi"]], "isError": false])

		let noArguments = try await rpc(port: server.port, method: "tools/call", params: ["name": "echo"])
		#expect(noArguments.json?["result"]?["content"]?[0]?["text"] == "<none>")
	}

	@Test func callToolWithImageAndJSON() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let reply = try await rpc(port: server.port, method: "tools/call", params: ["name": "picture", "arguments": [:]])
		let content = try #require(reply.json?["result"]?["content"]?.arrayValue)
		#expect(content.count == 2)
		#expect(content[0] == ["type": "image", "data": .string(Data([1, 2, 3]).base64EncodedString()), "mimeType": "image/png"])
		#expect(content[1]["text"] == "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
	}

	@Test func callToolHandlerError() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let reply = try await rpc(port: server.port, method: "tools/call", params: ["name": "fail", "arguments": [:]])
		#expect(reply.status == 200)
		let json = try #require(reply.json)
		#expect(json["error"] == nil)
		#expect(json["result"] == ["content": [["type": "text", "text": "Something broke"]], "isError": true])
	}

	@Test func unknownToolAndMethod() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let tool = try await rpc(port: server.port, method: "tools/call", params: ["name": "missing"])
		#expect(tool.json?["error"]?["code"] == -32602)
		#expect(tool.json?["result"] == nil)
		let method = try await rpc(port: server.port, method: "resources/list")
		#expect(method.json?["error"]?["code"] == -32601)
	}

	@Test func parseErrorOverHTTP() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let reply = try await send(port: server.port, body: Data("{not json".utf8))
		#expect(reply.status == 400)
		#expect(reply.json?["error"]?["code"] == -32700)
		#expect(reply.json?["id"] == .null)
	}

	@Test func wrongOriginIsForbidden() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let reply = try await rpc(port: server.port, method: "ping", headers: ["Origin": "https://evil.example"])
		#expect(reply.status == 403)
		let allowed = try await rpc(port: server.port, method: "ping", headers: ["Origin": "http://127.0.0.1:\(server.port)"])
		#expect(allowed.status == 200)
	}

	@Test func wrongMethodAndPath() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let get = try await send(port: server.port, method: "GET")
		#expect(get.status == 405)
		#expect(get.headers["allow"] == "POST")
		let delete = try await send(port: server.port, method: "DELETE")
		#expect(delete.status == 405)
		let other = try await send(port: server.port, path: "/other", body: Data("{}".utf8))
		#expect(other.status == 404)
	}

	@Test func slowToolDoesNotBlockOtherRequests() async throws {
		let server = try Self.makeServer()
		defer { server.stop() }
		let port = server.port
		async let slow = rpc(port: port, id: 1, method: "tools/call", params: ["name": "slow"])
		try await Task.sleep(for: .milliseconds(200))
		let clock = ContinuousClock()
		let start = clock.now
		let ping = try await rpc(port: port, id: 2, method: "ping")
		#expect(ping.status == 200)
		#expect(clock.now - start < .seconds(1))
		let slowReply = try await slow
		#expect(slowReply.json?["result"]?["content"]?[0]?["text"] == "done")
	}
}
