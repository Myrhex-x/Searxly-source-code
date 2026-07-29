//
//  SelectionActionsWebView.swift
//  SearxlyiOS
//
//  WKWebView subclass that adds Searxly actions to the text-selection edit menu:
//    · Explain This — opens the on-device page chat with the selection as the first question
//    · Translate This — shows the system translation popover for the selection (on-device)
//  `buildMenu(with:)` is the supported UIKit way in (WKWebView exposes no edit-menu delegate);
//  the intelligence item only appears when Apple Intelligence is available on the device.
//

import WebKit
import UIKit

@MainActor
final class SelectionActionsWebView: WKWebView {

    /// Called with the selected text when the user picks an action. Set by BrowserModel.
    var onExplainSelection: ((String) -> Void)?
    var onTranslateSelection: ((String) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }

        var actions: [UIAction] = []
        if PageIntelligence.isAvailable {
            actions.append(UIAction(title: L("Explain This"),
                                    image: UIImage(systemName: "apple.intelligence")) { [weak self] _ in
                self?.withSelection { self?.onExplainSelection?($0) }
            })
        }
        actions.append(UIAction(title: L("Translate This"),
                                image: UIImage(systemName: "character.bubble")) { [weak self] _ in
            self?.withSelection { self?.onTranslateSelection?($0) }
        })
        guard !actions.isEmpty else { return }

        let menu = UIMenu(options: .displayInline, children: actions)
        builder.insertSibling(menu, afterMenu: .standardEdit)
    }

    /// Fetches the current selection string and hands it over when non-trivial.
    private func withSelection(_ handler: @escaping (String) -> Void) {
        evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = (result as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2 else { return }
            // Bound the hand-off: a select-all on a huge page shouldn't flood the model prompt.
            handler(String(text.prefix(2_000)))
        }
    }
}
