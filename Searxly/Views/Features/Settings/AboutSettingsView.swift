//
//  AboutSettingsView.swift
//  Searxly
//

import SwiftUI

struct AboutSettingsView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    private var licenseManager: LicenseManager { LicenseManager.shared }
    @State private var confirmDeactivate = false

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    /// Plain-language name for how the license was bought (the enum's raw values are wire values).
    private func licenseChannelLabel(_ channel: LicenseChannel) -> String {
        switch channel {
        case .card:     return "Credit or debit card"
        case .crypto:   return "Crypto"
        case .appleIAP: return "App Store"
        case .comp:     return "Complimentary"
        case .unknown:  return "—"
        }
    }

    /// One provenance line: quiet small-caps label, ink value — the About pane's version of the
    /// instrument-panel readout.
    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(SettingsTheme.textTertiary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: Edition.isMaximum ? "About Searxly Maximum" : "About Searxly",
                subtitle: Edition.isMaximum
                    ? "Build provenance, licensing, and what this installation is made of."
                    : "Private search through SearXNG instances you control."
            )

            if Edition.isMaximum {
                // Professionals verify what they run: exact versions of the app and of every
                // bundled runtime, in one place. The Self-Test's supply-chain check confirms the
                // Tor binary listed here is the one Searxly shipped.
                SettingsSection(
                    title: "Build",
                    footer: "The bundled Tor runtime is signature-verified at every launch and by the Privacy Self-Test (Privacy & Data). All engines run locally; this installation has no server-side components."
                ) {
                    provenanceRow("Application", versionString.replacingOccurrences(of: "Version ", with: ""))
                    SettingsDivider()
                    provenanceRow("Edition", "Searxly Maximum — locked to Maximum Privacy")
                    SettingsDivider()
                    provenanceRow("Bundled Tor", TorRuntimeConfig.bundledVersion)
                    SettingsDivider()
                    provenanceRow("Search engine", "SearXNG (local instance, AGPL-3.0)")
                    SettingsDivider()
                    provenanceRow("Web engine", "WebKit (system), engine-level hardening applied")
                }

                // Maximum is paid, so show exactly which license this install runs on — and let the user
                // move it to another Mac. Gated on `paymentsEnabled` (not `Edition.isMaximum`) so the
                // section simply isn't there while Maximum is still free.
                if Licensing.paymentsEnabled {
                    SettingsSection(
                        title: "Your License",
                        footer: "Your license is checked on this Mac against a key built into the app — activating it, and this screen, send nothing to Searxly. Keep the key from your purchase email: you need it to activate on another Mac."
                    ) {
                        if let license = licenseManager.license {
                            provenanceRow("Status", "Activated")
                            SettingsDivider()
                            provenanceRow("License ID", license.licenseID)
                            SettingsDivider()
                            provenanceRow("Bought with", licenseChannelLabel(license.channel))
                            SettingsDivider()
                            provenanceRow("Purchased", license.issuedAt.formatted(date: .abbreviated, time: .omitted))
                            SettingsDivider()
                            provenanceRow("Expires", license.expiresAt.map {
                                $0.formatted(date: .abbreviated, time: .omitted)
                            } ?? "Never — this license is permanent")
                            SettingsDivider()
                            Button("Deactivate on this Mac") { confirmDeactivate = true }
                                .font(.callout)
                        } else {
                            provenanceRow("Status", "Not activated")
                        }
                    }
                }
            } else {
                SettingsSection(title: "Version") {
                    Text(versionString)
                        .font(.callout)
                    Text("Built with SearXNG, SwiftUI, and WebKit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(
                title: "Acknowledgements",
                footer: "Searxly bundles a native port of Rampart (on-device PII redaction) by National Design Studio, used under CC BY 4.0. Its model is trained on the OpenPII dataset (CC BY 4.0)."
            ) {
                Link(destination: URL(string: "https://github.com/nationaldesignstudio/rampart")!) {
                    Label("Rampart (CC BY 4.0)", systemImage: "shield.lefthalf.filled")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            // Maximum-only: the AGPL source offer for the bundled SearXNG. Base satisfies this
            // through the license text + full engine source that already ship inside the app
            // bundle; Maximum is the paid edition, so it surfaces the offer explicitly here too.
            if Edition.isMaximum {
                SettingsSection(
                    title: "Search Engine License",
                    footer: "Searxly Maximum bundles SearXNG, an open-source metasearch engine, under the GNU AGPL v3.0. Searxly's changes to it (theme and configuration) are published under the same license at the linked repository — you're free to download, run, and redistribute them."
                ) {
                    Link(destination: URL(string: "https://github.com/Searxly/Searxly-source-code")!) {
                        Label("SearXNG source & modifications (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    Link(destination: URL(string: "https://github.com/searxng/searxng")!) {
                        Label("SearXNG project", systemImage: "link")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }

            SettingsSection(title: "Community") {
                Link(destination: URL(string: "https://github.com/searxly/Searxly")!) {
                    Label("GitHub repository", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            SettingsSection(
                title: "First-run setup",
                footer: "Shows the welcome flow again the next time you open Searxly."
            ) {
                Button("Show onboarding again") {
                    hasCompletedOnboarding = false
                    UserDefaults.standard.removeObject(forKey: "Searxly.LocalSearxng.UserOptedIn")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        // Deactivating raises the activation gate immediately, and the only way back in is the key from
        // the purchase email. Worth one confirmation rather than a one-click lockout.
        .confirmationDialog(
            "Deactivate Searxly Maximum on this Mac?",
            isPresented: $confirmDeactivate,
            titleVisibility: .visible
        ) {
            Button("Deactivate", role: .destructive) { licenseManager.deactivate() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Searxly Maximum will lock until you enter a license key again. Your license stays valid — you can activate it here or on another Mac. Make sure you still have the key from your purchase email.")
        }
    }
}