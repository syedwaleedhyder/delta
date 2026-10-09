import SwiftUI

private enum DiffColors {
    static let addedLine = Color.green.opacity(0.12)
    static let addedWord = Color.green.opacity(0.35)
    static let removedLine = Color.red.opacity(0.10)
    static let removedWord = Color.red.opacity(0.32)
    static let emptySide = Color.secondary.opacity(0.06)
    static let current = Color.accentColor.opacity(0.8)
}

private let codeFont = Font.system(size: 12, design: .monospaced)

private func attributed(_ segments: [Segment], highlight: Color) -> AttributedString {
    var result = AttributedString()
    for segment in segments {
        var part = AttributedString(segment.text)
        if segment.changed { part.backgroundColor = highlight }
        result += part
    }
    // An empty line still needs height.
    return result.characters.isEmpty ? AttributedString(" ") : result
}

/// The raw text diff, side by side or inline. A single scroll view holds both columns, so they
/// always scroll together.
struct RawDiffView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch state.layout {
                    case .sideBySide:
                        ForEach(state.result.rows) { row in
                            SideBySideRow(row: row, isCurrent: isCurrent(row.id, in: state.result.hunkStarts))
                                .id(row.id)
                        }
                    case .inline:
                        ForEach(state.result.inlineRows) { row in
                            InlineDiffRow(row: row, isCurrent: isCurrent(row.id, in: state.result.inlineHunkStarts))
                                .id(row.id)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .onChange(of: state.navRequest.token) {
                let starts = state.layout == .sideBySide ? state.result.hunkStarts : state.result.inlineHunkStarts
                guard starts.indices.contains(state.currentHunk) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(starts[state.currentHunk], anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func isCurrent(_ rowID: Int, in starts: [Int]) -> Bool {
        starts.indices.contains(state.currentHunk) && starts[state.currentHunk] == rowID
    }
}

private struct LineNumber: View {
    let number: Int?

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(codeFont)
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

private struct SideBySideRow: View {
    let row: DiffRow
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 0) {
            cell(row.left, lineColor: DiffColors.removedLine, wordColor: DiffColors.removedWord)
            Divider()
            cell(row.right, lineColor: DiffColors.addedLine, wordColor: DiffColors.addedWord)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(DiffColors.current).frame(width: 3)
            }
        }
    }

    @ViewBuilder
    private func cell(_ line: DiffLine?, lineColor: Color, wordColor: Color) -> some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: line?.number)
            if let line {
                Text(attributed(line.segments, highlight: wordColor))
                    .font(codeFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background(for: line, lineColor: lineColor))
    }

    private func background(for line: DiffLine?, lineColor: Color) -> Color {
        if line == nil { return DiffColors.emptySide }
        return row.kind == .equal ? .clear : lineColor
    }
}

private struct InlineDiffRow: View {
    let row: InlineRow
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: row.oldNumber)
            LineNumber(number: row.newNumber)
            Text(sign)
                .font(codeFont)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(attributed(row.segments, highlight: wordColor))
                .font(codeFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(lineColor)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(DiffColors.current).frame(width: 3)
            }
        }
    }

    private var sign: String {
        switch row.kind {
        case .equal: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private var lineColor: Color {
        switch row.kind {
        case .equal: .clear
        case .added: DiffColors.addedLine
        case .removed: DiffColors.removedLine
        }
    }

    private var wordColor: Color {
        row.kind == .removed ? DiffColors.removedWord : DiffColors.addedWord
    }
}
