import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VSplitView {
            if state.showInputs {
                HSplitView {
                    EditorPane(title: "Original", text: $state.left)
                        .frame(minWidth: 240)
                    EditorPane(title: "Changed", text: $state.right)
                        .frame(minWidth: 240)
                }
                .frame(minHeight: 120, idealHeight: 260)
            }
            ResultPane()
                .frame(minHeight: 200)
        }
        .navigationTitle("Delta")
        .navigationSubtitle("Diff Viewer")
        .toolbar { DiffToolbar() }
    }
}

private struct ResultPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            if !state.hasInput {
                ContentUnavailableView(
                    "Paste two texts to compare",
                    systemImage: "doc.on.doc",
                    description: Text("Put the original in the left box and the changed version in the right box. The diff updates as you type."))
            } else {
                switch state.mode {
                case .raw:
                    RawDiffView()
                case .rendered:
                    RenderedDiffView(
                        diffBody: state.renderedBody,
                        navToken: state.navRequest.token,
                        navDirection: state.navRequest.direction)
                }
            }
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            if state.hasInput {
                if state.result.isIdentical {
                    Label("No differences", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("+\(state.result.additions)").foregroundStyle(.green)
                    Text("−\(state.result.deletions)").foregroundStyle(.red)
                    Text(changeSummary).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isComputing {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var changeSummary: String {
        let count = state.result.hunkCount
        let noun = count == 1 ? "change" : "changes"
        if state.mode == .raw && state.currentHunk >= 0 {
            return "change \(state.currentHunk + 1) of \(count)"
        }
        return "\(count) \(noun)"
    }
}

private struct DiffToolbar: ToolbarContent {
    @EnvironmentObject private var state: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation { state.showInputs.toggle() }
            } label: {
                Label(state.showInputs ? "Hide Inputs" : "Show Inputs",
                      systemImage: "rectangle.split.1x2")
            }
            .help(state.showInputs ? "Hide the input boxes (⇧⌘I)" : "Show the input boxes (⇧⌘I)")
        }

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $state.mode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Raw text diff or rendered Markdown (⌘1 / ⌘2)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if state.mode == .raw {
                Picker("Layout", selection: $state.layout) {
                    ForEach(RawLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Side by side or inline")
            }

            ControlGroup {
                Button("Previous Change", systemImage: "chevron.up") { state.previous() }
                    .help("Previous change (⌥⌘↑)")
                Button("Next Change", systemImage: "chevron.down") { state.next() }
                    .help("Next change (⌥⌘↓)")
            }
            .disabled(state.result.isIdentical)

            Menu {
                Toggle("Ignore Whitespace", isOn: $state.ignoreWhitespace)
                Divider()
                Button("Swap Sides", systemImage: "arrow.left.arrow.right") { state.swapSides() }
                Button("Clear Both", systemImage: "trash", role: .destructive) { state.clear() }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }
}
