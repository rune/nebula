import Foundation
import Network
import os

/// A Model Context Protocol server using the Streamable HTTP transport in stateless JSON mode.
///
/// The server listens on `127.0.0.1` only and serves `POST /mcp`. Each POST carries one JSON-RPC
/// message and gets one plain JSON response (no event streams, no sessions).
///
/// All methods are thread-safe and may be called from any thread or actor, including the main
/// actor. ``start(port:)`` and ``stop()`` block briefly (normally a few milliseconds) until the
/// socket is bound or released, so binding errors are thrown and a restart on the same port works.
///
/// Tool handlers run concurrently on background tasks, one per HTTP request.
public final class MCPServer: Sendable {
	/// The name reported in `serverInfo`.
	public let name: String
	/// The version reported in `serverInfo`.
	public let version: String
	/// The instructions returned from `initialize`.
	public let instructions: String
	/// The tools offered to clients, in listing order.
	public let tools: [MCPTool]

	/// Most connections served at once; further connections are refused.
	static let maxConnections = 32
	private static let startTimeout: DispatchTimeInterval = .seconds(5)
	private static let stopTimeout: DispatchTimeInterval = .seconds(2)

	private enum StartOutcome: Sendable {
		case ready(UInt16)
		case failed(String)
	}

	private struct ConnectionEntry: Sendable {
		var connection: NWConnection
		var handler: HTTPConnection
	}

	private struct State: Sendable {
		var listener: NWListener?
		var cancelled: OneShotSignal<Bool>?
		var isReady = false
		var requestedPort: UInt16 = 0
		var boundPort: UInt16 = 0
		var connections: [ObjectIdentifier: ConnectionEntry] = [:]
	}

	private let router: MCPRequestRouter
	private let queue = DispatchQueue(label: "app.nebula.mcp.network")
	private let state = OSAllocatedUnfairLock(initialState: State())

	/// Creates a server. Nothing is opened until ``start(port:)``.
	///
	/// - Parameters:
	///   - name: Reported to clients as `serverInfo.name`.
	///   - version: Reported to clients as `serverInfo.version`.
	///   - instructions: Usage notes for the model, returned from `initialize`. Omitted when empty.
	///   - tools: The tools to offer. Names must be unique; on duplicates the first wins.
	public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
		self.name = name
		self.version = version
		self.instructions = instructions
		self.tools = tools
		self.router = MCPRequestRouter(
			dispatcher: MCPDispatcher(name: name, version: version, instructions: instructions, tools: tools)
		)
	}

	deinit {
		shutDown(waitForRelease: false)
	}

	/// Whether the server is listening.
	public var isRunning: Bool {
		state.withLock { $0.listener != nil && $0.isReady }
	}

	/// The port the server listens on while running; otherwise the port last passed to ``start(port:)``.
	///
	/// When started with port `0`, this is the port the system picked.
	public var port: UInt16 {
		state.withLock { $0.isReady ? $0.boundPort : $0.requestedPort }
	}

	/// The endpoint URL clients connect to, for example `http://127.0.0.1:39351/mcp`.
	public var endpointURL: URL? {
		URL(string: "http://127.0.0.1:\(port)\(MCPRequestRouter.endpointPath)")
	}

	/// Starts listening on `127.0.0.1:<port>`. Pass `0` to let the system pick a free port.
	///
	/// Blocks until the socket is bound or binding fails.
	///
	/// - Throws: ``MCPServerError``.
	public func start(port: UInt16) throws {
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
		parameters.requiredInterfaceType = .loopback
		parameters.includePeerToPeer = false

		let listener: NWListener
		do {
			listener = try NWListener(using: parameters)
		} catch {
			throw MCPServerError.bindFailed(port: port, reason: error.localizedDescription)
		}
		let startup = OneShotSignal<StartOutcome>()
		let cancelled = OneShotSignal<Bool>()
		try state.withLock { state in
			guard state.listener == nil else { throw MCPServerError.alreadyRunning }
			state = State(listener: listener, cancelled: cancelled, requestedPort: port)
		}

		listener.stateUpdateHandler = { [weak self] newState in
			switch newState {
			case .ready:
				let boundPort = listener.port?.rawValue ?? 0
				self?.state.withLock { state in
					guard state.listener === listener else { return }
					state.isReady = true
					state.boundPort = boundPort
				}
				startup.resolve(.ready(boundPort))
			case .waiting(let error), .failed(let error):
				MCPLog.logger.error("MCP listener error: \(error.localizedDescription, privacy: .public)")
				if !startup.resolve(.failed(error.localizedDescription)) {
					// Failed after startup: shut down so `isRunning` reports the truth.
					self?.shutDown(listener: listener)
				}
			case .cancelled:
				startup.resolve(.failed("The listener was cancelled."))
				cancelled.resolve(true)
			default:
				break
			}
		}
		listener.newConnectionHandler = { [weak self] connection in
			self?.accept(connection)
		}
		listener.start(queue: queue)

		switch startup.wait(timeout: Self.startTimeout) {
		case .ready(let boundPort):
			MCPLog.logger.info("MCP server listening on 127.0.0.1:\(boundPort)")
		case .failed(let reason):
			shutDown(waitForRelease: true)
			throw MCPServerError.bindFailed(port: port, reason: reason)
		case nil:
			shutDown(waitForRelease: true)
			throw MCPServerError.timedOut(port: port)
		}
	}

	/// Stops listening and closes open connections. Safe to call when not running.
	///
	/// Blocks until the listening socket is released. Tool handlers already running are not
	/// cancelled; their responses are dropped.
	public func stop() {
		shutDown(waitForRelease: true)
	}

	// MARK: Internals

	/// Shuts down only if `listener` is still the current one (used from listener callbacks).
	private func shutDown(listener: NWListener) {
		let isCurrent = state.withLock { $0.listener === listener }
		if isCurrent {
			shutDown(waitForRelease: false)
		}
	}

	/// Tears down the listener and connections. Waiting must not happen on `queue`.
	private func shutDown(waitForRelease: Bool) {
		let (listener, cancelled, connections) = state.withLock { state in
			let taken = (state.listener, state.cancelled, Array(state.connections.values))
			state = State(requestedPort: state.requestedPort)
			return taken
		}
		guard let listener else { return }
		listener.newConnectionHandler = nil
		listener.cancel()
		for entry in connections {
			entry.connection.cancel()
		}
		if waitForRelease, cancelled?.wait(timeout: Self.stopTimeout) == nil {
			MCPLog.logger.notice("MCP listener did not report cancellation in time")
		}
		MCPLog.logger.info("MCP server stopped")
	}

	private func accept(_ connection: NWConnection) {
		let id = ObjectIdentifier(connection)
		let port = self.port
		let handler = HTTPConnection(
			connection: connection,
			queue: queue,
			respond: { [router] request in
				await router.response(for: request, port: port)
			},
			onClose: { [weak self] in
				self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
			}
		)
		let accepted = state.withLock { state in
			guard state.isReady, state.connections.count < Self.maxConnections else { return false }
			state.connections[id] = ConnectionEntry(connection: connection, handler: handler)
			return true
		}
		guard accepted else {
			MCPLog.logger.notice("Refused a connection: server stopped or too many open connections")
			connection.cancel()
			return
		}
		Task {
			await handler.start()
		}
	}
}
