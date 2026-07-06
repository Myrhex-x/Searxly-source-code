//
//  SearxlyAICloudSettingsView.swift
//  Searxly
//
//  Standalone Settings tab for the cloud AI engine (kept separate from the on-device/local engines so
//  the choice is clear). Enabling it auto-enables the master agent, since every engine needs it on.
//

import SwiftUI

struct SearxlyAICloudSettingsView: View {
    @State private var manager = LocalIntelligenceManager.shared
    @State private var showCloudEgressConfirm = false
    /// On-device PII redaction before cloud egress. Key matches `RampartRedactor.enabledDefaultsKey`.
    @AppStorage("redactPIIBeforeCloudAI") private var redactPIIBeforeCloudAI = true

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Searxly AI",
                subtitle: "Searxly's hosted AI — the most capable option, with no setup. It runs in Searxly's private cloud; connect your in-app wallet (free) to use it."
            )

            SettingsSection(
                title: "Enable",
                footer: "Unlike on-device AI, Searxly AI sends your prompt — plus any page you summarize and the search results behind a grounded answer — to Searxly's cloud. Personal details are redacted on your Mac first (see Privacy below). It only does so when you pick Searxly AI in the chat's model picker."
            ) {
                SettingsToggleRow(
                    title: "Enable Searxly AI",
                    description: "Adds Searxly AI to the chat's model picker. Some prompts are free.",
                    isOn: Binding(
                        get: { manager.preferences.searxlyAIEnabled },
                        set: { newValue in
                            if newValue && !manager.preferences.searxlyAIEnabled {
                                // First enable: require explicit acknowledgement that data leaves the Mac.
                                showCloudEgressConfirm = true
                            } else {
                                manager.preferences.searxlyAIEnabled = newValue
                                if !newValue { manager.preferences.useSearxlyAI = false }
                                manager.persistPreferences()
                                LocalIntelligenceManager.shared.noteSearxlyAIToggled()
                                Task { await LocalIntelligenceManager.shared.refreshAvailability() }
                            }
                        }
                    ),
                    badge: manager.preferences.searxlyAIEnabled ? "On" : nil
                )
            }

            if manager.preferences.searxlyAIEnabled {
                privacyRedactionSection

                if !SearxlyAICloud.isConfigured {
                    SettingsCallout(
                        title: "Not set up yet",
                        message: "Searxly AI isn't configured on this build.",
                        tint: .orange,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                SettingsSection(
                    title: "Your plan",
                    footer: "Connecting your wallet is free — no payment and no funds move. It's just a one-tap signature so each person has a single identity, which is what stops the free prompts from being abused."
                ) {
                    SearxlyAISubscriptionView()
                }

                agentToolsSection
            }
        }
        .alert("Searxly AI runs in the cloud", isPresented: $showCloudEgressConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") { enableSearxlyAICloud() }
        } message: {
            Text("Unlike on-device AI, Searxly AI sends what you ask it off this Mac to Searxly's cloud: your chat messages, any page text you ask it to summarize, and the private search results behind a grounded answer. Sensitive details like names, emails and ID numbers are redacted on your Mac before sending (you can turn this off under Privacy). It stays off until you pick \"Searxly AI\" in the chat. Enable it?")
        }
    }

    /// On-device redaction disclosure + toggle. Searxly AI is the one surface where free text
    /// leaves the Mac, so the control lives beside the egress disclosure.
    @ViewBuilder
    private var privacyRedactionSection: some View {
        SettingsSection(
            title: "Privacy",
            footer: "Before anything is sent, Searxly redacts personal info on your Mac — names, emails, phone numbers, SSNs, card and account numbers, and street addresses become neutral placeholders like [GIVEN_NAME_1]. Searxly AI answers about the placeholders and the real values are restored on-device, so nobody on the server sees them. City, state and ZIP are kept so answers stay useful. Powered by Rampart (open-source, CC BY 4.0)."
        ) {
            SettingsToggleRow(
                title: "Redact personal info before sending",
                description: "Scrub PII from your messages before they reach Searxly AI, then un-redact the reply locally.",
                isOn: $redactPIIBeforeCloudAI,
                badge: redactPIIBeforeCloudAI ? "On" : nil
            )
        }
    }

    /// The full cloud tool surface, toggleable per tool. Lives here (not in on-device settings) because every
    /// tool below is cloud-only — it runs on Searxly AI. The two core tools (Web search / Open website) that
    /// also work on-device are managed in the on-device AI settings tab.
    @ViewBuilder
    private var agentToolsSection: some View {
        SettingsSection(
            title: "Agent tools",
            footer: "Searxly AI can use these while it answers — switch off any you'd rather it never touch. They run in Searxly's cloud and every use is logged in AI Activity."
        ) {
            SettingsToggleRow(
                title: "Let the Agent use tools",
                description: "Master switch for tool use. When off, Searxly AI just chats and calls nothing.",
                isOn: Binding(
                    get: { manager.preferences.toolsEnabled },
                    set: { newValue in
                        manager.preferences.toolsEnabled = newValue
                        manager.persistPreferences()
                    }
                ),
                badge: manager.toolsEnabled ? "On" : nil
            )

            ForEach(AIToolCatalog.all.filter { !$0.availableOnDevice }) { tool in
                SettingsDivider()
                SettingsToggleRow(
                    title: tool.name,
                    description: tool.summary,
                    isOn: Binding(
                        get: { manager.isToolEnabled(tool.id) },
                        set: { manager.setToolEnabled(tool.id, $0) }
                    )
                )
                .disabled(!manager.toolsEnabled)
            }
        }
    }

    /// Flips Searxly AI (cloud) on after the egress disclosure. Also ensures the master agent is on, since
    /// every engine (cloud included) is gated by it — so enabling Searxly AI here just works.
    private func enableSearxlyAICloud() {
        if !manager.isEnabled { manager.isEnabled = true }
        manager.preferences.searxlyAIEnabled = true
        manager.persistPreferences()
        LocalIntelligenceManager.shared.noteSearxlyAIToggled()
        Task { await LocalIntelligenceManager.shared.refreshAvailability() }
    }
}
