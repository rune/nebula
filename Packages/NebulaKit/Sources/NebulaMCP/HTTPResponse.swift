import Foundation

/// An HTTP/1.1 response. The connection is always closed after it is sent.
struct HTTPResponse: Sendable, Hashable {
	/// The status code.
	var status: Int
	/// Extra header fields. `Content-Length` and `Connection` are added on serialisation.
	var headers: [String: String]
	/// The response body.
	var body: Data

	init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
		self.status = status
		self.headers = headers
		self.body = body
	}

	/// A JSON response.
	static func json(_ body: Data, status: Int = 200) -> HTTPResponse {
		HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
	}

	/// A plain-text response.
	static func plain(status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
		var allHeaders = headers
		allHeaders["Content-Type"] = "text/plain; charset=utf-8"
		return HTTPResponse(status: status, headers: allHeaders, body: Data((message + "\n").utf8))
	}

	/// The bytes to write to the socket.
	func serialized() -> Data {
		var head = "HTTP/1.1 \(status) \(HTTPResponse.reasonPhrase(for: status))\r\n"
		for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
			head += "\(name): \(value)\r\n"
		}
		head += "Content-Length: \(body.count)\r\n"
		head += "Cache-Control: no-store\r\n"
		head += "Connection: close\r\n\r\n"
		var data = Data(head.utf8)
		data.append(body)
		return data
	}

	static func reasonPhrase(for status: Int) -> String {
		switch status {
		case 200: "OK"
		case 202: "Accepted"
		case 400: "Bad Request"
		case 403: "Forbidden"
		case 404: "Not Found"
		case 405: "Method Not Allowed"
		case 408: "Request Timeout"
		case 413: "Content Too Large"
		case 415: "Unsupported Media Type"
		case 431: "Request Header Fields Too Large"
		case 500: "Internal Server Error"
		case 501: "Not Implemented"
		case 503: "Service Unavailable"
		case 505: "HTTP Version Not Supported"
		default: "Status \(status)"
		}
	}
}
