import Foundation

/// A dynamically typed JSON value.
///
/// Used for JSON-RPC payloads, tool arguments and JSON Schema documents. Numbers are stored as
/// `Double`; integral values are encoded without a fractional part (`1`, not `1.0`).
public enum JSONValue: Codable, Sendable, Hashable {
	/// JSON `null`.
	case null
	/// A JSON boolean.
	case bool(Bool)
	/// A JSON number.
	case number(Double)
	/// A JSON string.
	case string(String)
	/// A JSON array.
	case array([JSONValue])
	/// A JSON object.
	case object([String: JSONValue])

	// MARK: Codable

	/// Decodes any JSON value.
	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else if let value = try? container.decode([String: JSONValue].self) {
			self = .object(value)
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
		}
	}

	/// Encodes the value. Integral numbers that fit in `Int64` are written as integers.
	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null:
			try container.encodeNil()
		case .bool(let value):
			try container.encode(value)
		case .number(let value):
			if let integer = JSONValue.exactInteger(value) {
				try container.encode(integer)
			} else {
				try container.encode(value)
			}
		case .string(let value):
			try container.encode(value)
		case .array(let value):
			try container.encode(value)
		case .object(let value):
			try container.encode(value)
		}
	}

	private static func exactInteger(_ value: Double) -> Int64? {
		guard value.isFinite, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
		return Int64(value)
	}

	// MARK: Bridging

	/// Creates a JSON value from any `Encodable` value by round-tripping it through `JSONEncoder`.
	public init(encoding value: some Encodable) throws {
		let data = try JSONEncoder().encode(value)
		self = try JSONDecoder().decode(JSONValue.self, from: data)
	}

	/// Decodes this JSON value into a `Decodable` type.
	public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
		let data = try JSONEncoder().encode(self)
		return try JSONDecoder().decode(type, from: data)
	}

	/// Parses JSON data into a value.
	public init(data: Data) throws {
		self = try JSONDecoder().decode(JSONValue.self, from: data)
	}

	/// Serialises the value as JSON data with sorted keys.
	public func jsonData(pretty: Bool = false) throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}

	// MARK: Accessors

	/// The member named `key` when this is an object, otherwise `nil`.
	public subscript(key: String) -> JSONValue? {
		get {
			if case .object(let object) = self { return object[key] }
			return nil
		}
		set {
			guard case .object(var object) = self else { return }
			object[key] = newValue
			self = .object(object)
		}
	}

	/// The element at `index` when this is an array and the index is in range, otherwise `nil`.
	public subscript(index: Int) -> JSONValue? {
		guard case .array(let array) = self, array.indices.contains(index) else { return nil }
		return array[index]
	}

	/// The string payload, if this is a string.
	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	/// The numeric payload, if this is a number.
	public var doubleValue: Double? {
		if case .number(let value) = self { return value }
		return nil
	}

	/// The numeric payload as an `Int`, if this is a number with no fractional part.
	public var intValue: Int? {
		guard case .number(let value) = self, let integer = JSONValue.exactInteger(value) else { return nil }
		return Int(exactly: integer)
	}

	/// The boolean payload, if this is a boolean.
	public var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	/// The elements, if this is an array.
	public var arrayValue: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}

	/// The members, if this is an object.
	public var objectValue: [String: JSONValue]? {
		if case .object(let value) = self { return value }
		return nil
	}

	/// Whether this is `null`.
	public var isNull: Bool {
		if case .null = self { return true }
		return false
	}
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
	/// Creates `null`.
	public init(nilLiteral: ()) {
		self = .null
	}
}

extension JSONValue: ExpressibleByBooleanLiteral {
	/// Creates a boolean.
	public init(booleanLiteral value: Bool) {
		self = .bool(value)
	}
}

extension JSONValue: ExpressibleByIntegerLiteral {
	/// Creates a number from an integer literal.
	public init(integerLiteral value: Int) {
		self = .number(Double(value))
	}
}

extension JSONValue: ExpressibleByFloatLiteral {
	/// Creates a number from a floating-point literal.
	public init(floatLiteral value: Double) {
		self = .number(value)
	}
}

extension JSONValue: ExpressibleByStringLiteral {
	/// Creates a string.
	public init(stringLiteral value: String) {
		self = .string(value)
	}
}

extension JSONValue: ExpressibleByArrayLiteral {
	/// Creates an array.
	public init(arrayLiteral elements: JSONValue...) {
		self = .array(elements)
	}
}

extension JSONValue: ExpressibleByDictionaryLiteral {
	/// Creates an object. Later duplicate keys win.
	public init(dictionaryLiteral elements: (String, JSONValue)...) {
		self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
	}
}
