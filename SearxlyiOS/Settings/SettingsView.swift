//
//  SettingsView.swift
//  SearxlyiOS
//
//  Chrome-style settings: pure black canvas, soft rounded groups, monochrome SF Symbol rows,
//  close control at the top. Fully localized — no hard-coded English chrome.
//

import SwiftUI
import WebKit

// MARK: - Root

struct SettingsView: View {
    @Bindable private var shields = ShieldSettings.shared
    @Environment(\.dismiss) private var dismiss
    private var locale = AppLocale.shared
    private var defaultBrowser = DefaultBrowser.shared

    var body: some View {
        let _ = locale.languageCode
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // ── General ──
                    settingsGroup {
                        settingsLink(icon: "magnifyingglass", title: L("Search")) { SearchSettingsPane() }
                        groupDivider
                        settingsLink(icon: "globe", title: L("Language")) { LanguagePane() }
                        groupDivider
                        settingsLink(icon: "textformat.size", title: L("Appearance")) { AppearancePane() }
                        groupDivider
                        settingsLink(icon: "square.on.square", title: L("Tabs")) { TabsSettingsPane() }
                        groupDivider
                        settingsLink(icon: "play.rectangle", title: L("Media")) { MediaSettingsPane() }
                        groupDivider
                        settingsLink(icon: "arrow.triangle.2.circlepath", title: L("Sync")) { SyncView() }
                        // Hidden until Apple grants the browser entitlement — without it Searxly
                        // isn't offered in Settings ▸ Default Apps, so the row would lead nowhere.
                        if defaultBrowser.status != .unavailable {
                            groupDivider
                            Button {
                                defaultBrowser.openSystemSettings()
                            } label: {
                                settingsRow(
                                    icon: "safari",
                                    title: L("Default Browser"),
                                    trailing: defaultBrowser.status == .isDefault ? L("Searxly") : L("Not set"),
                                    trailingSystemImage: "arrow.up.right"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // ── Privacy & protection ──
                    settingsGroup {
                        settingsLink(icon: "shield.fill", title: L("Shields")) { ShieldsPane() }
                        groupDivider
                        settingsLink(icon: "hand.raised.fill", title: L("Privacy")) { PrivacyPane() }
                        groupDivider
                        settingsLink(icon: "faceid", title: L("Security")) { SecurityPane() }
                        groupDivider
                        settingsLink(icon: "chart.bar.fill", title: L("Privacy Report"),
                                     trailing: shields.lifetimeTrackersBlocked.formatted()) {
                            PrivacyReportView()
                        }
                    }

                    // ── Intelligence ──
                    settingsGroup {
                        settingsLink(icon: "apple.intelligence", title: L("Intelligence")) { IntelligencePane() }
                    }

                    // ── About ──
                    settingsGroup {
                        settingsRow(icon: "info.circle", title: L("Version"), trailing: appVersion)
                        groupDivider
                        Link(destination: URL(string: "https://searxly.app")!) {
                            settingsRow(icon: "safari", title: "searxly.app",
                                        trailingSystemImage: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                        groupDivider
                        settingsLink(icon: "doc.text", title: L("Open-Source Licenses")) { LicensesPane() }
                        groupDivider
                        Button {
                            dismiss()
                            // Defer so the sheet finishes dismissing before the cinema covers the root.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                OnboardingGate.requestReplay()
                            }
                        } label: {
                            settingsRow(icon: "sparkles.rectangle.stack",
                                        title: L("Replay onboarding"),
                                        trailingSystemImage: "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }

                    // ── Legal ──
                    settingsGroup {
                        settingsLink(icon: "lock.shield", title: L("Privacy Policy")) {
                            LegalPane(
                                title: L("Privacy Policy"),
                                markdown: LegalText.privacyPolicy,
                                onlineURL: URL(string: "https://searxly.app/privacy")!
                            )
                        }
                        groupDivider
                        settingsLink(icon: "doc.plaintext", title: L("Terms of Service")) {
                            LegalPane(
                                title: L("Terms of Service"),
                                markdown: LegalText.termsOfService,
                                onlineURL: URL(string: "https://searxly.app/terms")!
                            )
                        }
                    }

                    Text(L("Private search & browsing"))
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(Brand.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(Brand.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Brand.surfaceHi))
                    }
                    .accessibilityLabel(L("Done"))
                }
            }
            .tint(Brand.text)
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Chrome-style building blocks

private func settingsGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) {
        content()
    }
    .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.06))
    )
    .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Brand.hairline, lineWidth: 0.5)
    )
}

private var groupDivider: some View {
    Rectangle()
        .fill(Brand.hairline)
        .frame(height: 0.5)
        .padding(.leading, 52)
}

private func settingsLink<Destination: View>(
    icon: String,
    title: String,
    trailing: String? = nil,
    @ViewBuilder destination: @escaping () -> Destination
) -> some View {
    NavigationLink {
        destination()
    } label: {
        settingsRow(icon: icon, title: title, trailing: trailing, trailingSystemImage: "chevron.right")
    }
    .buttonStyle(.plain)
}

private func settingsRow(
    icon: String,
    title: String,
    trailing: String? = nil,
    trailingSystemImage: String? = nil
) -> some View {
    HStack(spacing: 14) {
        Image(systemName: icon)
            .scaledFont(size: 17, weight: .regular)
            .foregroundStyle(Brand.textSecondary)
            .frame(width: 26, alignment: .center)
        Text(title)
            .scaledFont(size: 16, weight: .regular)
            .foregroundStyle(Brand.text)
            .lineLimit(1)
        Spacer(minLength: 8)
        if let trailing {
            Text(trailing)
                .scaledFont(size: 15)
                .foregroundStyle(Brand.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        if let trailingSystemImage {
            Image(systemName: trailingSystemImage)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Brand.textTertiary.opacity(0.7))
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
}

// Shared pane chrome
private extension View {
    func settingsPane(_ title: String) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .tint(Brand.text)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Language (dedicated, rich)

private struct LanguagePane: View {
    @Bindable private var settings = SearchSettings.shared
    @Bindable private var locale = AppLocale.shared

    var body: some View {
        let _ = locale.languageCode
        List {
            Section {
                LabeledContent(L("System language")) {
                    Text(AppLocale.nativeLanguageName(for: AppLocale.systemLanguageCode))
                        .foregroundStyle(Brand.textSecondary)
                }
                LabeledContent(L("Active language")) {
                    Text(AppLocale.nativeLanguageName(for: locale.languageCode))
                        .foregroundStyle(Brand.textSecondary)
                }
            } header: {
                Text(L("Status"))
            } footer: {
                Text(L("By default Searxly follows your iPhone language for the interface, search, knowledge cards, and on-device AI. Override only if you want something different."))
            }

            Section {
                Picker(L("App Language"), selection: $locale.override) {
                    Text(L("System")).tag("")
                    ForEach(AppLocale.supported) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
            } header: {
                Text(L("Interface"))
            } footer: {
                Text(L("UI chrome translations ship for English, Français, Español, and Deutsch. Every other language still drives content correctly."))
            }

            Section {
                Picker(L("Search Results"), selection: $settings.language) {
                    Text(L("Automatic")).tag("auto")
                    ForEach(AppLocale.supported) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
            } header: {
                Text(L("Search & content"))
            } footer: {
                Text(L("Controls SearXNG results language, Wikipedia/Grokipedia cards, Accept-Language, and AI fallback language. Automatic follows App Language (and thus System when App Language is System)."))
            }

            Section {
                LabeledContent(L("Wikipedia language")) {
                    Text(settings.resolvedWikipediaLanguage)
                        .foregroundStyle(Brand.textSecondary)
                        .monospaced()
                }
                LabeledContent(L("Search language code")) {
                    Text(settings.resolvedContentLanguage)
                        .foregroundStyle(Brand.textSecondary)
                        .monospaced()
                }
            } header: {
                Text(L("Resolved"))
            }
        }
        .settingsPane(L("Language"))
    }
}

// MARK: - Search

private struct SearchSettingsPane: View {
    @Bindable private var settings = SearchSettings.shared
    @Bindable private var shields = ShieldSettings.shared
    @Bindable private var contentSafety = SearchContentSafety.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Safe Search"), selection: $settings.safeSearch) {
                    ForEach(SafeSearch.allCases) { Text($0.label).tag($0) }
                }
                Toggle(L("Content Filter"), isOn: $contentSafety.isEnabled).tint(.green)
                Toggle(L("Online Suggestions"), isOn: $shields.onlineSuggestions).tint(.green)
                Toggle(L("Site Icons in Results"), isOn: $shields.resultSiteIcons).tint(.green)
                Toggle(L("Knowledge Cards"), isOn: $shields.knowledgeCards).tint(.green)
                if shields.knowledgeCards {
                    Toggle(L("Prefer Grokipedia"), isOn: $shields.preferGrokipedia).tint(.green)
                }
            } header: {
                Text(L("Search"))
            } footer: {
                Text(L("Safe Search is applied by your search instance. Content Filter additionally screens results on this device with a bundled open-source blocklist — nothing is looked up online. Online Suggestions sends what you type to your instance for completions (off by default). Site Icons fetches each result site's icon anonymously. Knowledge Cards summarize entity searches — Grokipedia first, Wikipedia as fallback (never in private tabs)."))
            }

            Section {
                Toggle(L("News on Start Page"), isOn: $shields.newsHomeFeed).tint(.green)
                NavigationLink(L("Topics")) { NewsTopicsPane() }
                    .disabled(!shields.newsHomeFeed)
            } header: {
                Text(L("News"))
            } footer: {
                Text(L("Scroll down from the start page for a topic-by-topic headline feed pulled from your search instance. Headlines are kept in memory only — never saved to disk — and the feed never appears in private tabs."))
            }

            if SearchSettings.allowsCustomInstance {
                Section {
                    TextField(L("Search instance URL"), text: $settings.instanceURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button(L("Reset to default")) { settings.instanceURL = SearchSettings.defaultInstance }
                        .foregroundStyle(.red)
                        .disabled(settings.isUsingDefault)
                } header: {
                    Text(L("Advanced — search instance"))
                } footer: {
                    Text(settings.isUsingDefault
                         ? L("Using the Searxly search instance (search.searxly.app). You can point this at any SearXNG instance with the JSON API enabled — including one you self-host.")
                         : String(format: L("Searches use %@."), settings.base))
                }
            }
        }
        .settingsPane(L("Search"))
    }
}

private struct NewsTopicsPane: View {
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(HomeNewsFeed.topics) { topic in
                    Toggle(isOn: visibility(topic.id)) {
                        Label(L(topic.label), systemImage: topic.systemIcon)
                    }
                    .tint(.green)
                }
            } footer: {
                Text(L("Turn topics off to hide them from the start-page news feed. The top-story banner only draws from the hard-news topics you keep on."))
            }
        }
        .settingsPane(L("Topics"))
    }

    private func visibility(_ id: String) -> Binding<Bool> {
        Binding(
            get: { shields.isNewsTopicVisible(id) },
            set: { shields.setNewsTopic(id, visible: $0) }
        )
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Bindable private var appearance = AppearanceSettings.shared
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Text Size"), selection: $appearance.textSize) {
                    ForEach(AppTextSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(Brand.surfaceHi).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Result title preview"))
                            .font(.system(size: 18 * appearance.textScale, weight: .semibold))
                        Text(L("This is how result snippets will read at the selected size."))
                            .font(.system(size: 14 * appearance.textScale))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text(L("Text Size"))
            } footer: {
                Text(L("Applies to Searxly's interface — results, cards, suggestions. Web page text size is set per site from the lock icon on the page."))
            }

            Section {
                Toggle(L("Dark Mode for Websites"), isOn: $shields.websiteDarkMode).tint(.green)
            } footer: {
                Text(L("Darkens light websites; pages that are already dark are left alone. Runs entirely on this device. New tabs pick it up immediately — reload open tabs to apply."))
            }
        }
        .settingsPane(L("Appearance"))
    }
}

// MARK: - Tabs

private struct TabsSettingsPane: View {
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Restore Tabs at Launch"), isOn: $shields.restoreTabs).tint(.green)
            } footer: {
                Text(L("Reopens your last normal tabs encrypted on disk. Private tabs are never restored."))
            }
        }
        .settingsPane(L("Tabs"))
    }
}

// MARK: - Media

private struct MediaSettingsPane: View {
    @Bindable private var settings = SearchSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Keep Playing in Background"), isOn: $settings.backgroundMedia).tint(.green)
            } header: {
                Text(L("Media"))
            } footer: {
                Text(L("Lets audio and video carry on after you leave Searxly or lock the screen — the tab you were watching only. Other tabs are still paused, so a page playing in the background can't drain your battery. Media will also ignore the ring/silent switch while it plays."))
            }

            Section {
                Text(L("Use Picture in Picture from the ⋯ menu on any page with a video. It works even on sites that hide their own button, and the video keeps playing while you browse elsewhere."))
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
            } header: {
                Text(L("Picture in Picture"))
            }
        }
        .settingsPane(L("Media"))
    }
}

// MARK: - Shields

private struct ShieldsPane: View {
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Block Ads & Trackers"), isOn: $shields.blockAdsAndTrackers).tint(.green)
                Toggle(L("YouTube Ad Blocking"), isOn: $shields.youtubeAdBlock).tint(.green)
                    .disabled(!shields.blockAdsAndTrackers)
                Toggle(L("Fingerprint Protection"), isOn: $shields.fingerprintProtection).tint(.green)
                Toggle(L("Do-Not-Sell Signal (GPC)"), isOn: $shields.gpcSignal).tint(.green)
            } header: {
                Text(L("Shields"))
            } footer: {
                Text(L("Ad & tracker blocking uses bundled uBlock Origin filter lists (EasyList, EasyPrivacy, Peter Lowe, uBO) — fully local, nothing is downloaded. Fingerprint Protection randomizes canvas and audio readouts each session. GPC tells sites not to sell or share your data. Changes apply to new tabs."))
            }

            Section {
                Toggle(L("Distraction-Free YouTube"), isOn: $shields.youtubeDistractionFree).tint(.green)
            } footer: {
                Text(L("Hides Shorts, comments, and recommended videos on YouTube — including the suggestions that cover the end of a video. Your subscriptions, search, and the home feed are untouched. Applies to new tabs, and to open tabs after a reload."))
            }

            Section {
                Toggle(L("Hide Cookie Banners"), isOn: $shields.blockCookieBanners).tint(.green)
            } footer: {
                Text(L("Removes cookie-consent pop-ups and the scroll locks they add. Never clicks “Accept” for you — your Do-Not-Sell (GPC) signal already states your preference."))
            }

            Section {
                Toggle(L("HTTPS-Only"), isOn: $shields.httpsOnly).tint(.green)
                Toggle(L("Remove Tracking Parameters"), isOn: $shields.stripTrackingParams).tint(.green)
                Toggle(L("Skip AMP Pages"), isOn: $shields.deAMP).tint(.green)
            } header: {
                Text(L("Connections & Links"))
            } footer: {
                Text(L("HTTPS-Only upgrades insecure links and asks before ever loading plain HTTP. Link cleaning strips identifiers like utm_ and fbclid. AMP pages are replaced by the publisher's real page."))
            }

            if !shields.shieldsOffHosts.isEmpty {
                Section {
                    ForEach(shields.shieldsOffHosts.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button(L("Raise")) { shields.setShields(true, forHost: host) }
                                .font(.subheadline)
                        }
                    }
                    Button(L("Raise Shields Everywhere")) { shields.clearShieldsExceptions() }
                } header: {
                    Text(L("Sites with Lowered Shields"))
                } footer: {
                    Text(L("Ad & tracker blocking is reduced on these sites. Reload their tabs after raising."))
                }
            }
        }
        .settingsPane(L("Shields"))
    }
}

// MARK: - Privacy & Data

private struct PrivacyPane: View {
    @Bindable private var settings = SearchSettings.shared
    @Bindable private var shields = ShieldSettings.shared
    @State private var clearedData = false
    @State private var clearedHistory = false

    var body: some View {
        Form {
            Section {
                Toggle(L("Save History"), isOn: $settings.saveHistory).tint(.green)
                Toggle(L("Block Pop-ups"), isOn: $settings.blockPopups).tint(.green)
                Toggle(L("Clear Website Data on Exit"), isOn: $shields.clearDataOnExit).tint(.green)
            } header: {
                Text(L("Privacy"))
            } footer: {
                Text(L("History stays on this device only, encrypted at rest. Pop-up blocking stops sites opening extra windows. Clear on Exit wipes cookies and site data from previous sessions when Searxly starts, and disables tab restore."))
            }

            Section(L("Data")) {
                Button(clearedHistory ? L("History Cleared") : L("Clear History")) {
                    LibraryStore.shared.clearHistory()
                    clearedHistory = true
                }
                .disabled(clearedHistory || LibraryStore.shared.history.isEmpty)

                Button(clearedData ? L("Website Data Cleared") : L("Clear Website Data")) {
                    WKWebsiteDataStore.default().removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        modifiedSince: .distantPast
                    ) {}
                    // Remembered per-site preferences (desktop mode, text zoom) are a host list —
                    // browsing history by another name — so clearing site data clears them too.
                    PerSiteSettings.shared.clearAll()
                    clearedData = true
                }
                .disabled(clearedData)
            }
        }
        .settingsPane(L("Privacy"))
    }
}

// MARK: - Security

private struct SecurityPane: View {
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("App Lock"), isOn: appLockBinding).tint(.green)
                    .disabled(!AppLockManager.deviceSupportsAuthentication)
            } header: {
                Text(L("Security"))
            } footer: {
                if AppLockManager.deviceSupportsAuthentication {
                    Text(String(format: L("Require %@ to open Searxly."), AppLockManager.shared.biometryLabel))
                } else {
                    Text(L("App Lock needs Face ID, Touch ID, or a device passcode."))
                }
            }

            Section {
                Toggle(L("Lock Private Tabs"), isOn: $shields.lockPrivateTabs).tint(.green)
                    .disabled(!AppLockManager.deviceSupportsAuthentication)
            } footer: {
                Text(String(format: L("Require %@ to reveal private tabs after you leave Searxly. Their contents stay hidden in the tab switcher until you unlock."), AppLockManager.shared.biometryLabel))
            }
        }
        .settingsPane(L("Security"))
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { AppLockManager.shared.isEnabled },
            set: { newValue in Task { await AppLockManager.shared.setEnabled(newValue) } }
        )
    }
}

// MARK: - Intelligence

private struct IntelligencePane: View {
    @Bindable private var shields = ShieldSettings.shared
    @State private var availability = PageIntelligence.availability

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Apple Intelligence"), value: L(availability.label))

                if availability == .downloading {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Brand.text)
                        Text(L("iOS is downloading Apple's on-device model in the background. It goes fastest on Wi-Fi with the iPhone charging. This screen updates automatically."))
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if availability == .notEnabled {
                    Text(L("Turn on Apple Intelligence in Settings ▸ Apple Intelligence & Siri, then come back here."))
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Intelligence"))
            } footer: {
                Text(L("Searxly's AI runs entirely on this device with Apple Intelligence — nothing is sent to any server, ever, which is also why it works in private tabs."))
            }
            .task {
                PageIntelligence.requestModelIfNeeded()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    let now = PageIntelligence.availability
                    if now != availability {
                        availability = now
                        if now == .downloading { PageIntelligence.requestModelIfNeeded() }
                    }
                }
            }

            Section {
                Toggle(L("AI Overview"), isOn: $shields.aiOverview).tint(.green)
                    .disabled(availability != .available)
            } footer: {
                Text(L("A short answer above web results, grounded strictly in the result snippets with cited sources and follow-up searches. Generates automatically for question-like searches; other searches get a Generate button."))
            }

            Section {
                LabeledContent(L("Summarize Page"), value: "⋯ \(L("menu"))")
                LabeledContent(L("Ask About This Page"), value: "⋯ \(L("menu"))")
                LabeledContent(L("Find on Page…"), value: "⌘F · ⋯")
                LabeledContent(L("Reader"), value: "⋯ \(L("menu"))")
            } footer: {
                Text(L("Page tools appear in the ⋯ menu while browsing: Find highlights matches with the system navigator, Reader extracts a clean article, Summarize and Ask use only the page text on-device."))
            }
        }
        .settingsPane(L("Intelligence"))
    }
}

// MARK: - Open-Source Licenses

private struct LicensesPane: View {
    private let sourceURL = URL(string: "https://github.com/Searxly/Searxly-source-code")!
    private let upstreamURL = URL(string: "https://github.com/searxng/searxng")!

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SearXNG")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(Brand.text)
                    Text(L("Private search is powered by SearXNG, an open-source metasearch engine, licensed under the GNU AGPL v3.0."))
                        .scaledFont(size: 13)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                Link(L("View source code"), destination: sourceURL)
                Link(L("SearXNG project"), destination: upstreamURL)
            } header: {
                Text(L("Search Engine"))
            } footer: {
                Text(L("Searxly's changes to SearXNG (its theme and configuration) are published at the source link above under the same AGPL-3.0 license — you're free to download, run, and redistribute them."))
            }
        }
        .settingsPane(L("Open-Source Licenses"))
    }
}

// MARK: - Legal (Privacy Policy & Terms)

private struct LegalPane: View {
    let title: String
    let markdown: String
    let onlineURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(String(format: L("Last updated: %@"), LegalText.lastUpdated))
                        .scaledFont(size: 12)
                        .foregroundStyle(Brand.textTertiary)
                    Spacer(minLength: 8)
                    Link(destination: onlineURL) {
                        HStack(spacing: 4) {
                            Text(L("View online"))
                            Image(systemName: "arrow.up.right")
                        }
                        .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(Brand.textSecondary)
                }
                .padding(.bottom, 2)

                LegalMarkdownText(markdown: markdown)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
        .preferredColorScheme(.dark)
    }
}

private struct LegalMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(LegalText.parse(markdown)) { block in
                switch block {
                case .lead(let text):
                    LegalText.inline(text)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                case .heading(let text):
                    Text(text)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Brand.text)
                        .padding(.top, 8)
                case .paragraph(let text):
                    LegalText.inline(text)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(Brand.textTertiary)
                        LegalText.inline(text)
                            .scaledFont(size: 13)
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .tint(Brand.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
/// Canonical Privacy Policy and Terms text for iOS.
///
/// IMPORTANT: this must stay identical to the macOS copy in
/// Searxly/Views/Features/Settings/LegalDocuments.swift and to the site's privacy.html / terms.html.
/// The two Swift targets don't share a module, so the text is duplicated on purpose — change all
/// copies together.
private enum LegalText {
    static let lastUpdated = "July 2026"

    enum Block: Identifiable {
        case lead(String), heading(String), paragraph(String), bullet(String)
        var id: String {
            switch self {
            case .lead(let s):      return "l:\(s)"
            case .heading(let s):   return "h:\(s)"
            case .paragraph(let s): return "p:\(s)"
            case .bullet(let s):    return "b:\(s)"
            }
        }
    }

    static func parse(_ markdown: String) -> [Block] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("> ")  { return .lead(String(line.dropFirst(2))) }
            if line.hasPrefix("- ")  { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    static func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    static let privacyPolicy = """
    > The short version: we collect almost nothing, and we tell you exactly what the few exceptions are. This is plain language, not boilerplate — if it ever conflicts with how Searxly actually behaves, the product's behavior is the source of truth and we'll fix the wording.

    ## 1. Our approach
    Searxly is private by architecture, not by promise. There are no accounts, no analytics SDKs, and no telemetry in the app. We don't build an ad profile of you, and we have no business model that depends on your data. Most of what the app does happens entirely on your own device, where we never see it. Where a feature does touch the network, this policy names it and says what it reveals.

    ## 2. What stays on your device
    The following is stored on your device and is never sent to a Searxly server:
    - **Browsing history & bookmarks** — kept locally. You can turn history off, and turn on encryption-at-rest (CryptoKit + your device keychain) for stored data.
    - **Passwords** — the optional password vault (macOS) is local and encrypted; entries are never synced to us.
    - **Wallet keys** — on macOS, wallet keys are generated from a standard recovery phrase and encrypted on your device. They never leave it; we cannot access your funds, see your phrase, or sign on your behalf.
    - **Search on macOS** — your searches run through a search engine on your own Mac (see section 3).
    - **Agentic Tools (macOS)** — the local tool server your own AI can connect to runs entirely on your Mac, and is off by default (see section 4).

    ## 3. Search & address-bar suggestions
    How search reaches the web depends on your platform:
    - **On macOS**, Searxly runs a SearXNG search engine locally on your Mac. Your query is aggregated on-device, and the engine fetches results from upstream sources directly from your machine (or through Tor in Searxly Maximum). We do not receive, store, or log your searches.
    - **On iPhone & iPad**, the search engine can't run on the device, so the app searches through our hosted instance at search.searxly.app. Your query and IP reach that server the same way any request reaches any website. We run SearXNG, which is built not to keep search logs or user profiles — we don't associate queries with your identity, build ad profiles from them, or sell them. The server keeps only minimal, short-lived operational data (as any server does) to run the service and prevent abuse.
    - **Address-bar suggestions** — as you type, search-query completions are fetched from your configured search instance: on macOS that's your local engine, so they never leave your Mac; if you set a remote instance (or on iPhone & iPad, where "Online Suggestions" is off by default), they're sent there. There's no third-party autocomplete, and website/history suggestions are always computed locally.

    ## 4. On-device AI & Agentic Tools
    Searxly's own AI features run on your device, not in a Searxly cloud:
    - **On iPhone & iPad**, optional AI features — a short AI Overview above results, page summaries, and "ask about this page" — run entirely on-device using Apple Intelligence. Nothing is sent to any server, which is why they also work in private tabs. (Page translation likewise uses Apple's on-device translation.)
    - **On macOS**, Searxly has no built-in AI assistant. Instead it exposes its private browsing as tools your own local AI can call over the Model Context Protocol, through a small server that is off until you turn it on, bound to loopback, and protected by a token. Tool calls run locally — private search routes only through your own engine, and page reads or browser actions happen on your device — and every call is written to an activity log you can read. If you connect a cloud model yourself, whatever your client sends to that provider is between you and them; Searxly still runs the tools locally and sends nothing itself.

    ## 5. Safe-browsing warning
    Searxly can warn you before a known-malicious or deceptive site. The check runs against a blocklist bundled inside the app, entirely on your device — deliberately not Google Safe Browsing, which would send every address you visit to a third party. Nothing about the sites you visit leaves your device. It's on by default, and you can turn it off.

    ## 6. VPN (macOS)
    Searxly's base edition includes an optional managed VPN. When you turn it on, your internet traffic is routed through our VPN server before it reaches the sites you visit — so that server necessarily carries your traffic in transit. We operate it on a no-logs basis: we don't keep records of the sites you visit through the VPN. The server processes only the minimal connection data needed to run the service and prevent abuse. Access can be gated by a pass — connecting proves a signature from your wallet and an on-chain check, which our gateway sees and uses only to verify access, not to profile you.

    You can also pay for a pass by card. Card payments run on Stripe's hosted checkout — Searxly never sees or stores your card number. Stripe processes the payment details and the email you give it for a receipt as an independent controller under its own privacy policy; we receive only confirmation that a payment succeeded, so we can activate your pass. Paying in crypto involves no card and no payment processor, and is the more private option.

    ## 7. Wallet & on-chain features (macOS)
    If you use the built-in wallet, your keys stay on your device (see section 2). To function, it reads public information and uses a few third parties:
    - **Blockchain nodes (Base RPC)** — to read balances and broadcast transactions you approve, through public Base RPC providers. Like any on-chain request, they see the request and your IP.
    - **Transaction history** — fetched from a public block-explorer API (Etherscan); it sees the address you're viewing and your IP.
    - **Price feeds** (CoinGecko, GeckoTerminal, DexScreener) — for coin prices, charts, and coin logos. These are looked up by public contract address only.
    - **Optional name resolution** — if you turn on ENS / Basenames, `.eth` and Base names are resolved through a public Ethereum/Base RPC.
    - **Swaps** — swaps require your own 0x API key, and the request goes straight from your Mac to 0x. No Searxly server sits in the swap: we never see your address, the pair, or the amount, and we never relay or route the trade. The transaction 0x returns is signed on your device by you.
    We never custody your funds, act as a broker or exchange, or sign on your behalf. On-chain swaps carry a small fee, described in our Terms.

    ## 8. Feedback you send us (macOS)
    If you use in-app Feedback, or submit a knowledge-panel correction, the message you write is delivered to our team channel (through a webhook to Discord, which processes it as our messaging tool). We receive only what you choose to type, plus any minimal context you include. It's entirely optional, and only ever sent when you press send.

    ## 9. App updates (macOS)
    Searxly checks for updates by requesting our update feed from searxly.app. That request reveals your IP and current version to the host, like any web request. Updates are cryptographically signed and verified before they install. In Searxly Maximum the update check is fetched over Tor (and can use an .onion feed), so even the version check doesn't reveal your IP.

    ## 10. Normal browsing requests
    Searxly is a web browser, so when you open a page or load a result's favicon, thumbnail, or a knowledge-card source (e.g. Grokipedia or Wikipedia), your device contacts those third-party sites directly — exactly as any browser does. Those servers see a normal request and your IP. Built-in ad & tracker blocking reduces this; we don't sit in the middle of it or log it.

    ## 11. This website
    The searxly.app site is static and ships no tracking scripts and no advertising cookies. Your web host may keep standard server access logs (e.g. IP, user-agent) for security and operations, as is normal for any website.

    ## 12. Editions & Searxly Maximum licences
    Searxly Maximum is a paid edition, built to run locally: it has no managed VPN, no wallet, no Local Pack, and no feedback webhook. Its search runs locally and can route through Tor, and its bundled Tor runtime is signature-verified at every launch.

    **Activating your licence is the one and only time Maximum contacts us.** When you enter your licence key, the app sends us that key together with a **one-way fingerprint of your Mac's hardware ID** — a salted hash, so we never receive the ID itself — and we tie your licence to that one machine. That request does not include your name, your email, or anything about your browsing, and **the app never contacts us again afterwards**: every later check happens on your Mac, offline, with no network at all.

    We store that fingerprint against your licence, plus a receipt of when your key was issued and emailed. We keep both for as long as your licence is valid — and because Maximum licences never expire, that means indefinitely. We need them to move your licence to a new Mac, to send you your key again if you lose it, and to prove we delivered what you paid for. The lawful basis is performance of our contract with you (Article 6(1)(b) GDPR).

    We treat that fingerprint as personal data: it is **pseudonymous, not anonymous**, because we can link it to your purchase and therefore to the email address Stripe holds for you. You can ask for a copy of it, or ask us to erase it — though erasing it means we can no longer move your licence to another Mac or re-send your key.

    ## 14. What we never do
    We don't sell, rent, or share your data with advertisers or data brokers — ever. We don't run analytics or telemetry, and we don't build a profile of you.

    ## 15. Data retention
    On-device data lives on your device for as long as you keep it, and clears when you delete it, run a panic-wipe, or enable strict privacy mode. There are no server-side accounts or records to retain. The limited server touch-points above (our search instance, the VPN/gateway, Local Pack, and feedback you send) keep only minimal, short-lived operational data as described.

    **One thing we keep indefinitely:** if you buy Searxly Maximum, the activation record and delivery receipt for your licence (see section 13). A Maximum licence never expires, so those records have to outlive any fixed retention window — without them we could not move your licence to a new Mac, re-send your key, or show that we delivered it. They contain no name, no address, and no browsing data: only your licence, a one-way fingerprint of the Mac it runs on, and the timestamps.

    ## 16. Your controls & rights
    - Turn history off, or encrypt stored data at rest.
    - Keep Agentic Tools off entirely, or local-only, and require confirmation for any tool that touches the network.
    - Use panic-wipe or strict privacy mode to clear local data instantly.
    Because we hold almost nothing about you, you control your own data directly on your device. For the limited server touch-points, you can contact us to ask what we hold or request deletion. If you're in the EU/EEA or the UK, you keep your local data-protection rights, including access and erasure.

    ## 17. Children
    Searxly is not directed to children, and any crypto activity is intended for adults. Age and legal requirements for crypto vary by region — please don't route around them.

    ## 18. Who we are & contact
    Searxly is an independent project operated by its developer. For questions, security reports, or data requests, reach us through the channels below. These are the only official channels; anything else claiming to be Searxly isn't:
    - Support — [support.searxly.app](https://support.searxly.app), or email [support@searxly.app](mailto:support@searxly.app)
    - Email (privacy & data requests only) — [privacy@searxly.app](mailto:privacy@searxly.app)
    - X — [@Searxly](https://x.com/Searxly)
    - Telegram channel — [t.me/searxlyapp](https://t.me/searxlyapp)
    - Telegram community — [t.me/searxlycom](https://t.me/searxlycom)
    - Discord — [discord.gg/YNNgTkNAXD](https://discord.gg/YNNgTkNAXD)
    - Source code — [github.com/searxly/Searxly-source-code](https://github.com/searxly/Searxly-source-code)

    ## 19. Changes
    If this policy changes, we'll update the date above and post material changes on our official channels. We'll keep it short and honest.
    """

    static let termsOfService = """
    > The short version: Searxly is a free tool we give you as-is. There are no accounts, your keys and your data are yours, and nothing here is financial advice. By downloading, installing, or using Searxly (the "app") or this website, you agree to these terms. If you don't agree, please don't use it.

    ## 1. What Searxly is
    Searxly is a private browser. On macOS it runs a search engine locally on your Mac and adds optional privacy tooling and an optional self-custody wallet; on iPhone & iPad it's a private-search browser that searches through our hosted instance. It's built to be private by architecture: no accounts, no telemetry, and most of what it does happens on your own device. How data is handled is described in our Privacy Policy, which forms part of these terms.

    ## 2. Your licence to use it
    The Searxly browser is provided free of charge for personal use, and we grant you a personal, non-exclusive, non-transferable licence to install and run it on your own devices. Searxly Maximum is a separate, paid edition sold under section 7, and its licence covers one Mac. In either case you may not resell it, remove or alter its notices, or misrepresent it as your own. Portions of Searxly are open source and governed by their own licences — for example the SearXNG search engine, provided under the GNU AGPL v3.0, whose source and our changes to it we publish and offer to you.

    ## 3. No accounts
    Using the browser and search requires no account, sign-up, or identification, and that is true of Searxly Maximum too — a licence key is not an account, and we never ask you to log in. Some optional extras (the paid Maximum edition, or the VPN) have their own additional terms in the sections below, which we make clear at the point you choose to use them. Maximum does check your licence key with us once, when you first activate it (section 7); after that it runs entirely offline.

    ## 4. The self-custody wallet (macOS)
    If you use the built-in wallet, it is fully self-custodial. This has real consequences you must understand and accept:
    - Your keys and recovery phrase are generated and stored on your device. We never receive, hold, or have any way to recover them.
    - If you lose your recovery phrase or device, or send funds to the wrong address, we can't reverse it or restore access. You are solely responsible for backing up your phrase and securing your device.
    - We don't custody funds, act as a broker or exchange, or ever take control of your assets or sign transactions on your behalf.
    - On-chain transactions are irreversible and may incur network fees outside our control.

    ## 5. Fees for on-chain features (macOS)
    In-app token swaps carry a small protocol fee — currently 0.65% — which is routed to the project treasury. It's collected on-chain as part of the swap (through the 0x settlement contract), with no separate transaction: the fee is a parameter on the quote your own 0x key fetches, so we collect it without ever handling, routing, or intermediating your trade. Blockchain network (gas) fees are separate and outside our control. The fee is shown in the swap screen before you confirm, and may change over time.

    ## 6. VPN (macOS)
    The optional managed VPN is provided as-is, with no uptime or service-level guarantee. Access may be gated by a pass or a promotional grant. You must use it lawfully. We operate it on a no-logs basis, but no VPN can guarantee anonymity, and we may refuse, suspend, or decline to renew access to prevent abuse or to comply with the law.

    **Buying a pass.** A VPN pass is a one-off, time-boxed purchase — there is no subscription and nothing auto-renews; you choose to buy again to extend. You can pay by card (processed by Stripe on its hosted checkout — Searxly never sees your card details) or in USDC from the in-app wallet. The price is shown before you confirm.

    **Right of withdrawal & refunds.** A VPN pass is digital content and services that we begin supplying immediately. By buying a pass you expressly ask us to start it straight away and you acknowledge that, once it is active, you lose the 14-day right of withdrawal that would otherwise apply to a distance sale (Article L.221-28 of the French Consumer Code).

    **When we do refund: a pass that doesn't work.** That's the one case. If a pass you paid for never activates, or can't connect because of a fault on our side, open a ticket at [support.searxly.app](https://support.searxly.app) and tell us what happened — what you saw, and roughly when. We'll check it against our delivery records (we keep a receipt of exactly when your access certificate was issued) and either re-issue your pass or refund you. A pass that was delivered and working isn't refundable.

    **Paying in crypto is final.** Crypto payments settle on a public blockchain: they are irreversible, and we cannot reverse, cancel, or charge one back. You are responsible for sending the correct asset (USDC) on the correct network (Base) to the address the app shows you. **If you send to a wrong address, on the wrong network, or the wrong amount, those funds never reach us — we don't receive them, we can't recover them, and there is nothing for us to refund.** Check carefully before you confirm. And once a crypto-paid pass has been delivered it is not refundable, since you asked for it to start immediately.

    **Consumer mediation.** If you are a consumer and a complaint you raised with us directly isn't resolved within a reasonable time, you may refer the dispute, free of charge, to the consumer mediator we are registered with (Article L.612-1 of the French Consumer Code): CM2C — Centre de la Médiation de la Consommation de Conciliateurs de Justice. File online at https://www.cm2c.net/declarer-un-litige.php, or by post to CM2C, 49 rue de Ponthieu, 75008 Paris (tel. 01 89 47 00 14 · litiges@cm2c.net). Mediation is only available after you've first sent us a written complaint that went unresolved, and within one year of that complaint.

    ## 7. Searxly Maximum (macOS)
    Searxly Maximum is a paid edition of the browser. It is a **one-time purchase — there is no subscription** and nothing auto-renews. The price is shown before you confirm, and you pay **by card** (processed by Stripe on its hosted checkout — Searxly never sees your card details). Maximum is not sold for crypto.

    **What you get.** A licence key, emailed to you as soon as your payment goes through. It **never expires**. It activates Maximum on **one Mac**: when you enter your key, the app ties the licence to that machine. Reinstalling macOS on the same Mac is fine — the same key still works, as many times as you need. Moving to a *different* Mac needs us to move the licence for you: open a ticket at support.searxly.app and we'll do it.

    **Activation.** Entering your key is the one moment Maximum contacts us: the app sends your key and a one-way fingerprint of your Mac's hardware ID, so we can tie the licence to it. It sends nothing about you or your browsing, and never contacts us again afterwards. See our Privacy Policy for exactly what we store and for how long.

    **Your key is yours.** The licence is personal to you. You may not resell, publish, or share your key, or use it on more Macs than you bought it for.

    **Right of withdrawal & refunds.** A licence key is digital content that we supply immediately. By buying Maximum you **expressly ask us to send your key straight away** and you acknowledge that, **once it has been sent, you lose the 14-day right of withdrawal** that would otherwise apply to a distance sale (Article L.221-28 of the French Consumer Code). You confirm both of these with a tick box before you pay.

    **When we do refund: a licence that doesn't work.** That's the one case. If you paid and never received your key, or it won't activate because of a fault on our side, open a ticket at support.searxly.app and tell us what happened — what you saw, and roughly when. We'll check it against our delivery records (we keep a receipt of exactly when your key was issued and emailed) and either re-send it or refund you. A licence that was delivered and activates isn't refundable.

    **Consumer mediation.** If you are a consumer and a complaint you raised with us directly isn't resolved within a reasonable time, you may refer the dispute, free of charge, to the consumer mediator we are registered with (Article L.612-1 of the French Consumer Code): **CM2C** — Centre de la Médiation de la Consommation de Conciliateurs de Justice. File online at cm2c.net/declarer-un-litige.php, or by post to CM2C, 49 rue de Ponthieu, 75008 Paris (tel. 01 89 47 00 14 · litiges@cm2c.net). Mediation is only available after you've first sent us a written complaint that went unresolved, and within one year of that complaint.

    ## 8. Nothing here is financial advice
    Searxly, this website, and any prices, charts, or coin information shown are provided for information only and are not financial, investment, legal, or tax advice. Searxly does not issue, promote, or endorse any token. Crypto assets are volatile and can lose value. Do your own research, and only use funds you can afford to lose. The availability and legality of crypto features vary by region — it's your responsibility to comply with the laws that apply to you.

    ## 9. Acceptable use
    Searxly is a general-purpose browser and you're responsible for how you use it. Don't use it to break the law, infringe others' rights, attack or disrupt services, or circumvent security you're not authorised to bypass. You are responsible for the sites you visit and the content you access.

    ## 10. Third-party services & content
    As a browser, Searxly connects you to third-party websites, search sources, price feeds, blockchain nodes, and other services. We don't control those, aren't responsible for their content or availability, and their own terms and privacy practices apply when you use them. Any third-party trademarks are the property of their respective owners and are used for identification only.

    ## 11. As-is, no warranty
    Searxly is provided "as is" and "as available", without warranties of any kind, whether express or implied, including fitness for a particular purpose, merchantability, or non-infringement. We work hard to make it private and reliable, but we don't guarantee it will be uninterrupted, error-free, or that it will meet your specific needs. Privacy and security tools reduce risk; no tool can make you perfectly anonymous or secure.

    ## 12. Limitation of liability
    To the maximum extent permitted by law, Searxly and its contributors are not liable for any indirect, incidental, or consequential damages, or for lost profits, lost data, or lost crypto assets, arising from your use of (or inability to use) the app or website. Because the app is free and self-custodial, you accept that you use it at your own risk.

    ## 13. Changes to the app or these terms
    We may update, change, or discontinue features at any time, and we may update these terms. When we make material changes, we'll update the date above and post notice on our official channels. Continuing to use Searxly after a change means you accept the updated terms.

    ## 14. Governing law
    These terms are governed by the laws of France, without regard to conflict-of-laws rules. If you're a consumer in the EU/EEA or the UK, you keep the mandatory protections of the law of your home country, and nothing here limits rights that can't be limited by law.

    ## 15. Contact & official channels
    Questions about these terms? Reach us here. These are the only official channels; anything else claiming to be Searxly isn't:
    - Support (anything about the app, your pass, or a problem) — [support.searxly.app](https://support.searxly.app), or email [support@searxly.app](mailto:support@searxly.app)
    - Privacy & data requests only — [privacy@searxly.app](mailto:privacy@searxly.app)
    - X — [@Searxly](https://x.com/Searxly)
    - Telegram channel — [t.me/searxlyapp](https://t.me/searxlyapp)
    - Telegram community — [t.me/searxlycom](https://t.me/searxlycom)
    - Discord — [discord.gg/YNNgTkNAXD](https://discord.gg/YNNgTkNAXD)
    - Source code — [github.com/searxly/Searxly-source-code](https://github.com/searxly/Searxly-source-code)
    """
}
