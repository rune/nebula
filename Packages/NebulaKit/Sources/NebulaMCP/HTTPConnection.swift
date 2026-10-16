import Foundation
import Network

/// Serves exactly one request on one accepted TCP connection, then closes it.
///
/// The actor owns the read buffer. Network callbacks hop onto it with a `Task`; only one receive
/// is outstanding at a time, so bytes are appended in order. The request handler runs while the
/// actor is suspended, so a slow tool call never blocks the listener or other connections.
actor HTTPConnection {
	/// How long a client may take to send a complete request.
	static let readTimeout: Duration = .seconds(30)
	private static let readChunk = 64 * 1024

	private let connection: NWConnection
	private let queue: DispatchQueue
	private let respond: @Sendable (HTTPRequest) async -> HTTPResponse
	private let onClose: @Sendable () -> Void
	private var buffer = Data()
	private var hasRequest = false
	private var isClosed = false

	init(
		connection: NWConnection,
		queue: DispatchQueue,
		respond: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
		onClose: @escaping @Sendable () -> Void
	) {
		self.connection = connection
		self.queue = queue
		self.respond = respond
		self.onClose = onClose
	}

	func start() {
		connection.stateUpdateHandler = { [weak self] state in
			switch state {
			case .failed(let error):
				MCPLog.logger.debug("Connection failed: \(error.localizedDescription, privacy: .public)")
				Task { await self?.close() }
			case .cancelled:
				Task { await self?.close() }
			default:
				break
			}
		}
		connection.start(queue: queue)
		receiveNext()
		Task { [weak self] in
			try? await Task.sleep(for: HTTPConnection.readTimeout)
			await self?.readTimedOut()
		}
	}

	private func receiveNext() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunk) { [weak self] data, _, isComplete, error in
			Task { await self?.didReceive(data, isComplete: isComplete, failed: error != nil) }
		}
	}

	private func didReceive(_ data: Data?, isComplete: Bool, failed: Bool) async {
		guard !isClosed, !hasRequest else { return }
		if let data {
			buffer.append(data)
		}
		switch HTTPRequestParser.parse(buffer) {
		case .complete(let request):
			hasRequest = true
			buffer = Data()
			let response = await respond(request)
			send(response)
		case .rejected(let response):
			hasRequest = true
			send(response)
		case .incomplete:
			if isComplete || failed {
				close()
			} else {
				receiveNext()
			}
		}
	}

	private func readTimedOut() {
		guard !isClosed, !hasRequest else { return }
		hasRequest = true
		send(.plain(status: 408, "Request timed out."))
	}

	private func send(_ response: HTTPResponse) {
		guard !isClosed else { return }
		let connection = self.connection
		connection.send(content: response.serialized(), completion: .contentProcessed { _ in
			connection.cancel()
		})
	}

	private func close() {
		guard !isClosed else { return }
		isClosed = true
		connection.stateUpdateHandler = nil
		connection.cancel()
		onClose()
	}
}
