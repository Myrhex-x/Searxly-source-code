//
//  SupportSettingsView.swift
//  Searxly
//
//  One door to the hosted Support Center (support.searxly.app), where people open and track tickets.
//  Kept deliberately thin: Searxly holds no support state on the device, so this pane's whole job is
//  to hand off to the portal — it doesn't reimplement it.
//

import SwiftUI
import AppKit

/// Canonical home of the hosted support portal URL. Referenced from Settings (this pane) and from the
/// VPN pane (so a card payer can open a billing ticket), so it lives in the committed source rather
/// than in either caller — one string, one place to change it.
enum SupportCenter {
    static let url = URL(string: "https://support.searxly.app")!

    /// Opens the support portal in the user's browser (their default browser, which may be Searxly).
    static func open() {
        NSWorkspace.shared.open(url)
    }
}

struct SupportSettingsView: View {
    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: Localization.string("support_title", defaultValue: "Support"),
                subtitle: "Get help, report a problem, or open and track a support ticket. Handled by our hosted support center at support.searxly.app."
            )

            SettingsSection(
                title: "Support center",
                footer: "Opens support.searxly.app in your browser. Start a new ticket or check the status of one you already filed."
            ) {
                Button {
                    SupportCenter.open()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "lifepreserver.fill").font(.system(size: 13))
                        Text("Open Support Center")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(SettingsTheme.inkFill)
                .foregroundStyle(SettingsTheme.onInk)
            }
        }
    }
}
