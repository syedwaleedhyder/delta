import XCTest
@testable import Delta

final class DiffEngineTests: XCTestCase {
    private func kinds(_ result: DiffResult) -> [RowKind] { result.rows.map(\.kind) }

    func testIdenticalTexts() {
        let text = "# Title\n\nSome text.\n"
        let result = DiffEngine.compute(old: text, new: text)
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(kinds(result), [.equal, .equal, .equal])
        XCTAssertEqual(result.hunkCount, 0)
    }

    func testEmptyInputs() {
        XCTAssertTrue(DiffEngine.compute(old: "", new: "").rows.isEmpty)

        let added = DiffEngine.compute(old: "", new: "a\nb")
        XCTAssertEqual(kinds(added), [.added, .added])
        XCTAssertEqual(added.additions, 2)
        XCTAssertEqual(added.deletions, 0)

        let removed = DiffEngine.compute(old: "a\nb", new: "")
        XCTAssertEqual(kinds(removed), [.removed, .removed])
        XCTAssertEqual(removed.deletions, 2)
    }

    func testPureInsertion() {
        let result = DiffEngine.compute(old: "one\nthree", new: "one\ntwo\nthree")
        XCTAssertEqual(kinds(result), [.equal, .added, .equal])
        XCTAssertEqual(result.rows[1].right?.number, 2)
        XCTAssertNil(result.rows[1].left)
        XCTAssertEqual(result.hunkStarts, [1])
    }

    func testPureDeletion() {
        let result = DiffEngine.compute(old: "one\ntwo\nthree", new: "one\nthree")
        XCTAssertEqual(kinds(result), [.equal, .removed, .equal])
        XCTAssertEqual(result.rows[1].left?.number, 2)
        XCTAssertEqual(result.deletions, 1)
    }

    func testModifiedLineHasWordSegments() {
        let result = DiffEngine.compute(
            old: "The quick brown fox jumps",
            new: "The quick red fox jumps")
        XCTAssertEqual(kinds(result), [.modified])
        let left = result.rows[0].left!.segments
        let right = result.rows[0].right!.segments
        XCTAssertEqual(left.filter(\.changed).map(\.text), ["brown"])
        XCTAssertEqual(right.filter(\.changed).map(\.text), ["red"])
        XCTAssertEqual(result.rows[0].left!.text, "The quick brown fox jumps")
        XCTAssertEqual(result.rows[0].right!.text, "The quick red fox jumps")
    }

    func testCompletelyDifferentLineIsWhollyChanged() {
        let (left, right) = DiffEngine.wordDiff("alpha beta gamma", "one two three", options: .init())
        XCTAssertEqual(left, [Segment(text: "alpha beta gamma", changed: true)])
        XCTAssertEqual(right, [Segment(text: "one two three", changed: true)])
    }

    func testMovedLineShowsAsRemoveAndAdd() {
        let result = DiffEngine.compute(old: "a\nb\nc", new: "b\nc\na")
        XCTAssertEqual(result.additions, 1)
        XCTAssertEqual(result.deletions, 1)
        XCTAssertEqual(result.hunkCount, 2)
    }

    func testLineEndingsAreNormalized() {
        let result = DiffEngine.compute(old: "a\r\nb\r\n", new: "a\nb\n")
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(DiffEngine.splitLines("a\rb"), ["a", "b"])
        XCTAssertEqual(DiffEngine.splitLines("a\n"), ["a"])
        XCTAssertEqual(DiffEngine.splitLines("a\n\n"), ["a", ""])
    }

    func testIgnoreWhitespace() {
        let old = "let  x =  1\n\tindented"
        let new = "let x = 1\n    indented"
        XCTAssertFalse(DiffEngine.compute(old: old, new: new).isIdentical)
        XCTAssertTrue(DiffEngine.compute(old: old, new: new, options: .init(ignoreWhitespace: true)).isIdentical)
    }

    func testInlineRowsListRemovalsBeforeAdditions() {
        let result = DiffEngine.compute(old: "same\nold line here", new: "same\nnew line here")
        XCTAssertEqual(result.inlineRows.map(\.kind), [.equal, .removed, .added])
        XCTAssertEqual(result.inlineHunkStarts, [1])
    }

    func testTokenize() {
        XCTAssertEqual(DiffEngine.tokenize("Hello, world_1!  ok"),
                       ["Hello", ",", " ", "world_1", "!", "  ", "ok"])
    }
}

final class RenderedDiffTests: XCTestCase {
    func testIdenticalDocumentsHaveNoMarkup() {
        let output = RenderedDiff.compute(old: "# Title\n\nText", new: "# Title\n\nText")
        XCTAssertEqual(output.changeCount, 0)
        XCTAssertFalse(output.body.contains("<ins>"))
        XCTAssertFalse(output.body.contains("<del>"))
    }

    func testChangedWordIsWrapped() {
        let output = RenderedDiff.compute(old: "Hello brave world", new: "Hello new world")
        XCTAssertTrue(output.body.contains("<del>brave</del>"), output.body)
        XCTAssertTrue(output.body.contains("<ins>new</ins>"), output.body)
        XCTAssertEqual(output.changeCount, 1)
    }

    func testAddedParagraphKeepsItsTags() {
        let output = RenderedDiff.compute(old: "First", new: "First\n\nSecond paragraph")
        XCTAssertTrue(output.body.contains("<p><ins>Second paragraph</ins></p>"), output.body)
    }

    func testDeletedListItemKeepsItsStructure() {
        let output = RenderedDiff.compute(old: "- one\n- two\n- three", new: "- one\n- three")
        XCTAssertTrue(output.body.contains("<li><del>two</del></li>") || output.body.contains("<del>two</del>"), output.body)
        XCTAssertTrue(output.body.contains("<ul>"))
    }

    func testHeadingLevelChangeProducesValidStructure() {
        let output = RenderedDiff.compute(old: "# Title", new: "## Title")
        XCTAssertTrue(output.body.contains("<h2>Title</h2>"), output.body)
        XCTAssertFalse(output.body.contains("<h1>"), output.body)
    }

    func testEscapedTextIsNotSplitInsideEntities() {
        XCTAssertEqual(RenderedDiff.tokenize("a &amp; b"), ["a", " ", "&amp;", " ", "b"])
        XCTAssertEqual(RenderedDiff.tokenize("<p class=\"x\">hi</p>"), ["<p class=\"x\">", "hi", "</p>"])
    }

    func testBalancedTags() {
        XCTAssertTrue(RenderedDiff.isBalanced(["<p>", "x", "</p>"]))
        XCTAssertFalse(RenderedDiff.isBalanced(["<p>", "x"]))
        XCTAssertFalse(RenderedDiff.isBalanced(["x", "y"]))
        XCTAssertTrue(RenderedDiff.isBalanced(["<li>", "<p>", "x", "</p>", "</li>"]))
    }

    func testPageBlocksScriptsFromContent() {
        let page = RenderedDiff.page(body: "<script>alert(1)</script>", css: "")
        XCTAssertTrue(page.contains("script-src 'nonce-"))
    }
}

final class TextStatsTests: XCTestCase {
    func testEmptyText() {
        XCTAssertEqual(TextStats(""), TextStats())
    }

    func testCountsLinesWordsAndCharacters() {
        let stats = TextStats("# Title\n\nHello, world!\n")
        XCTAssertEqual(stats.lines, 3)
        XCTAssertEqual(stats.words, 3)
        XCTAssertEqual(stats.characters, 23)
    }

    func testMarkdownSyntaxIsNotAWord() {
        XCTAssertEqual(TextStats("- one\n- two\n```\ncode\n```").words, 3)
    }

    func testCharactersCountEmojiOnce() {
        XCTAssertEqual(TextStats("👍🏽 ok").characters, 4)
    }
}
