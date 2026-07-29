//
//  DefaultBrowser.swift
//  SearxlyiOS
//
//  "Make Searxly your default browser" — status, the nudge's showing rules, and the jump into
//  iOS Settings.
//
//  The app can only be *chosen* as the default browser once Apple grants the managed
//  `com.apple.developer.web-browser` entitlement (requested at
//  developer.apple.com/contact/request/default-browser). Until then Searxly is not listed in
//  Settings ▸ Apps ▸ Default Apps at all, so nudging anyone there would send them looking for an
//  option that isn't on screen.
//
//  `UIApplication.isDefault(_:)` distinguishes the two cases for us: it THROWS when the status is
//  unavailable — which is exactly the un-entitled state — and returns a plain Bool once we are a
//  candidate. So this whole feature stays invisible until the entitlement lands and then turns
//  itself on, with no flag to remember to flip.
//
//  The URL handling it advertises already works: BrowserView.handleDeepLink opens any http(s) URL
//  handed to the app in a new tab.
//

import SwiftUI
import UIKit

@MainActor
@Observable
final class DefaultBrowser {
    static let shared = DefaultBrowser()

    enum Status {
        /// Not a candidate — the browser entitlement isn't granted (or the check was rate-limited).
        case unavailable
        case isDefault
        case notDefault
    }

    private(set) var status: Status = .unavailable

    /// Launches before the nudge is allowed to appear. Someone still deciding whether they like the
    /// app shouldn't be asked to make it their default on day one.
    private static let launchesBeforePrompting = 3

    private static let launchCountKey = "searxly.ios.launchCount"
    private static let dismissedKey = "searxly.ios.defaultBrowserPromptDismissed"

    /// Stored (not computed off UserDefaults) so @Observable sees the change and the card animates
    /// away the moment it's dismissed.
    private(set) var wasDismissed: Bool

    private let launchCount: Int
    private let defaults = UserDefaults.standard

    private init() {
        wasDismissed = UserDefaults.standard.bool(forKey: Self.dismissedKey)
        launchCount = UserDefaults.standard.integer(forKey: Self.launchCountKey) + 1
        UserDefaults.standard.set(launchCount, forKey: Self.launchCountKey)
    }

    /// Whether the home-screen card should show: entitled, not already the default, not dismissed,
    /// and the user has been around long enough to have an opinion.
    var shouldShowCard: Bool {
        status == .notDefault && !wasDismissed && launchCount >= Self.launchesBeforePrompting
    }

    func dismissCard() {
        wasDismissed = true
        defaults.set(true, forKey: Self.dismissedKey)
    }

    /// Refreshes `status`. iOS rate-limits this check, and a rate-limited answer is *unknown*, not
    /// "no" — treating it as unavailable keeps us quiet rather than nagging on a stale reading.
    func refresh() {
        do {
            status = try UIApplication.shared.isDefault(.webBrowser) ? .isDefault : .notDefault
        } catch {
            status = .unavailable
        }
    }

    /// Opens Settings ▸ Apps ▸ Default Apps, where the Browser row lives.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Home card

/// The nudge itself: one quiet, dismissible card on the start page. Monochrome, no badge, no
/// repeat — dismissing it is permanent, and it never returns once Searxly is the default.
struct DefaultBrowserCard: View {
    private var model = DefaultBrowser.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "safari")
                .scaledFont(size: 18, weight: .medium)
                .foregroundStyle(Brand.text)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("Open links in Searxly"))
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Brand.text)
                Text(L("Set Searxly as your default browser so links from other apps open here."))
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(L("Open Settings")) {
                    Haptics.tick()
                    model.openSystemSettings()
                }
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(Brand.text)
                .padding(.top, 6)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.2)) { model.dismissCard() }
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Brand.textTertiary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Dismiss"))
        }
        .padding(14)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
