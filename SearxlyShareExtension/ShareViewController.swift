//
//  ShareViewController.swift
//  SearxlyShareExtension — "Open in Searxly" Share/Action extension
//
//  Shows up in the system share sheet from any app (Safari, Mail, Messages, …). It pulls the shared
//  URL (or a URL found in shared text), hands it to the app via a searxly://open?url=… deep link,
//  and dismisses. No UI of its own — it's a one-shot bridge. Nothing is uploaded.
//
//  Uses NSExtensionPrincipalClass (this class) instead of a storyboard, so the target needs no
//  MainInterface.storyboard.
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await run() }
    }

    private func run() async {
        guard let url = await sharedURL() else { return finish() }
        var comps = URLComponents()
        comps.scheme = "searxly"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let deepLink = comps.url { openHostApp(deepLink) }
        finish()
    }

    /// The shared page URL — either a first-class URL attachment or a URL parsed out of shared text.
    private func sharedURL() async -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = value as? URL {
                    return url
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let text = value as? String,
                   let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme != nil {
                    return url
                }
            }
        }
        return nil
    }

    /// Opens a URL in the containing app by walking the responder chain to UIApplication — the
    /// reliable way for a share extension to launch its host app with a custom scheme.
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
