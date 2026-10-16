import Foundation
import Testing
@testable import NebulaMCP

@Suite("HTTP parsing and routing")
struct HTTPRequestParserTests {
	private func parse(_ text: String) -> HTTPRequestParser.Outcome {
		HTTPRequestParser.parse(Data(text.utf8))
	}

	private func rejectionStatus(_ outcome: HTTPRequestParser.Outcome) -> Int? {
		if case .rejected(let response) = outcome { return response.status }
		return nil
	}

	@Test func parsesRequestWithBody() throws {
		let outcome = parse("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nCONTENT-length: 4\r\nX-A: 1\r\nx-a: 2\r\n\r\nabcd")
		guard case .complete(let request) = outcome else {
			Issue.record("Expected a complete request")
			return
		}
		#expect(request.method == "POST")
		#expect(request.path == "/mcp")
		#expect(request.header("Host") == "127.0.0.1:1")
		#expect(request.header("x-a") == "1, 2")
		#expect(request.body == Data("abcd".utf8))
	}

	@Test func waitsForMoreBytes() {
		#expect({ if case .incomplete = parse("POST /mcp HTTP/1.1\r\nHost: a") { return true } else { return false } }())
		#expect({ if case .incomplete = parse("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") { return true } else { return false } }())
	}

	@Test func rejectsBadInput() {
		#expect(rejectionStatus(parse("POST /mcp HTTP/1.1\r\nContent-Length: 5000000\r\n\r\n")) == 413)
		#expect(rejectionStatus(parse("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) == 400)
		#expect(rejectionStatus(parse("POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n")) == 400)
		#expect(rejectionStatus(parse("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == 501)
		#expect(rejectionStatus(parse("NONSENSE\r\n\r\n")) == 400)
		#expect(rejectionStatus(parse("GET / HTTP/2\r\n\r\n")) == 505)
		#expect(rejectionStatus(parse("GET / HTTP/1.1\r\nno colon\r\n\r\n")) == 400)
		#expect(rejectionStatus(parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 40_000))) == 431)
	}

	@Test func routerRejectsForeignHostAndOrigin() async {
		let router = MCPRequestRouter(dispatcher: MCPDispatcher(name: "t", version: "1", instructions: "", tools: []))
		let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
		func request(_ headers: [String: String]) -> HTTPRequest {
			HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body)
		}
		#expect(await router.response(for: request(["host": "127.0.0.1:9"]), port: 9).status == 200)
		#expect(await router.response(for: request(["host": "LOCALHOST:9"]), port: 9).status == 200)
		#expect(await router.response(for: request([:]), port: 9).status == 403)
		#expect(await router.response(for: request(["host": "evil.example:9"]), port: 9).status == 403)
		#expect(await router.response(for: request(["host": "127.0.0.1:10"]), port: 9).status == 403)
		#expect(await router.response(for: request(["host": "127.0.0.1:9", "origin": "http://localhost:9"]), port: 9).status == 200)
		#expect(await router.response(for: request(["host": "127.0.0.1:9", "origin": "null"]), port: 9).status == 403)
		#expect(await router.response(for: request(["host": "127.0.0.1:9", "content-type": "text/plain"]), port: 9).status == 415)
		#expect(await router.response(for: request(["host": "127.0.0.1:9", "mcp-protocol-version": "1999-01-01"]), port: 9).status == 400)
		#expect(await router.response(for: request(["host": "127.0.0.1:9", "mcp-protocol-version": "2025-03-26"]), port: 9).status == 200)
	}

	@Test func dispatcherHandlesMalformedMessages() async {
		let dispatcher = MCPDispatcher(name: "t", version: "1", instructions: "", tools: [])
		func code(_ json: String) async -> Double? {
			guard case .reply(let reply, _) = await dispatcher.handle(Data(json.utf8)) else { return nil }
			return reply["error"]?["code"]?.doubleValue
		}
		#expect(await code("{nope") == -32700)
		#expect(await code("[]") == -32600)
		#expect(await code("42") == -32600)
		#expect(await code(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#) == -32600)
		#expect(await code(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == -32600)
		#expect(await code(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#) == -32601)
		#expect(await code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#) == -32602)
		#expect(await dispatcher.handle(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == .accepted)
	}
}
