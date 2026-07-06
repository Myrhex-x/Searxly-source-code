//
//  SettingsView.swift
//  SearxlyiOS
//
//  Settings, iOS-Settings style: a gear emblem header, then icon-chip rows leading to focused
//  panes — Search, Appearance, Shields, Privacy & Data, Security, Intelligence — plus the
//  Privacy Report and About. Monochrome throughout (brand rule: no colored icon chips).
//

import SwiftUI
import WebKit

struct SettingsView: View {
    @Bindable private var shields = ShieldSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .listRowBackground(Color.clear)
                }

                Section {
                    row(icon: "magnifyingglass", title: L("Search")) { SearchSettingsPane() }
                    row(icon: "textformat.size", title: L("Appearance")) { AppearancePane() }
                    row(icon: "shield.fill", title: L("Shields")) { ShieldsPane() }
                    row(icon: "hand.raised.fill", title: L("Privacy")) { PrivacyPane() }
                    row(icon: "faceid", title: L("Security")) { SecurityPane() }
                    row(icon: "arrow.triangle.2.circlepath", title: L("Sync")) { SyncView() }
                    row(icon: "sparkles", title: L("Intelligence")) { IntelligencePane() }
                }

                Section {
                    NavigationLink {
                        PrivacyReportView()
                    } label: {
                        HStack(spacing: 12) {
                            chip("chart.bar.fill")
                            Text(L("Privacy Report"))
                            Spacer()
                            Text(shields.lifetimeTrackersBlocked.formatted())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Section(L("About")) {
                    LabeledContent(L("Version"), value: appVersion)
                    Link("searxly.app", destination: URL(string: "https://searxly.app")!)
                }
            }
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .tint(Brand.text)
        }
    }

    /// The "actual settings logo": a monochrome gear emblem heading the page.
    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Brand.surfaceHi)
                    .frame(width: 74, height: 74)
                Circle()
                    .strokeBorder(Brand.hairline, lineWidth: 0.5)
                    .frame(width: 74, height: 74)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Brand.text)
            }
            Text("Searxly")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.text)
            Text(L("Private search & browsing"))
                .font(.system(size: 12))
                .foregroundStyle(Brand.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func row<Destination: View>(
        icon: String, title: String, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                chip(icon)
                Text(title)
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// Monochrome icon chip (the iOS-Settings row look, minus the colors).
private func chip(_ systemName: String) -> some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Brand.text)
        .frame(width: 30, height: 30)
        .overlay(
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.bg)
        )
}

// MARK: - Search

private struct SearchSettingsPane: View {
    @Bindable private var settings = SearchSettings.shared
    @Bindable private var shields = ShieldSettings.shared
    @Bindable private var locale = AppLocale.shared

    var body: some View {
        Form {
            Section {
                TextField("https://your-searxng-instance", text: $settings.instanceURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Reset to default") { settings.instanceURL = SearchSettings.defaultInstance }
                    .foregroundStyle(.red)
                    .disabled(settings.isUsingDefault)
            } header: {
                Text("Search instance")
            } footer: {
                if settings.isUsingDefault {
                    Text("Using the Searxly search instance (search.searxly.app). You can point this at any SearXNG instance with the JSON API enabled.")
                } else {
                    Text("Searches use \(settings.base).")
                }
            }

            Section {
                Picker(L("App Language"), selection: $locale.override) {
                    Text(L("System")).tag("")
                    ForEach(AppLocale.supported) { Text($0.label).tag($0.code) }
                }
                Picker(L("Search Results"), selection: $settings.language) {
                    Text(L("Automatic")).tag("auto")
                    ForEach(AppLocale.supported) { Text($0.label).tag($0.code) }
                }
            } header: {
                Text(L("Language"))
            } footer: {
                Text("App and search languages are independent — e.g. English interface with French results. Interface translations cover English, Français, Español, and Deutsch for now; system controls follow after a relaunch.")
            }

            Section {
                Picker(L("Safe Search"), selection: $settings.safeSearch) {
                    ForEach(SafeSearch.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Online Suggestions", isOn: $shields.onlineSuggestions)
                Toggle("Site Icons in Results", isOn: $shields.resultSiteIcons)
                Toggle("Knowledge Cards", isOn: $shields.knowledgeCards)
                Toggle("Grokipedia Cards", isOn: $shields.preferGrokipedia)
                    .disabled(!shields.knowledgeCards)
            } header: {
                Text(L("Search"))
            } footer: {
                Text("Online Suggestions sends what you type to your instance for completions (off by default). Site Icons fetches each result site's icon anonymously. Knowledge Cards summarize entity searches — Grokipedia first, Wikipedia as fallback (never in private tabs).")
            }
        }
        .navigationTitle(L("Search"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Bindable private var appearance = AppearanceSettings.shared

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
                        Text("Result title preview")
                            .font(.system(size: 18 * appearance.textScale, weight: .semibold))
                        Text("This is how result snippets will read at the selected size.")
                            .font(.system(size: 14 * appearance.textScale))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text(L("Text Size"))
            } footer: {
                Text("Applies to Searxly's interface — results, cards, suggestions. Web page text size is set per site from the lock icon on the page.")
            }
        }
        .navigationTitle(L("Appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }
}

// MARK: - Shields

private struct ShieldsPane: View {
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Block Ads & Trackers", isOn: $shields.blockAdsAndTrackers)
                Toggle("YouTube Ad Blocking", isOn: $shields.youtubeAdBlock)
                    .disabled(!shields.blockAdsAndTrackers)
                Toggle("Fingerprint Protection", isOn: $shields.fingerprintProtection)
                Toggle("Do-Not-Sell Signal (GPC)", isOn: $shields.gpcSignal)
            } header: {
                Text(L("Shields"))
            } footer: {
                Text("Ad & tracker blocking uses bundled uBlock Origin filter lists (EasyList, EasyPrivacy, Peter Lowe, uBO) — fully local, nothing is downloaded. Fingerprint Protection randomizes canvas and audio readouts each session. GPC tells sites not to sell or share your data. Changes apply to new tabs.")
            }

            Section {
                Toggle("Hide Cookie Banners", isOn: $shields.blockCookieBanners)
            } footer: {
                Text("Removes cookie-consent pop-ups and the scroll locks they add. Never clicks “Accept” for you — your Do-Not-Sell (GPC) signal already states your preference.")
            }

            Section {
                Toggle("HTTPS-Only", isOn: $shields.httpsOnly)
                Toggle("Remove Tracking Parameters", isOn: $shields.stripTrackingParams)
                Toggle("Skip AMP Pages", isOn: $shields.deAMP)
            } header: {
                Text("Connections & Links")
            } footer: {
                Text("HTTPS-Only upgrades insecure links and asks before ever loading plain HTTP. Link cleaning strips identifiers like utm_ and fbclid. AMP pages are replaced by the publisher's real page.")
            }

            if !shields.shieldsOffHosts.isEmpty {
                Section {
                    ForEach(shields.shieldsOffHosts.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Raise") { shields.setShields(true, forHost: host) }
                                .font(.subheadline)
                        }
                    }
                    Button("Raise Shields Everywhere") { shields.clearShieldsExceptions() }
                } header: {
                    Text("Sites with Lowered Shields")
                } footer: {
                    Text("Ad & tracker blocking is reduced on these sites. Reload their tabs after raising.")
                }
            }
        }
        .navigationTitle(L("Shields"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
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
                Toggle("Save History", isOn: $settings.saveHistory)
                Toggle("Block Pop-ups", isOn: $settings.blockPopups)
                Toggle("Restore Tabs at Launch", isOn: $shields.restoreTabs)
                Toggle("Clear Website Data on Exit", isOn: $shields.clearDataOnExit)
            } header: {
                Text(L("Privacy"))
            } footer: {
                Text("History stays on this device only, encrypted at rest. Pop-up blocking stops sites opening extra windows. Tab restore saves open pages encrypted (never private tabs) and is disabled by Clear on Exit, which wipes cookies and site data from previous sessions when Searxly starts.")
            }

            Section(L("Data")) {
                Button(clearedHistory ? "History Cleared" : L("Clear History")) {
                    LibraryStore.shared.clearHistory()
                    clearedHistory = true
                }
                .disabled(clearedHistory || LibraryStore.shared.history.isEmpty)

                Button(clearedData ? "Website Data Cleared" : "Clear Website Data") {
                    WKWebsiteDataStore.default().removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        modifiedSince: .distantPast
                    ) {}
                    clearedData = true
                }
                .disabled(clearedData)
            }
        }
        .navigationTitle(L("Privacy"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }
}

// MARK: - Security

private struct SecurityPane: View {
    @Bindable private var shields = ShieldSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("App Lock", isOn: appLockBinding)
                    .disabled(!AppLockManager.deviceSupportsAuthentication)
            } header: {
                Text(L("Security"))
            } footer: {
                if AppLockManager.deviceSupportsAuthentication {
                    Text("Require \(AppLockManager.shared.biometryLabel) to open Searxly.")
                } else {
                    Text("App Lock needs Face ID, Touch ID, or a device passcode.")
                }
            }

            Section {
                Toggle("Lock Private Tabs", isOn: $shields.lockPrivateTabs)
                    .disabled(!AppLockManager.deviceSupportsAuthentication)
            } footer: {
                Text("Require \(AppLockManager.shared.biometryLabel) to reveal private tabs after you leave Searxly. Their contents stay hidden in the tab switcher until you unlock.")
            }
        }
        .navigationTitle(L("Security"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }

    /// The toggle drives an async biometric confirmation; the switch reflects the manager's
    /// state so a cancelled/failed prompt visibly snaps back.
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

    /// Live availability — polled while this pane is open, so finishing the model download
    /// (or flipping the Apple Intelligence switch) updates the row without leaving Settings.
    @State private var availability = PageIntelligence.availability

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Apple Intelligence"), value: L(availability.label))

                if availability == .downloading {
                    VStack(alignment: .leading, spacing: 7) {
                        // Apple exposes no progress for the system model download —
                        // an indeterminate bar is the honest version of a loading bar.
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Brand.text)
                        Text(L("iOS is downloading Apple's on-device model in the background. It goes fastest on Wi-Fi with the iPhone charging. This screen updates automatically."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if availability == .notEnabled {
                    Text(L("Turn on Apple Intelligence in Settings ▸ Apple Intelligence & Siri, then come back here."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Intelligence"))
            } footer: {
                Text("Searxly's AI runs entirely on this device with Apple Intelligence — nothing is sent to any server, ever, which is also why it works in private tabs. (Status detail: \(PageIntelligence.availabilityDetail))")
            }
            .task {
                // Nudge the asset download by registering demand, then poll until ready.
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
                Toggle(L("AI Overview"), isOn: $shields.aiOverview)
                    .disabled(availability != .available)
            } footer: {
                Text("A short answer above web results, grounded strictly in the result snippets with cited sources and follow-up searches. Generates automatically for question-like searches; other searches get a Generate button.")
            }

            Section {
                LabeledContent(L("Summarize Page"), value: "⋯ \(L("menu"))")
                LabeledContent(L("Ask About This Page"), value: "⋯ \(L("menu"))")
            } footer: {
                Text("Both appear in the page menu while browsing on eligible devices: a streaming summary of the page, and a chat that answers questions using only the page's own text.")
            }
        }
        .navigationTitle(L("Intelligence"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }
}
