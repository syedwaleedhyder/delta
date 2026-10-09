import Foundation

/// Line diff (Myers, via the standard library's `CollectionDifference`) with word-level
/// refinement of lines that were changed rather than purely added or removed.
enum DiffEngine {
    struct Options: Hashable, Sendable {
        var ignoreWhitespace = false
    }

    enum Op: Equatable {
        case equal(Int, Int)
        case remove(Int)
        case insert(Int)
    }

    // MARK: - Public entry point

    static func compute(old: String, new: String, options: Options = Options()) -> DiffResult {
        let a = splitLines(old)
        let b = splitLines(new)
        let ignoreWhitespace = options.ignoreWhitespace
        let key: (String) -> String = { ignoreWhitespace ? collapseWhitespace($0) : $0 }
        let lineOps = ops(a.map(key), b.map(key)) { $0 == $1 }

        var result = DiffResult()
        var removed: [Int] = []
        var inserted: [Int] = []

        func flush() {
            guard !removed.isEmpty || !inserted.isEmpty else { return }
            result.hunkStarts.append(result.rows.count)
            result.inlineHunkStarts.append(result.inlineRows.count)

            // Pair removed and inserted lines in order; those become "modified" rows.
            let paired = min(removed.count, inserted.count)
            var leftSegments: [[Segment]] = []
            var rightSegments: [[Segment]] = []
            for k in 0..<paired {
                let (l, r) = wordDiff(a[removed[k]], b[inserted[k]], options: options)
                leftSegments.append(l)
                rightSegments.append(r)
            }

            for k in 0..<max(removed.count, inserted.count) {
                let id = result.rows.count
                if k < paired {
                    result.rows.append(DiffRow(
                        id: id, kind: .modified,
                        left: DiffLine(number: removed[k] + 1, segments: leftSegments[k]),
                        right: DiffLine(number: inserted[k] + 1, segments: rightSegments[k])))
                } else if k < removed.count {
                    result.rows.append(DiffRow(
                        id: id, kind: .removed,
                        left: DiffLine(number: removed[k] + 1, segments: [Segment(text: a[removed[k]], changed: false)]),
                        right: nil))
                } else {
                    result.rows.append(DiffRow(
                        id: id, kind: .added,
                        left: nil,
                        right: DiffLine(number: inserted[k] + 1, segments: [Segment(text: b[inserted[k]], changed: false)])))
                }
            }

            for (k, i) in removed.enumerated() {
                let segments = k < paired ? leftSegments[k] : [Segment(text: a[i], changed: false)]
                result.inlineRows.append(InlineRow(
                    id: result.inlineRows.count, kind: .removed, oldNumber: i + 1, newNumber: nil, segments: segments))
            }
            for (k, j) in inserted.enumerated() {
                let segments = k < paired ? rightSegments[k] : [Segment(text: b[j], changed: false)]
                result.inlineRows.append(InlineRow(
                    id: result.inlineRows.count, kind: .added, oldNumber: nil, newNumber: j + 1, segments: segments))
            }

            result.deletions += removed.count
            result.additions += inserted.count
            removed.removeAll()
            inserted.removeAll()
        }

        for op in lineOps {
            switch op {
            case let .equal(i, j):
                flush()
                result.rows.append(DiffRow(
                    id: result.rows.count, kind: .equal,
                    left: DiffLine(number: i + 1, segments: [Segment(text: a[i], changed: false)]),
                    right: DiffLine(number: j + 1, segments: [Segment(text: b[j], changed: false)])))
                result.inlineRows.append(InlineRow(
                    id: result.inlineRows.count, kind: .equal, oldNumber: i + 1, newNumber: j + 1,
                    segments: [Segment(text: b[j], changed: false)]))
            case let .remove(i):
                removed.append(i)
            case let .insert(j):
                inserted.append(j)
            }
        }
        flush()
        return result
    }

    // MARK: - Building blocks

    /// Splits text into lines, treating CRLF, CR and LF alike. A trailing newline does not add an empty line.
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// Turns a Myers diff into an ordered edit script. Within a change block, removals come before insertions.
    static func ops<T>(_ a: [T], _ b: [T], by areEquivalent: (T, T) -> Bool) -> [Op] {
        let difference = b.difference(from: a, by: areEquivalent)
        var isRemoved = [Bool](repeating: false, count: a.count)
        var isInserted = [Bool](repeating: false, count: b.count)
        for change in difference {
            switch change {
            case let .remove(offset, _, _): isRemoved[offset] = true
            case let .insert(offset, _, _): isInserted[offset] = true
            }
        }

        var result: [Op] = []
        result.reserveCapacity(max(a.count, b.count))
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && isRemoved[i] {
                result.append(.remove(i)); i += 1
            } else if j < b.count && isInserted[j] {
                result.append(.insert(j)); j += 1
            } else {
                result.append(.equal(i, j)); i += 1; j += 1
            }
        }
        return result
    }

    /// Splits a line into word, whitespace and single-punctuation tokens.
    static func tokenize(_ line: String) -> [String] {
        enum Kind { case word, space, other }
        func kind(_ c: Character) -> Kind {
            if c.isWhitespace { return .space }
            if c.isLetter || c.isNumber || c == "_" { return .word }
            return .other
        }

        var tokens: [String] = []
        var current = ""
        var currentKind: Kind?
        for c in line {
            let k = kind(c)
            if k == currentKind && k != .other {
                current.append(c)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(c)
                currentKind = k
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Word-level diff of two lines. If they share too little, the whole line is marked as changed
    /// instead, since scattered single-word matches are harder to read than a plain replacement.
    static func wordDiff(_ old: String, _ new: String, options: Options) -> ([Segment], [Segment]) {
        let ta = tokenize(old)
        let tb = tokenize(new)
        let isSpace: (String) -> Bool = { $0.first?.isWhitespace ?? false }
        let equivalent: (String, String) -> Bool = options.ignoreWhitespace
            ? { $0 == $1 || (isSpace($0) && isSpace($1)) }
            : { $0 == $1 }
        let tokenOps = ops(ta, tb, by: equivalent)

        var left: [Segment] = []
        var right: [Segment] = []
        var sharedChars = 0
        for op in tokenOps {
            switch op {
            case let .equal(i, j):
                append(ta[i], changed: false, to: &left)
                append(tb[j], changed: false, to: &right)
                if !isSpace(ta[i]) { sharedChars += ta[i].count }
            case let .remove(i):
                append(ta[i], changed: !isSpace(ta[i]) || !options.ignoreWhitespace, to: &left)
            case let .insert(j):
                append(tb[j], changed: !isSpace(tb[j]) || !options.ignoreWhitespace, to: &right)
            }
        }

        let total = max(old.filter { !$0.isWhitespace }.count, new.filter { !$0.isWhitespace }.count)
        if total > 0 && Double(sharedChars) / Double(total) < 0.3 {
            return ([Segment(text: old, changed: true)], [Segment(text: new, changed: true)])
        }
        return (left, right)
    }

    private static func append(_ text: String, changed: Bool, to segments: inout [Segment]) {
        if let last = segments.last, last.changed == changed {
            segments[segments.count - 1].text += text
        } else {
            segments.append(Segment(text: text, changed: changed))
        }
    }

    static func collapseWhitespace(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
