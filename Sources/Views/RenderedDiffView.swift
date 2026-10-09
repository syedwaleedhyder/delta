import SwiftUI
import WebKit

/// Shows the rendered Markdown diff in a web view, keeping the scroll position when the content updates.
struct RenderedDiffView: NSViewRepresentable {
    let diffBody: String
    let navToken: Int
    let navDirection: NavDirection

    private static let css: String = {
        guard let url = Bundle.main.url(forResource: "diff", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedBody != diffBody {
            coordinator.loadedBody = diffBody
            let html = RenderedDiff.page(body: diffBody, css: Self.css)
            if coordinator.hasLoaded {
                webView.evaluateJavaScript("window.scrollY") { value, _ in
                    coordinator.pendingScrollY = value as? Double ?? 0
                    webView.loadHTMLString(html, baseURL: nil)
                }
            } else {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
        if coordinator.navToken != navToken {
            coordinator.navToken = navToken
            let call = navDirection == .next ? "window.delta.next()" : "window.delta.previous()"
            webView.evaluateJavaScript(call)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedBody: String?
        var hasLoaded = false
        var pendingScrollY: Double = 0
        var navToken = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoaded = true
            if pendingScrollY > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY))")
            }
        }

        /// Opens links in the default browser instead of navigating away from the diff.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
