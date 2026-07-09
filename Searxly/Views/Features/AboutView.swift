//
//  AboutView.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Phase 12: Proper About window
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe.desk")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text(Edition.appName)
                    .font(.largeTitle.weight(.semibold))

                Text(Edition.isMaximum ? "Locked-down, 100% local private browser" : "Privacy-first native macOS browser")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                Text("Version \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text("Powered by SearXNG + SwiftUI + WebKit")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("A learning project following the SEARCXLY-PLAN.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Link("View on GitHub", destination: URL(string: "https://github.com/searxly/Searxly")!)
                    .font(.callout)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Acknowledgments") {
                    // Future: show acknowledgments
                }
                .buttonStyle(.link)

                Text("•")
                    .foregroundStyle(.tertiary)

                Link("Report an Issue", destination: URL(string: "https://github.com/searxly/Searxly/issues")!)
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(32)
        .frame(width: 380, height: 320)
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

#Preview {
    AboutView()
}