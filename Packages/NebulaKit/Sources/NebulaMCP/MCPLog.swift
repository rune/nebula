import os

/// The logger shared by the MCP module.
enum MCPLog {
	static let logger = Logger(subsystem: "app.nebula", category: "mcp")
}
