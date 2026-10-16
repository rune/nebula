import Foundation

/// Short, readable identifiers for timeline items, e.g. `zoom-4k2p`. Readable so that
/// tools and logs can refer to items, random so that ids never collide after deletes.
public struct ItemID: Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
	public let rawValue: String

	public init(_ rawValue: String) { self.rawValue = rawValue }
	public init(stringLiteral value: String) { self.rawValue = value }

	public init(from decoder: Decoder) throws {
		rawValue = try decoder.singleValueContainer().decode(String.self)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	public var description: String { rawValue }

	private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

	public static func make(_ prefix: String) -> ItemID {
		var generator = SystemRandomNumberGenerator()
		let suffix = String((0..<4).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
		return ItemID("\(prefix)-\(suffix)")
	}
}

/// Who created a timeline item. Polish only replaces items it created itself.
public enum ItemSource: String, Codable, Sendable {
	case user
	case polish
	case imported
}
