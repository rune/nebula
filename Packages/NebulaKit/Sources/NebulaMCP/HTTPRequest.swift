import Foundation

/// A parsed HTTP/1.1 request.
struct HTTPRequest: Sendable, Hashable {
	/// The request method, as sent (for example `POST`).
	var method: String
	/// The path part of the request target, without the query string.
	var path: String
	/// Header fields keyed by lowercased name. Repeated fields are joined with `", "`.
	var headers: [String: String]
	/// The request body.
	var body: Data

	/// The value of a header field, looked up case-insensitively.
	func header(_ name: String) -> String? {
		headers[name.lowercased()]
	}
}

/// Incremental parser for HTTP/1.1 requests with `Content-Length` bodies.
enum HTTPRequestParser {
	/// Largest accepted request head (request line plus headers).
	static let maxHeadBytes = 32 * 1024
	/// Largest accepted body.
	static let maxBodyBytes = 4 * 1024 * 1024

	/// The result of feeding the bytes received so far to the parser.
	enum Outcome: Sendable {
		/// More bytes are needed.
		case incomplete
		/// A full request was parsed.
		case complete(HTTPRequest)
		/// The request is malformed or too large; send this response and close.
		case rejected(HTTPResponse)
	}

	private static let headTerminator = Data("\r\n\r\n".utf8)

	/// Parses the first request in `buffer`.
	static func parse(_ buffer: Data) -> Outcome {
		guard let terminator = buffer.range(of: headTerminator) else {
			return buffer.count > maxHeadBytes ? .rejected(.plain(status: 431, "Request header fields too large.")) : .incomplete
		}
		let headLength = buffer.distance(from: buffer.startIndex, to: terminator.lowerBound)
		guard headLength <= maxHeadBytes else {
			return .rejected(.plain(status: 431, "Request header fields too large."))
		}
		guard let head = String(data: buffer[buffer.startIndex..<terminator.lowerBound], encoding: .isoLatin1) else {
			return .rejected(.plain(status: 400, "Malformed request head."))
		}

		var lines = head.components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
		guard requestLine.count == 3, !requestLine[0].isEmpty, !requestLine[1].isEmpty else {
			return .rejected(.plain(status: 400, "Malformed request line."))
		}
		guard requestLine[2].hasPrefix("HTTP/1.") else {
			return .rejected(.plain(status: 505, "Only HTTP/1.x is supported."))
		}
		let method = String(requestLine[0])
		let target = requestLine[1]
		let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? target)

		var headers: [String: String] = [:]
		var contentLengths: Set<String> = []
		for line in lines {
			guard let colon = line.firstIndex(of: ":"), let first = line.first, first != " ", first != "\t" else {
				return .rejected(.plain(status: 400, "Malformed header field."))
			}
			let name = line[..<colon].lowercased()
			guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
				return .rejected(.plain(status: 400, "Malformed header field."))
			}
			let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			if name == "content-length" {
				contentLengths.insert(value)
			}
			if let existing = headers[name] {
				headers[name] = existing + ", " + value
			} else {
				headers[name] = value
			}
		}

		guard headers["transfer-encoding"] == nil else {
			return .rejected(.plain(status: 501, "Transfer-Encoding is not supported; send Content-Length."))
		}
		var bodyLength = 0
		if !contentLengths.isEmpty {
			guard contentLengths.count == 1, let value = contentLengths.first, let length = Int(value), length >= 0 else {
				return .rejected(.plain(status: 400, "Invalid Content-Length."))
			}
			guard length <= maxBodyBytes else {
				return .rejected(.plain(status: 413, "Request body exceeds 4 MB."))
			}
			bodyLength = length
		}

		let bodyStart = terminator.upperBound
		guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= bodyLength else {
			return .incomplete
		}
		let bodyEnd = buffer.index(bodyStart, offsetBy: bodyLength)
		let body = Data(buffer[bodyStart..<bodyEnd])
		return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
	}
}
