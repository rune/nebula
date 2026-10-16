import Foundation

/// Cleans recognizer output into caption text: removes special tokens such as `<|en|>`,
/// non-speech markers such as "[Music]", "(silence)" or "*laughs*", music symbols and
/// stray whitespace.
enum CaptionText {
	/// Cleans a whole piece of text. Returns "" when nothing speakable is left.
	static func clean(_ text: String) -> String {
		var stripper = Stripper()
		return normalize(stripper.strip(text))
	}

	/// Collapses whitespace, removes spaces before punctuation and trims. Returns "" when the
	/// text has no letters or digits (for example a lone "-" or "...").
	static func normalize(_ text: String) -> String {
		var result = text.replacing(/\s+/, with: " ")
		result = result.replacing(/\s+([,.!?;:…%])/) { String($0.output.1) }
		result = result.trimmingCharacters(in: .whitespacesAndNewlines)
		while let first = result.first, ",;:".contains(first) {
			result.removeFirst()
			result = result.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		guard result.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
		return result
	}

	/// Removes markup from consecutive pieces of text (such as the words of one segment),
	/// remembering open brackets across pieces so that "[", "Music", "]" are all dropped.
	struct Stripper {
		private var depth = 0
		private var inAsterisks = false

		mutating func strip(_ text: String) -> String {
			let withoutTokens = text.replacing(/<\|[^|>]*\|>/, with: "").replacing(">>", with: "")
			var output = ""
			for character in withoutTokens {
				switch character {
				case "[", "(", "{":
					depth += 1
				case "]", ")", "}":
					depth = max(0, depth - 1)
				case "*":
					inAsterisks.toggle()
				case "♪", "♫", "♬", "🎵", "🎶":
					continue
				default:
					if depth == 0 && !inAsterisks { output.append(character) }
				}
			}
			return output
		}
	}
}
