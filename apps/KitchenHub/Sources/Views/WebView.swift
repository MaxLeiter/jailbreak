import SwiftUI
import WebKit

/// Thin WKWebView wrapper that reloads when the URL changes.
struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.load(URLRequest(url: url))
        context.coordinator.current = url
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.current != url {
            context.coordinator.current = url
            wv.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var current: URL?
    }
}
