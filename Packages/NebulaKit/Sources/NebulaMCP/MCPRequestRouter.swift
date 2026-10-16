import Foundation

/// Applies the HTTP-level rules of the Streamable HTTP transport, then hands the body to the dispatcher.
///
/// Rules, in order:
/// 1. `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (blocks DNS rebinding), else 403.
/// 2. An `Origin`, if present, must be `http://127.0.0.1:<port>` or `http://localhost:<port>`, else 403.
/// 3. Only `/mcp` exists (404 otherwise) and only `POST` is allowed on it (405 with `Allow: POST`).
/// 4. A `Content-Type`, if present, must be JSON (415), and an `MCP-Protocol-Version`, if present,
///    must be supported (400).
struct MCPRequestRouter: Sendable {
	/// The only served path.
	static let endpointPath = "/mcp"

	let dispatcher: MCPDispatcher

	func response(for request: HTTPRequest, port: UInt16) async -> HTTPResponse {
		let allowedHosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
		guard let host = request.header("host")?.lowercased(), allowedHosts.contains(host) else {
			MCPLog.logger.notice("Rejected request with Host \(request.header("host") ?? "<none>", privacy: .public)")
			return .plain(status: 403, "Forbidden: invalid Host header.")
		}
		if let origin = request.header("origin") {
			let allowedOrigins: Set<String> = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
			guard allowedOrigins.contains(origin.lowercased()) else {
				MCPLog.logger.notice("Rejected request with Origin \(origin, privacy: .public)")
				return .plain(status: 403, "Forbidden: invalid Origin header.")
			}
		}
		guard request.path == Self.endpointPath else {
			return .plain(status: 404, "Not found. The MCP endpoint is POST \(Self.endpointPath).")
		}
		guard request.method == "POST" else {
			return .plain(status: 405, "Method not allowed. Use POST.", headers: ["Allow": "POST"])
		}
		if let contentType = request.header("content-type"), !contentType.lowercased().contains("application/json") {
			return .plain(status: 415, "Content-Type must be application/json.")
		}
		if let version = request.header("mcp-protocol-version"),
		   !MCPDispatcher.supportedProtocolVersions.contains(version) {
			return .plain(status: 400, "Unsupported MCP-Protocol-Version: \(version)")
		}

		switch await dispatcher.handle(request.body) {
		case .accepted:
			return HTTPResponse(status: 202)
		case .reply(let message, let status):
			do {
				return .json(try message.jsonData(), status: status)
			} catch {
				MCPLog.logger.error("Could not encode response: \(error.localizedDescription, privacy: .public)")
				return .plain(status: 500, "Could not encode the response.")
			}
		}
	}
}
