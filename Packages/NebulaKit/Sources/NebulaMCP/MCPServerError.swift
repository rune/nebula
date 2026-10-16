import Foundation

/// Errors thrown by ``MCPServer/start(port:)``.
public enum MCPServerError: LocalizedError, Sendable, Hashable {
	/// The server is already listening. Call ``MCPServer/stop()`` first.
	case alreadyRunning
	/// The listener could not be created or bound (for example, the port is in use).
	case bindFailed(port: UInt16, reason: String)
	/// The listener did not become ready in time.
	case timedOut(port: UInt16)

	/// A readable description of the error.
	public var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			"The MCP server is already running."
		case .bindFailed(let port, let reason):
			"The MCP server could not listen on 127.0.0.1:\(port): \(reason)"
		case .timedOut(let port):
			"The MCP server did not start listening on 127.0.0.1:\(port) in time."
		}
	}
}
