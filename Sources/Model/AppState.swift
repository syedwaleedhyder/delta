import Foundation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case raw, rendered
    var id: String { rawValue }
    var title: String { self == .raw ? "Raw" : "Rendered" }
}

enum RawLayout: String, CaseIterable, Identifiable {
    case sideBySide, inline
    var id: String { rawValue }
    var title: String { self == .sideBySide ? "Side by Side" : "Inline" }
    var symbol: String { self == .sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

enum NavDirection { case next, previous }

@MainActor
final class AppState: ObservableObject {
    private enum Key {
        static let left = "leftText"
        static let right = "rightText"
        static let mode = "viewMode"
        static let layout = "rawLayout"
        static let ignoreWhitespace = "ignoreWhitespace"
        static let showInputs = "showInputs"
    }

    private let defaults = UserDefaults.standard

    @Published var left: String { didSet { textChanged(left, key: Key.left) } }
    @Published var right: String { didSet { textChanged(right, key: Key.right) } }

    @Published var mode: ViewMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    @Published var layout: RawLayout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    @Published var showInputs: Bool { didSet { defaults.set(showInputs, forKey: Key.showInputs) } }
    @Published var ignoreWhitespace: Bool {
        didSet {
            defaults.set(ignoreWhitespace, forKey: Key.ignoreWhitespace)
            recompute(after: .zero)
        }
    }

    @Published private(set) var result = DiffResult.empty
    @Published private(set) var renderedBody = ""
    @Published private(set) var renderedChangeCount = 0
    @Published private(set) var isComputing = false

    /// Index of the change the raw view is showing; -1 before the first navigation.
    @Published private(set) var currentHunk = -1
    /// Bumped on every next/previous request so views can react even when the index wraps to the same value.
    @Published private(set) var navRequest: (direction: NavDirection, token: Int) = (.next, 0)

    private var computeTask: Task<Void, Never>?

    init() {
        left = defaults.string(forKey: Key.left) ?? ""
        right = defaults.string(forKey: Key.right) ?? ""
        mode = ViewMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .raw
        layout = RawLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .sideBySide
        ignoreWhitespace = defaults.bool(forKey: Key.ignoreWhitespace)
        showInputs = defaults.object(forKey: Key.showInputs) as? Bool ?? true
        recompute(after: .zero)
    }

    var hasInput: Bool { !left.isEmpty || !right.isEmpty }

    private func textChanged(_ text: String, key: String) {
        defaults.set(text, forKey: key)
        recompute(after: .milliseconds(250))
    }

    func recompute(after delay: Duration) {
        computeTask?.cancel()
        let old = left, new = right
        let options = DiffEngine.Options(ignoreWhitespace: ignoreWhitespace)
        computeTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            isComputing = true
            let (diff, rendered) = await Task.detached(priority: .userInitiated) {
                (DiffEngine.compute(old: old, new: new, options: options),
                 RenderedDiff.compute(old: old, new: new))
            }.value
            if Task.isCancelled { return }
            result = diff
            renderedBody = rendered.body
            renderedChangeCount = rendered.changeCount
            currentHunk = -1
            isComputing = false
        }
    }

    func compareNow() { recompute(after: .zero) }

    func swapSides() {
        let old = left
        left = right
        right = old
    }

    func clear() {
        left = ""
        right = ""
    }

    func next() { navigate(.next) }
    func previous() { navigate(.previous) }

    private func navigate(_ direction: NavDirection) {
        let count = result.hunkCount
        if mode == .raw && count > 0 {
            switch direction {
            case .next: currentHunk = (currentHunk + 1) % count
            case .previous: currentHunk = currentHunk <= 0 ? count - 1 : currentHunk - 1
            }
        }
        navRequest = (direction, navRequest.token + 1)
    }
}
