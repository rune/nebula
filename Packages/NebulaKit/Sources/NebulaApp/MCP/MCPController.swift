import Foundation
import NebulaMCP
import Observation
import os

/// Runs Nebula's MCP server according to settings and exposes its status to the UI.
@MainActor
@Observable
public final class MCPController {
	public private(set) var isRunning = false
	public private(set) var error: String?
	public private(set) var callCount = 0
	public private(set) var lastCall: String?
	@ObservationIgnored weak var app: AppModel?
	@ObservationIgnored private var server: MCPServer?
	private static let logger = Logger(subsystem: "app.nebula", category: "mcp")

	public var url: String { "http://127.0.0.1:\(app?.settings.mcpPort ?? 39351)/mcp" }

	public var setupCommand: String {
		"claude mcp add --transport http --scope user nebula \(url)"
	}

	public func applySettings() {
		guard let app else { return }
		stop()
		guard app.settings.mcpEnabled else { return }
		let server = MCPServer(name: "nebula", version: "1.0.0", instructions: MCPTools.instructions, tools: MCPTools.all(controller: self))
		do {
			try server.start(port: UInt16(clamping: app.settings.mcpPort))
			self.server = server
			isRunning = true
			error = nil
		} catch {
			self.error = error.localizedDescription
			isRunning = false
			Self.logger.error("MCP server failed to start: \(error.localizedDescription, privacy: .public)")
		}
	}

	public func stop() {
		server?.stop()
		server = nil
		isRunning = false
	}

	func record(_ tool: String) {
		callCount += 1
		lastCall = tool
	}
}
