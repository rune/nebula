import Foundation

/// Builders for the JSON Schema documents used as tool input schemas.
///
/// Each builder returns a plain ``JSONValue`` so schemas can be nested freely:
///
/// ```swift
/// JSONSchema.object([
/// 	"time": JSONSchema.number("Time in seconds", minimum: 0),
/// 	"label": JSONSchema.string("Optional label"),
/// ], required: ["time"])
/// ```
public enum JSONSchema {
	/// An object schema with the given properties.
	///
	/// - Parameters:
	///   - properties: Property name to schema.
	///   - required: Names of required properties.
	///   - description: Optional human-readable description.
	///   - additionalProperties: Whether unknown properties are allowed. `nil` leaves it unspecified.
	public static func object(
		_ properties: [String: JSONValue],
		required: [String] = [],
		description: String? = nil,
		additionalProperties: Bool? = nil
	) -> JSONValue {
		var schema: [String: JSONValue] = [
			"type": "object",
			"properties": .object(properties),
		]
		if !required.isEmpty {
			schema["required"] = .array(required.map(JSONValue.string))
		}
		if let description {
			schema["description"] = .string(description)
		}
		if let additionalProperties {
			schema["additionalProperties"] = .bool(additionalProperties)
		}
		return .object(schema)
	}

	/// A string schema, optionally restricted to a set of values.
	public static func string(_ description: String? = nil, enum values: [String]? = nil) -> JSONValue {
		var schema = base(type: "string", description: description)
		if let values {
			schema["enum"] = .array(values.map(JSONValue.string))
		}
		return .object(schema)
	}

	/// A number schema with optional inclusive bounds.
	public static func number(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
		.object(bounded(type: "number", description: description, minimum: minimum, maximum: maximum))
	}

	/// An integer schema with optional inclusive bounds.
	public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
		.object(bounded(
			type: "integer",
			description: description,
			minimum: minimum.map(Double.init),
			maximum: maximum.map(Double.init)
		))
	}

	/// A boolean schema.
	public static func boolean(_ description: String? = nil) -> JSONValue {
		.object(base(type: "boolean", description: description))
	}

	/// An array schema whose elements match `items`.
	public static func array(of items: JSONValue, description: String? = nil) -> JSONValue {
		var schema = base(type: "array", description: description)
		schema["items"] = items
		return .object(schema)
	}

	private static func base(type: String, description: String?) -> [String: JSONValue] {
		var schema: [String: JSONValue] = ["type": .string(type)]
		if let description {
			schema["description"] = .string(description)
		}
		return schema
	}

	private static func bounded(type: String, description: String?, minimum: Double?, maximum: Double?) -> [String: JSONValue] {
		var schema = base(type: type, description: description)
		if let minimum {
			schema["minimum"] = .number(minimum)
		}
		if let maximum {
			schema["maximum"] = .number(maximum)
		}
		return schema
	}
}
