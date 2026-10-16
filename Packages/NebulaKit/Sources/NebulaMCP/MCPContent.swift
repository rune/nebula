import Foundation

/// One content block in a tool result.
public enum MCPContent: Sendable, Hashable {
	/// Plain text.
	case text(String)
	/// An image, sent base64-encoded with its MIME type (for example `image/png`).
	case image(data: Data, mimeType: String)

	/// The MCP wire representation of this block.
	var jsonValue: JSONValue {
		switch self {
		case .text(let text):
			["type": "text", "text": .string(text)]
		case .image(let data, let mimeType):
			["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
		}
	}
}
