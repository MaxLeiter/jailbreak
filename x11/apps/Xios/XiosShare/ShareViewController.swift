import UIKit
import UniformTypeIdentifiers
import os

/// "Share to the Linux desktop": a URL from Safari or a file from Files becomes
/// an xdg-open on the running desktop.
///
/// ARCHITECTURE NOTE — why there are two paths.
///
/// An app extension is a separate process with its own sandbox and its own
/// entitlements; it cannot touch the host app's memory, so every bit of
/// coordination goes through the unix sockets under /var/jb/tmp. Whether an appex
/// is *allowed* to reach those at all is not something we can assume — the
/// `no-container` + absolute-path-exception recipe in XiosShare/entitlements.plist
/// is proven for a full .app (IOSCLaunch, Xios) but not for an extension.
///
/// So this class probes first (XiosSandboxProbe) and then takes one of:
///   1. DIRECT — connect to ioscd.sock and send OPEN_URL. Preferred: no app
///      switch, the share sheet just reports success.
///   2. FALLBACK — hand the URL to the main app via `xios://open?url=…` through
///      NSExtensionContext.open. The app is not sandbox-restricted here, and it
///      does the same OPEN_URL call from a process that can reach the socket.
///
/// The fallback is not dead weight even if the direct path works: ioscd being
/// down, or a future iOS tightening the appex sandbox, both land here.
@objc(ShareViewController)
final class ShareViewController: UIViewController {

    private let log = Logger(subsystem: "com.max.xios.share", category: "share")

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let card = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        Task { await handleShare() }
    }

    // MARK: - Work

    private func handleShare() async {
        guard let shared = await extractSharedURL() else {
            finish(ok: false, title: "Nothing to send",
                   detail: "This item isn't a link or a file the desktop can open.")
            return
        }

        // Probe before choosing a route. Cheap (one connect) and it is the
        // evidence the device run needs.
        let probe = XiosSandboxProbe.run()
        let report = XiosSandboxProbe.report(probe)
        log.info("share probe:\n\(report, privacy: .public)")

        if probe.directPathUsable {
            do {
                try XiosControl.openURL(shared.absoluteString)
                finish(ok: true, title: "Sent to desktop",
                       detail: shared.absoluteString, diagnostics: report)
                return
            } catch {
                // Reachable but refused (bad scheme, no xdg-open, no compositor).
                // That is a real answer, not a routing problem — don't bounce
                // through the app just to get the same refusal.
                log.error("direct OPEN_URL refused: \(error.localizedDescription, privacy: .public)")
                finish(ok: false, title: "The desktop refused it",
                       detail: error.localizedDescription, diagnostics: report)
                return
            }
        }

        // No direct path. Route via the main app, which can reach the socket.
        log.notice("appex cannot reach ioscd directly; routing via the host app")
        await routeViaHostApp(shared, report: report)
    }

    /// Pull a URL out of the share payload. Safari gives a `public.url`; Files
    /// gives a `public.file-url`; a text share may still contain a link.
    private func extractSharedURL() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        for type in [UTType.url, UTType.fileURL] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let url = await loadURL(from: provider, type: type) { return url }
            }
        }
        // Last resort: a shared string that happens to be a link.
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(from: provider),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme != nil {
                return url
            }
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let s = String(data: data, encoding: .utf8),
                          let url = URL(string: s) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    /// Fallback: `xios://open?url=<percent-encoded>` — the app handles it in
    /// AppDelegate and makes the same OPEN_URL call.
    @MainActor
    private func routeViaHostApp(_ url: URL, report: String) async {
        var components = URLComponents()
        components.scheme = "xios"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]

        guard let handoff = components.url else {
            finish(ok: false, title: "Couldn't send it",
                   detail: "That link couldn't be encoded.", diagnostics: report)
            return
        }

        guard let context = extensionContext else { return }
        let opened = await context.open(handoff)
        if opened {
            finish(ok: true, title: "Opening in Xios",
                   detail: url.absoluteString, diagnostics: report)
        } else {
            finish(ok: false, title: "Couldn't reach the desktop",
                   detail: "The extension can't reach ioscd and the Xios app didn't open.",
                   diagnostics: report)
        }
    }

    // MARK: - UI

    private func finish(ok: Bool, title: String, detail: String, diagnostics: String? = nil) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.titleLabel.text = title
            self.detailLabel.text = detail
            if let diagnostics {
                self.diagnosticsLabel.text = diagnostics
                self.diagnosticsLabel.isHidden = false
            }
            // Leave a failure on screen long enough to read; a success can go.
            let delay: TimeInterval = ok ? 1.1 : 4.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private func buildUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = "Sending to the desktop…"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 3

        diagnosticsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        diagnosticsLabel.textColor = .tertiaryLabel
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.isHidden = true

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, diagnosticsLabel, spinner])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
    }
}
