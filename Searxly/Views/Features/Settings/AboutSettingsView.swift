//
//  AboutSettingsView.swift
//  Searxly
//

import SwiftUI

struct AboutSettingsView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "About Searxly",
                subtitle: "Private search through SearXNG instances you control."
            )

            SettingsSection(title: "Version") {
                Text(versionString)
                    .font(.callout)
                Text("Built with SearXNG, SwiftUI, and WebKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }
}