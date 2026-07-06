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
                footer: "On-device PII redaction for Searxly AI is a native port of Rampart by National Design Studio, used under CC BY 4.0. Its model is trained on the OpenPII dataset (CC BY 4.0)."
            ) {
                Link(destination: URL(string: "https://github.com/nationaldesignstudio/rampart")!) {
                    Label("Rampart (CC BY 4.0)", systemImage: "shield.lefthalf.filled")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            SettingsSection(title: "Community") {
                Link(destination: URL(string: "https://github.com/Myrhex-x/Searxly")!) {
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