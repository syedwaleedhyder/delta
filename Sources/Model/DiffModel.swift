import Foundation

/// A run of text inside a line; `changed` marks the words that differ from the other side.
struct Segment: Hashable, Sendable {
    var text: String
    var changed: Bool
}

struct DiffLine: Hashable, Sendable {
    /// 1-based line number in its source text.
    var number: Int
    var segments: [Segment]

    var text: String { segments.map(\.text).joined() }
}

enum RowKind: Hashable, Sendable {
    case equal, added, removed, modified
}

/// One row of the side-by-side view. `left` is nil for pure additions, `right` for pure removals.
struct DiffRow: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: RowKind
    let left: DiffLine?
    let right: DiffLine?
}

/// One row of the inline (unified) view.
struct InlineRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case equal, added, removed }

    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let segments: [Segment]
}

struct DiffResult: Sendable {
    var rows: [DiffRow] = []
    var inlineRows: [InlineRow] = []
    /// Row ids where each change block starts, used for next/previous navigation.
    var hunkStarts: [Int] = []
    var inlineHunkStarts: [Int] = []
    var additions = 0
    var deletions = 0

    static let empty = DiffResult()

    var hunkCount: Int { hunkStarts.count }
    var isIdentical: Bool { additions == 0 && deletions == 0 }
}
