import AppKit
import SwiftUI

/// A plain-text editor for pasting content. Unlike `TextEditor`, it turns off smart quotes, dashes,
/// autocorrect and other substitutions, which would otherwise create false differences.
struct InputEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text {
            // Replace through the text storage so the change can be undone (e.g. after Clear or Swap).
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: fullRange, replacementString: text) {
                textView.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}

/// One input column: a header with the title, line/word/character counts and Paste/Clear buttons,
/// above the editor.
struct EditorPane: View {
    let title: String
    @Binding var text: String

    var body: some View {
        let stats = TextStats(text)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Text(text.isEmpty ? "Empty" : summary(stats))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text.isEmpty ? "" : summary(stats))
                Spacer(minLength: 4)
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        text = pasted
                    }
                }
                .help("Replace with the clipboard contents")
                Button("Clear", systemImage: "xmark.circle") { text = "" }
                    .help("Clear this side")
                    .disabled(text.isEmpty)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            ZStack(alignment: .topLeading) {
                InputEditor(text: $text)
                if text.isEmpty {
                    Text("Paste the \(title.lowercased()) text here")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 11)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func summary(_ stats: TextStats) -> String {
        [count(stats.lines, "line"), count(stats.words, "word"), count(stats.characters, "char")]
            .joined(separator: " · ")
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }
}
