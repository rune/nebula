import Foundation
import Testing
@testable import NebulaMCP

@Suite("JSONValue")
struct JSONValueTests {
	private struct Sample: Codable, Equatable {
		var name: String
		var count: Int
		var ratio: Double
		var enabled: Bool
		var tags: [String]
		var note: String?
	}

	@Test func decodesEveryKind() throws {
		let json = #"{"a":null,"b":true,"c":1,"d":1.5,"e":"x","f":[1,false],"g":{"h":"i"}}"#
		let value = try JSONValue(data: Data(json.utf8))
		#expect(value["a"] == .null)
		#expect(value["b"] == .bool(true))
		#expect(value["c"] == .number(1))
		#expect(value["d"] == .number(1.5))
		#expect(value["e"] == .string("x"))
		#expect(value["f"] == .array([.number(1), .bool(false)]))
		#expect(value["g"]?["h"]?.stringValue == "i")
	}

	@Test func booleansAndNumbersStayDistinct() throws {
		let value = try JSONValue(data: Data("[true, 1, 0, false]".utf8))
		#expect(value == [true, 1, 0, false])
		#expect(value[0]?.boolValue == true)
		#expect(value[1]?.doubleValue == 1)
		#expect(value[1]?.boolValue == nil)
	}

	@Test func roundTripsThroughData() throws {
		let original: JSONValue = [
			"string": "hello \"world\" / ünïcode",
			"int": 42,
			"negative": -7,
			"fraction": 0.25,
			"big": 1e20,
			"flag": false,
			"nothing": nil,
			"list": [1, "two", [3.5]],
			"nested": ["deep": ["deeper": true]],
		]
		let data = try original.jsonData()
		#expect(try JSONValue(data: data) == original)
		let pretty = try original.jsonData(pretty: true)
		#expect(try JSONValue(data: pretty) == original)
	}

	@Test func integersEncodeWithoutFraction() throws {
		let data = try JSONValue.array([1, -3, 2.5]).jsonData()
		#expect(String(decoding: data, as: UTF8.self) == "[1,-3,2.5]")
	}

	@Test func bridgesEncodableAndDecodable() throws {
		let sample = Sample(name: "clip", count: 3, ratio: 0.5, enabled: true, tags: ["a", "b"], note: nil)
		let value = try JSONValue(encoding: sample)
		#expect(value["name"] == "clip")
		#expect(value["count"]?.intValue == 3)
		#expect(value["tags"]?.arrayValue?.count == 2)
		let decoded: Sample = try value.decode()
		#expect(decoded == sample)
		#expect(try value.decode(Sample.self) == sample)
	}

	@Test func accessorsReturnNilForOtherKinds() {
		let value: JSONValue = "text"
		#expect(value.stringValue == "text")
		#expect(value.doubleValue == nil)
		#expect(value.intValue == nil)
		#expect(value.boolValue == nil)
		#expect(value.arrayValue == nil)
		#expect(value.objectValue == nil)
		#expect(value["key"] == nil)
		#expect(value[0] == nil)
		#expect(JSONValue.number(1.5).intValue == nil)
		#expect(JSONValue.null.isNull)
	}

	@Test func objectSubscriptSetter() {
		var value: JSONValue = ["a": 1]
		value["b"] = "two"
		value["a"] = nil
		#expect(value == ["b": "two"])
	}
}
