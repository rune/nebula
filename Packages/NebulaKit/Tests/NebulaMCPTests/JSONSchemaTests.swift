import Foundation
import Testing
@testable import NebulaMCP

@Suite("JSONSchema")
struct JSONSchemaTests {
	@Test func objectSchema() {
		let schema = JSONSchema.object(
			[
				"time": JSONSchema.number("Seconds", minimum: 0, maximum: 60),
				"count": JSONSchema.integer(minimum: 1),
				"mode": JSONSchema.string("Mode", enum: ["fast", "slow"]),
				"loop": JSONSchema.boolean(),
				"ids": JSONSchema.array(of: JSONSchema.string(), description: "Item ids"),
			],
			required: ["time"],
			description: "Arguments"
		)
		#expect(schema["type"] == "object")
		#expect(schema["required"] == ["time"])
		#expect(schema["description"] == "Arguments")
		#expect(schema["additionalProperties"] == nil)
		#expect(schema["properties"]?["time"] == ["type": "number", "description": "Seconds", "minimum": 0, "maximum": 60])
		#expect(schema["properties"]?["count"] == ["type": "integer", "minimum": 1])
		#expect(schema["properties"]?["mode"] == ["type": "string", "description": "Mode", "enum": ["fast", "slow"]])
		#expect(schema["properties"]?["loop"] == ["type": "boolean"])
		#expect(schema["properties"]?["ids"] == ["type": "array", "items": ["type": "string"], "description": "Item ids"])
	}

	@Test func emptyObjectOmitsRequired() {
		let schema = JSONSchema.object([:], additionalProperties: false)
		#expect(schema == ["type": "object", "properties": [:], "additionalProperties": false])
	}
}
