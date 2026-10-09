import Foundation

/// Line, word and character counts for one input.
struct TextStats: Equatable, Sendable {
    var lines = 0
    var words = 0
    var characters = 0

    init(lines: Int = 0, words: Int = 0, characters: Int = 0) {
        self.lines = lines
        self.words = words
        self.characters = characters
    }

    init(_ text: String) {
        lines = DiffEngine.splitLines(text).count
        characters = text.count
        // A word is a whitespace-separated run with at least one letter or digit, so Markdown
        // syntax such as "#", "-" or "```" isn't counted.
        words = text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}
