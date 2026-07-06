//
//  SearchSettingsView.swift
//  Searxly
//

import SwiftUI
import AppKit

struct SearchSettingsView: View {
    @Binding var knowledgePanelEnabled: Bool

    @AppStorage(AppLanguage.overrideKey) private var appLanguageOverride: String = ""
    @AppStorage("searchQueryHistoryEnabled") private var searchQueryHistoryEnabled: Bool = true

    @State private var showClearConfirmation = false
    /// Language in effect when this pane opened — used to offer a relaunch once it changes.
    @State private var languageWhenOpened: String = ""

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Search",
                subtitle: "Control how Searxly presents search results on your Mac."
            )

            languageSection

            searchHistorySection

            SettingsSection(
                title: "Knowledge panel",
                footer: "Shows entity cards on the right side of web results. Disable this if you want zero external connections — your main search always stays private through your local SearXNG."
            ) {
                SettingsCallout(
                    title: "Connects directly to Grokipedia",
                    message: "When enabled, Searxly fetches article data directly from grokipedia.com for every entity card shown. Your search query reaches Grokipedia's servers — it does not go through your private SearXNG instance. Grokipedia can see what you searched and your IP address (or your VPN exit IP if a VPN is active).",
                    tint: .orange,
                    systemImage: "exclamationmark.triangle.fill"
                )

                SettingsToggleRow(
                    title: "Knowledge panel on search results",
                    description: "Google-style info cards for brands, people, and dictionary words.",
                    isOn: $knowledgePanelEnabled
                )
            }
        }
    }

    // MARK: - Language section

    @ViewBuilder
    private var languageSection: some View {
        SettingsSection(
            title: "Language",
            footer: "One language for all of Searxly — the interface and your search results. By default it follows your Mac (System Settings → Language & Region). The interface itself ships in English and French so far; other choices fall back to English while search results still use your language."
        ) {
            let effectiveLabel: String = {
                if appLanguageOverride.isEmpty {
                    return "System (\(AppLanguage.systemSearchLanguageCode))"
                }
                return SearchLanguage.all.first(where: { $0.code == appLanguageOverride })?.displayLabel
                    ?? appLanguageOverride
            }()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Searxly language")
                        .font(.callout)
                    Text("Active: \(effectiveLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button {
                        AppLanguage.setOverride(nil)
                        appLanguageOverride = ""
                    } label: {
                        HStack {
                            Text("System default (\(AppLanguage.systemSearchLanguageCode))")
                            if appLanguageOverride.isEmpty { Image(systemName: "checkmark") }
                        }
                    }

                    Divider()

                    ForEach(SearchLanguage.all) { lang in
                        Button {
                            AppLanguage.setOverride(lang.code)
                            appLanguageOverride = lang.code
                        } label: {
                            HStack {
                                Text(lang.displayLabel)
                                if lang.code == appLanguageOverride { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(effectiveLabel)
                            .font(.callout)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !appLanguageOverride.isEmpty {
                Button("Reset to system default") {
                    AppLanguage.setOverride(nil)
                    appLanguageOverride = ""
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .onAppear { languageWhenOpened = appLanguageOverride }

        if appLanguageOverride != languageWhenOpened {
            SettingsCallout(
                title: "Search already speaks your new language",
                message: "New searches use it immediately. Relaunch Searxly to switch the interface too.",
                tint: .secondary,
                systemImage: "arrow.triangle.2.circlepath"
            )
            SettingsActionChip(title: "Relaunch Searxly", systemImage: "arrow.triangle.2.circlepath") {
                relaunchSearxly()
            }
        }
    }

    /// Starts a fresh instance (the `-n` equivalent — see the stale-instance relaunch gotcha),
    /// then quits this one so the new language applies everywhere.
    private func relaunchSearxly() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Search history section

    @ViewBuilder
    private var searchHistorySection: some View {
        SettingsSection(
            title: "Search History",
            footer: "When enabled, past search queries are suggested as you type. Only queries that returned results are saved — nothing leaves your device."
        ) {
            SettingsToggleRow(
                title: "Suggest recent searches",
                description: "Show past search queries in the address bar dropdown.",
                isOn: $searchQueryHistoryEnabled
            )

            if searchQueryHistoryEnabled {
                HStack {
                    Button("Clear search history") {
                        SearchQueryHistoryStore.shared.clearAll()
                        showClearConfirmation = true
                    }
                    .font(.callout)
                    .buttonStyle(.link)
                    .foregroundStyle(.red)

                    Spacer()
                }
                .alert("Search history cleared", isPresented: $showClearConfirmation) {
                    Button("OK") {}
                }
            }
        }
    }
}

// MARK: - Language list

/// Languages offered by the in-app picker. Every code here MUST be registered in the local
/// SearXNG's `search.languages` (settings.yml) — the runtime silently strips (or rejects)
/// unregistered locales, which is why some entries are bare codes ("hi", "uk", "vi") and
/// Norwegian/Hebrew are absent (not valid sxng locales on the bundled runtime).
struct SearchLanguage: Identifiable {
    let code: String   // SearXNG format: "en-US", "fr-FR", or bare "hi".
    let label: String
    var id: String { code }

    /// "French (France) · Français" — English label plus the language's own name for itself.
    var displayLabel: String {
        let locale = Locale(identifier: code)
        guard let autonym = locale.localizedString(forLanguageCode: AppLanguage.baseCode(of: code)),
              !label.lowercased().hasPrefix(autonym.lowercased())
        else { return label }
        return "\(label) · \(autonym.capitalized(with: locale))"
    }

    static let all: [SearchLanguage] = [
        SearchLanguage(code: "en-US",  label: "English (US)"),
        SearchLanguage(code: "en-GB",  label: "English (UK)"),
        SearchLanguage(code: "en-CA",  label: "English (Canada)"),
        SearchLanguage(code: "en-AU",  label: "English (Australia)"),
        SearchLanguage(code: "fr-FR",  label: "French (France)"),
        SearchLanguage(code: "fr-CA",  label: "French (Canada)"),
        SearchLanguage(code: "de-DE",  label: "German"),
        SearchLanguage(code: "es-ES",  label: "Spanish (Spain)"),
        SearchLanguage(code: "es-MX",  label: "Spanish (Mexico)"),
        SearchLanguage(code: "it-IT",  label: "Italian"),
        SearchLanguage(code: "pt-PT",  label: "Portuguese (Portugal)"),
        SearchLanguage(code: "pt-BR",  label: "Portuguese (Brazil)"),
        SearchLanguage(code: "nl-NL",  label: "Dutch"),
        SearchLanguage(code: "sv-SE",  label: "Swedish"),
        SearchLanguage(code: "da-DK",  label: "Danish"),
        SearchLanguage(code: "fi-FI",  label: "Finnish"),
        SearchLanguage(code: "pl-PL",  label: "Polish"),
        SearchLanguage(code: "ru-RU",  label: "Russian"),
        SearchLanguage(code: "tr-TR",  label: "Turkish"),
        SearchLanguage(code: "ar-SA",  label: "Arabic"),
        SearchLanguage(code: "ja-JP",  label: "Japanese"),
        SearchLanguage(code: "ko-KR",  label: "Korean"),
        SearchLanguage(code: "zh-CN",  label: "Chinese (Simplified)"),
        SearchLanguage(code: "zh-TW",  label: "Chinese (Traditional)"),
        SearchLanguage(code: "hi",     label: "Hindi"),
        SearchLanguage(code: "id-ID",  label: "Indonesian"),
        SearchLanguage(code: "uk",     label: "Ukrainian"),
        SearchLanguage(code: "cs-CZ",  label: "Czech"),
        SearchLanguage(code: "ro-RO",  label: "Romanian"),
        SearchLanguage(code: "hu-HU",  label: "Hungarian"),
        SearchLanguage(code: "el-GR",  label: "Greek"),
        SearchLanguage(code: "th-TH",  label: "Thai"),
        SearchLanguage(code: "vi",     label: "Vietnamese"),
    ]
}
