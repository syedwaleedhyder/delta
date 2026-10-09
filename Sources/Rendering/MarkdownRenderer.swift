import Foundation
import Markdown

enum MarkdownRenderer {
    static func html(_ markdown: String) -> String {
        HTMLFormatter.format(markdown)
    }
}
