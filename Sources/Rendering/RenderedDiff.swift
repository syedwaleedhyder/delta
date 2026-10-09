import Foundation

/// Diffs two Markdown documents by rendering both to HTML and diffing the HTML token streams
/// (tags, entities, words, whitespace). Changed text is wrapped in `<ins>` / `<del>`; the page script
/// then marks each changed block so it gets a margin marker and can be navigated to.
enum RenderedDiff {
    struct Output: Sendable {
        var body: String
        var changeCount: Int
    }

    static func compute(old: String, new: String) -> Output {
        diffHTML(old: MarkdownRenderer.html(old), new: MarkdownRenderer.html(new))
    }

    static func diffHTML(old: String, new: String) -> Output {
        let a = tokenize(old)
        let b = tokenize(new)
        let ops = DiffEngine.ops(a, b) { $0 == $1 }

        var out = ""
        out.reserveCapacity(new.utf8.count + new.utf8.count / 4)
        var deleted: [String] = []
        var inserted: [String] = []
        var changeCount = 0

        func flush() {
            guard !deleted.isEmpty || !inserted.isEmpty else { return }
            changeCount += 1
            if !deleted.isEmpty {
                // Whole deleted blocks keep their structure; partial ones drop their tags so they
                // don't break the structure of the new document.
                emit(deleted, wrapper: "del", keepTags: isBalanced(deleted), into: &out)
            }
            if !inserted.isEmpty {
                emit(inserted, wrapper: "ins", keepTags: true, into: &out)
            }
            deleted.removeAll()
            inserted.removeAll()
        }

        for op in ops {
            switch op {
            case let .equal(_, j):
                flush()
                out += b[j]
            case let .remove(i):
                deleted.append(a[i])
            case let .insert(j):
                inserted.append(b[j])
            }
        }
        flush()
        return Output(body: out, changeCount: changeCount)
    }

    // MARK: - Tokens

    static func isTag(_ token: String) -> Bool {
        token.count > 1 && token.hasPrefix("<") && token.hasSuffix(">")
    }

    /// Tags, entities, whitespace runs, word runs and single punctuation characters.
    static func tokenize(_ html: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(html)
        var i = 0

        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < chars.count {
            let c = chars[i]
            if c == "<", let end = chars[i...].firstIndex(of: ">") {
                tokens.append(String(chars[i...end]))
                i = end + 1
            } else if c == "&", let end = entityEnd(chars, from: i) {
                tokens.append(String(chars[i...end]))
                i = end + 1
            } else if c.isWhitespace {
                var j = i
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                tokens.append(String(chars[i..<j]))
                i = j
            } else if isWord(c) {
                var j = i
                while j < chars.count && isWord(chars[j]) { j += 1 }
                tokens.append(String(chars[i..<j]))
                i = j
            } else {
                tokens.append(String(c))
                i += 1
            }
        }
        return tokens
    }

    private static func entityEnd(_ chars: [Character], from start: Int) -> Int? {
        var j = start + 1
        while j < chars.count && j - start <= 10 {
            let c = chars[j]
            if c == ";" { return j > start + 1 ? j : nil }
            guard c.isLetter || c.isNumber || c == "#" else { return nil }
            j += 1
        }
        return nil
    }

    private static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "col", "area", "source", "wbr"]

    private static func tagName(_ tag: String) -> (name: String, closing: Bool)? {
        guard !tag.hasPrefix("<!"), !tag.hasSuffix("/>") else { return nil }
        var body = tag.dropFirst().dropLast()
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard !name.isEmpty, !voidTags.contains(name) else { return nil }
        return (name, closing)
    }

    /// True when the tags in `tokens` open and close in matching pairs, i.e. they form whole elements.
    static func isBalanced(_ tokens: [String]) -> Bool {
        var stack: [String] = []
        var sawTag = false
        for token in tokens where isTag(token) {
            guard let (name, closing) = tagName(token) else { continue }
            sawTag = true
            if closing {
                guard stack.last == name else { return false }
                stack.removeLast()
            } else {
                stack.append(name)
            }
        }
        return sawTag && stack.isEmpty
    }

    private static func emit(_ tokens: [String], wrapper: String, keepTags: Bool, into out: inout String) {
        var text = ""
        func flushText() {
            guard !text.isEmpty else { return }
            if text.allSatisfy(\.isWhitespace) {
                out += text
            } else {
                out += "<\(wrapper)>\(text)</\(wrapper)>"
            }
            text = ""
        }
        for token in tokens {
            if isTag(token) {
                flushText()
                if keepTags { out += token }
            } else {
                text += token
            }
        }
        flushText()
    }

    // MARK: - Page

    /// Wraps the diff body in a full page. Scripts are restricted to the page's own nonce, so
    /// `<script>` tags or event handlers inside pasted Markdown never run.
    static func page(body: String, css: String) -> String {
        let nonce = UUID().uuidString
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src * data:; script-src 'nonce-\(nonce)'">
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown">
        \(body)
        </article>
        <script nonce="\(nonce)">
        window.delta = (function () {
          const blockSelector = 'p, li, h1, h2, h3, h4, h5, h6, pre, blockquote, td, th, hr';
          const blocks = [];
          document.querySelectorAll('ins, del').forEach(function (el) {
            const block = el.closest(blockSelector) || el;
            if (!block.classList.contains('chg')) {
              block.classList.add('chg');
              blocks.push(block);
            }
          });
          let index = -1;
          function show(i) {
            if (blocks.length === 0) return;
            index = (i + blocks.length) % blocks.length;
            blocks.forEach(function (b) { b.classList.remove('current'); });
            const block = blocks[index];
            block.classList.add('current');
            block.scrollIntoView({ block: 'center', behavior: 'smooth' });
          }
          return {
            next: function () { show(index + 1); },
            previous: function () { show(index < 0 ? blocks.length - 1 : index - 1); },
            count: function () { return blocks.length; }
          };
        })();
        </script>
        </body>
        </html>
        """
    }
}
