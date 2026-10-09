import AppKit
import SwiftUI

@main
struct DeltaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Delta", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Delta") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Compare") {
                Button("Compare Now") { state.compareNow() }
                    .keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("Next Change") { state.next() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Change") { state.previous() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Divider()
                Toggle("Ignore Whitespace", isOn: $state.ignoreWhitespace)
                Button("Swap Sides") { state.swapSides() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Clear Both") { state.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }

            CommandGroup(before: .toolbar) {
                Picker("Diff View", selection: $state.mode) {
                    Text("Raw").tag(ViewMode.raw).keyboardShortcut("1", modifiers: .command)
                    Text("Rendered").tag(ViewMode.rendered).keyboardShortcut("2", modifiers: .command)
                }
                .pickerStyle(.inline)
                Picker("Raw Layout", selection: $state.layout) {
                    ForEach(RawLayout.allCases) { Text($0.title).tag($0) }
                }
                Button(state.showInputs ? "Hide Inputs" : "Show Inputs") {
                    withAnimation { state.showInputs.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    static func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "Diff Viewer\nCompare two texts, raw or as rendered Markdown.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Delta",
            .credits: credits,
        ])
    }
}
