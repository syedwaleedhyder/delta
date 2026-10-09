import Foundation

/// Line diff with word-level refinement of lines that were changed rather than purely added or removed.
///
/// Lines are first anchored on lines that occur exactly once on each side (patience diff), so repeated
/// lines such as blank lines can't split a rewritten section apart. Between anchors the diff is Myers,
/// via the standard library's `CollectionDifference`. Within a changed block, removed and added lines
/// are paired by similarity rather than by position.
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
        let keysA = a.map(key)
        let keysB = b.map(key)
        let blocks = mergeAcrossBlankLines(blocks(from: patienceOps(keysA, keysB)), a, b)

        var result = DiffResult()

        func plain(_ text: String) -> [Segment] { [Segment(text: text, changed: false)] }

        func appendEqualRow(_ i: Int, _ j: Int) {
            result.rows.append(DiffRow(
                id: result.rows.count, kind: .equal,
                left: DiffLine(number: i + 1, segments: plain(a[i])),
                right: DiffLine(number: j + 1, segments: plain(b[j]))))
            result.inlineRows.append(InlineRow(
                id: result.inlineRows.count, kind: .equal, oldNumber: i + 1, newNumber: j + 1,
                segments: plain(b[j])))
        }

        func appendChangedRow(_ row: DiffRow) {
            if result.rows.last.map({ $0.kind == .equal }) ?? true {
                result.hunkStarts.append(result.rows.count)
            }
            result.rows.append(row)
        }

        func emitChange(_ removed: [Int], _ inserted: [Int]) {
            // Pair removed and inserted lines by similarity; those become "modified" rows.
            let pairs = pairBySimilarity(
                removed.map { a[$0] }, inserted.map { b[$0] },
                removed.map { keysA[$0] }, inserted.map { keysB[$0] })

            // Inline rows: within each run between unchanged lines, removals come before additions.
            var pendingRemoved: [InlineRow] = []
            var pendingInserted: [InlineRow] = []
            func flushInline() {
                guard !pendingRemoved.isEmpty || !pendingInserted.isEmpty else { return }
                if result.inlineRows.last.map({ $0.kind == .equal }) ?? true {
                    result.inlineHunkStarts.append(result.inlineRows.count)
                }
                for row in pendingRemoved + pendingInserted {
                    result.inlineRows.append(InlineRow(
                        id: result.inlineRows.count, kind: row.kind, oldNumber: row.oldNumber,
                        newNumber: row.newNumber, segments: row.segments))
                }
                pendingRemoved.removeAll()
                pendingInserted.removeAll()
            }
            func removedRow(_ r: Int, _ segments: [Segment]) {
                pendingRemoved.append(InlineRow(
                    id: 0, kind: .removed, oldNumber: removed[r] + 1, newNumber: nil, segments: segments))
                result.deletions += 1
            }
            func insertedRow(_ i: Int, _ segments: [Segment]) {
                pendingInserted.append(InlineRow(
                    id: 0, kind: .added, oldNumber: nil, newNumber: inserted[i] + 1, segments: segments))
                result.additions += 1
            }
            func removeOnly(_ r: Int) {
                appendChangedRow(DiffRow(
                    id: result.rows.count, kind: .removed,
                    left: DiffLine(number: removed[r] + 1, segments: plain(a[removed[r]])), right: nil))
                removedRow(r, plain(a[removed[r]]))
            }
            func insertOnly(_ i: Int) {
                appendChangedRow(DiffRow(
                    id: result.rows.count, kind: .added,
                    left: nil, right: DiffLine(number: inserted[i] + 1, segments: plain(b[inserted[i]]))))
                insertedRow(i, plain(b[inserted[i]]))
            }

            var nextRemoved = 0
            var nextInserted = 0
            for (r, i) in pairs {
                while nextRemoved < r { removeOnly(nextRemoved); nextRemoved += 1 }
                while nextInserted < i { insertOnly(nextInserted); nextInserted += 1 }
                if keysA[removed[r]] == keysB[inserted[i]] {
                    // Identical line (a blank) that sits between changes that were merged into one block.
                    flushInline()
                    appendEqualRow(removed[r], inserted[i])
                } else {
                    let (left, right) = wordDiff(a[removed[r]], b[inserted[i]], options: options)
                    appendChangedRow(DiffRow(
                        id: result.rows.count, kind: .modified,
                        left: DiffLine(number: removed[r] + 1, segments: left),
                        right: DiffLine(number: inserted[i] + 1, segments: right)))
                    removedRow(r, left)
                    insertedRow(i, right)
                }
                nextRemoved = r + 1
                nextInserted = i + 1
            }
            while nextRemoved < removed.count { removeOnly(nextRemoved); nextRemoved += 1 }
            while nextInserted < inserted.count { insertOnly(nextInserted); nextInserted += 1 }
            flushInline()
        }

        for block in blocks {
            switch block {
            case let .equal(i, j): appendEqualRow(i, j)
            case let .change(removed, inserted): emitChange(removed, inserted)
            }
        }
        return result
    }

    // MARK: - Change blocks

    enum Block: Equatable {
        case equal(Int, Int)
        case change(removed: [Int], inserted: [Int])
    }

    /// Groups an edit script into unchanged lines and blocks of removed/inserted lines.
    static func blocks(from ops: [Op]) -> [Block] {
        var result: [Block] = []
        var removed: [Int] = []
        var inserted: [Int] = []
        func flush() {
            guard !removed.isEmpty || !inserted.isEmpty else { return }
            result.append(.change(removed: removed, inserted: inserted))
            removed.removeAll()
            inserted.removeAll()
        }
        for op in ops {
            switch op {
            case let .equal(i, j): flush(); result.append(.equal(i, j))
            case let .remove(i): removed.append(i)
            case let .insert(j): inserted.append(j)
            }
        }
        flush()
        return result
    }

    /// Largest removed × inserted block that is paired by similarity; beyond it pairing is positional.
    private static let maxPairingCells = 40_000

    /// Blank lines that merely separate two change blocks match by coincidence (every document has
    /// them), and they split a rewritten section in two so its lines are never compared. Fold them into
    /// one block; similarity pairing then decides which blank lines really correspond.
    static func mergeAcrossBlankLines(_ blocks: [Block], _ a: [String], _ b: [String]) -> [Block] {
        func isBlank(_ s: String) -> Bool { s.allSatisfy { $0.isWhitespace } }

        var result: [Block] = []
        var current: (removed: [Int], inserted: [Int])?
        var blanks: [(Int, Int)] = []

        func close() {
            if let current { result.append(.change(removed: current.removed, inserted: current.inserted)) }
            for (i, j) in blanks { result.append(.equal(i, j)) }
            current = nil
            blanks = []
        }

        for block in blocks {
            switch block {
            case let .equal(i, j):
                if current != nil && isBlank(a[i]) && isBlank(b[j]) {
                    blanks.append((i, j))
                } else {
                    close()
                    result.append(.equal(i, j))
                }
            case let .change(removed, inserted):
                if let open = current {
                    let mergedRemoved = open.removed + blanks.map(\.0) + removed
                    let mergedInserted = open.inserted + blanks.map(\.1) + inserted
                    if mergedRemoved.count * mergedInserted.count <= maxPairingCells {
                        current = (mergedRemoved, mergedInserted)
                        blanks = []
                        continue
                    }
                    close()
                }
                current = (removed, inserted)
            }
        }
        close()
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

    /// Patience-style line diff: anchors on lines that occur exactly once on both sides, keeps the longest
    /// ordered run of them, and diffs what lies between with Myers.
    static func patienceOps(_ a: [String], _ b: [String]) -> [Op] {
        var result: [Op] = []
        result.reserveCapacity(max(a.count, b.count))

        func solve(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) {
            var lo1 = aStart, hi1 = aEnd, lo2 = bStart, hi2 = bEnd
            while lo1 < hi1 && lo2 < hi2 && a[lo1] == b[lo2] {
                result.append(.equal(lo1, lo2)); lo1 += 1; lo2 += 1
            }
            var tail = 0
            while lo1 < hi1 && lo2 < hi2 && a[hi1 - 1] == b[hi2 - 1] {
                hi1 -= 1; hi2 -= 1; tail += 1
            }

            let anchors = uniqueAnchors(a, lo1, hi1, b, lo2, hi2)
            if anchors.isEmpty {
                let offsetA = lo1, offsetB = lo2
                for op in ops(Array(a[lo1..<hi1]), Array(b[lo2..<hi2]), by: { $0 == $1 }) {
                    switch op {
                    case let .equal(i, j): result.append(.equal(offsetA + i, offsetB + j))
                    case let .remove(i): result.append(.remove(offsetA + i))
                    case let .insert(j): result.append(.insert(offsetB + j))
                    }
                }
            } else {
                var nextA = lo1, nextB = lo2
                for (x, y) in anchors {
                    solve(nextA, x, nextB, y)
                    result.append(.equal(x, y))
                    nextA = x + 1; nextB = y + 1
                }
                solve(nextA, hi1, nextB, hi2)
            }

            for k in 0..<tail { result.append(.equal(hi1 + k, hi2 + k)) }
        }

        solve(0, a.count, 0, b.count)
        return result
    }

    /// Index pairs of lines that occur exactly once in both ranges, reduced to the longest run that is
    /// in order on both sides.
    private static func uniqueAnchors(
        _ a: [String], _ aStart: Int, _ aEnd: Int,
        _ b: [String], _ bStart: Int, _ bEnd: Int
    ) -> [(Int, Int)] {
        guard aStart < aEnd, bStart < bEnd else { return [] }
        var countA: [String: Int] = [:]
        var countB: [String: Int] = [:]
        var positionInB: [String: Int] = [:]
        for i in aStart..<aEnd { countA[a[i], default: 0] += 1 }
        for j in bStart..<bEnd { countB[b[j], default: 0] += 1; positionInB[b[j]] = j }

        var candidates: [(Int, Int)] = []
        for i in aStart..<aEnd where countA[a[i]] == 1 && countB[a[i]] == 1 {
            if let j = positionInB[a[i]] { candidates.append((i, j)) }
        }
        guard !candidates.isEmpty else { return [] }

        // Longest increasing subsequence on the B positions (patience sorting).
        var tails: [Int] = []          // candidate index ending the best run of each length
        var previous = [Int?](repeating: nil, count: candidates.count)
        for (k, candidate) in candidates.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if candidates[tails[mid]].1 < candidate.1 { low = mid + 1 } else { high = mid }
            }
            previous[k] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(k) } else { tails[low] = k }
        }

        var chain: [(Int, Int)] = []
        var cursor: Int? = tails.last
        while let k = cursor {
            chain.append(candidates[k])
            cursor = previous[k]
        }
        return chain.reversed()
    }

    /// Matches removed lines to added lines that are similar to them, keeping both in order, so a
    /// reworded line gets word-level highlights even when lines around it were added or deleted.
    /// Returns (removed index, inserted index) pairs in ascending order.
    static func pairBySimilarity(
        _ removed: [String], _ inserted: [String], _ removedKeys: [String], _ insertedKeys: [String]
    ) -> [(Int, Int)] {
        let n = removed.count, m = inserted.count
        guard n > 0, m > 0 else { return [] }
        // A lone replaced line is always shown as a modification.
        if n == 1 && m == 1 { return [(0, 0)] }
        // Very large blocks: fall back to pairing by position.
        if n * m > maxPairingCells { return (0..<min(n, m)).map { ($0, $0) } }

        let bagsA = removed.map(wordBag)
        let bagsB = inserted.map(wordBag)
        let threshold = 0.35
        let blankMatchScore = 0.2

        // score[i][j]: best total similarity using the first i removed and first j inserted lines.
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var similarity = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 1...n {
            for j in 1...m {
                let s: Double
                if removedKeys[i - 1] == insertedKeys[j - 1] {
                    // Identical lines match outright; identical blank lines only weakly, so they
                    // never outweigh a genuine reworded pair.
                    s = removed[i - 1].allSatisfy { $0.isWhitespace } ? blankMatchScore : 1
                } else {
                    let dice = diceSimilarity(bagsA[i - 1], bagsB[j - 1])
                    s = dice >= threshold ? dice : 0
                }
                similarity[i - 1][j - 1] = s
                var best = max(score[i - 1][j], score[i][j - 1])
                if s > 0 { best = max(best, score[i - 1][j - 1] + s) }
                score[i][j] = best
            }
        }

        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            let s = similarity[i - 1][j - 1]
            if s > 0 && score[i][j] == score[i - 1][j - 1] + s {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    private static func wordBag(_ line: String) -> [String: Int] {
        var bag: [String: Int] = [:]
        for token in tokenize(line) where token.first.map({ $0.isLetter || $0.isNumber }) ?? false {
            bag[token.lowercased(), default: 0] += 1
        }
        return bag
    }

    /// Dice coefficient of two word multisets: 1 for identical words, 0 for nothing in common.
    private static func diceSimilarity(_ x: [String: Int], _ y: [String: Int]) -> Double {
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total > 0 else { return 0 }
        var shared = 0
        for (word, count) in x { shared += min(count, y[word] ?? 0) }
        return Double(2 * shared) / Double(total)
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
