//
//  PrivacySettingsView.swift
//  Searxly
//
//  Privacy & Data pane. Organized top-down by how often people need it:
//    1. Privacy Mode   — the one ladder that drives everything (Normal ⊂ Encrypted ⊂ Maximum)
//    2. Browsing       — what Searxly remembers
//    3. Content filtering — SafeSearch + ad/tracker blocking
//    4. Your data      — encryption at rest, recovery code, clearing, honest storage notes
//    5. Get set up     — default browser + import (one-time actions, so they live last)
//
//  The old "Shortcuts" preset buttons were removed on purpose: they silently set the same modes
//  the Privacy Mode picker already sets, which meant two controls fighting over one state.
//

import SwiftUI

struct PrivacySettingsView: View {
    @Binding var historyEnabled: Bool
    @Binding var defaultNewTabsToPrivate: Bool
    @Binding var dataEncryptionEnabled: Bool
    @Binding var clearedMessage: String
    @Binding var showClearConfirmation: Bool
    @Binding var showingClearData: Bool

    var requestReauth: ((@escaping () -> Void, (() -> Void)?) -> Void)?
    var onExportRecovery: (() -> Void)?
    /// Jump to another Settings pane (used to send the user to VPN for a pass). A notification would be
    /// wrong here: Settings is already open, so the seeding `.onAppear` never refires.
    var onNavigate: ((SettingsCategory) -> Void)?

    /// @Observable — the VPN pass state decides whether the Searxly VPN lane can be picked at all.
    private let vpnService = ManagedVPNService.shared

    @State private var appPrivacyMode: AppPrivacyMode = .normal
    @State private var maxProtection: MaxProtection = .tor
    @State private var amnesiaPreference: Bool = AmnesiaMode.preference
    @State private var securityLevel: MaximumSecurityLevel = .standard

    // Operational security (Searxly Maximum) — seeded from the live values; persisted synchronously
    // in onChange (a deferred write can be lost on a quick quit).
    @State private var uniformLocale: Bool = false
    @State private var captureExclusion: Bool = false
    @State private var secureKeyboardEntry: Bool = false

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: Localization.string("privacy_header"),
                subtitle: Edition.isMaximum
                    ? "Live security status, engine hardening, and how data is stored on this Mac. If protection drops, traffic stops — it never falls back to an unprotected connection."
                    : "One privacy ladder, from fast to bulletproof — plus what Searxly remembers and how it's stored on this Mac."
            )

            // Searxly Maximum leads with the instrument panel: live posture before any control.
            if Edition.isMaximum {
                MaximumStatusBoard()
            }

            privacyModeSection
            // Searxly Maximum edition features only: the live Privacy Self-Test, Network Ledger, Tor
            // bridges, Amnesic mode, and the operational-security controls are premium hardening and
            // are absent from the base (free) app.
            if Edition.isMaximum {
                securityLevelSection
                operationalSecuritySection
                PrivacySelfTestSection()
                NetworkLedgerSection()
                TorBridgesSection()
                amnesicSection
            }
            browsingSection
            filteringSection
            requestShieldsSection
            dataSection
            setupSection
        }
    }

    // MARK: - 1. Privacy Mode

    private var privacyModeSection: some View {
        Group {
            if Edition.isMaximum {
                lockedMaximumModeSection
            } else {
                editablePrivacyModeSection
            }
        }
    }

    /// Searxly Maximum: the ladder itself is locked — the app is permanently in Maximum Privacy, with no
    /// lower rung. What the user DOES choose is the lane that carries the traffic, and this is the one
    /// place that choice is made. Settings → VPN deliberately doesn't duplicate it: which network hides
    /// your IP is a privacy posture, not a VPN setting, and two controls over one state is how the VPN
    /// pane ended up being mostly about Tor.
    private var lockedMaximumModeSection: some View {
        SettingsSection(
            title: "Privacy Mode",
            footer: "Searxly Maximum runs permanently in Maximum Privacy — there is no lower setting. Fingerprint defenses and at-rest encryption are always on. Whichever lane you pick, if it drops all traffic is blocked rather than exposed."
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maximum Privacy — always on")
                        .font(.callout.weight(.semibold))
                    Text("Locked on: IP protection, Strict fingerprint scrambling, at-rest encryption, and App Lock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Hide my IP with")
                    .font(.callout)
                protectionRow(.tor)
                protectionRow(.vpn)
            }
        }
    }

    /// The live lane, read straight off @Observable PrivacyManager rather than mirrored into @State.
    /// The lane can change without the user touching these rows — ManagedVPNService.enforceAccess()
    /// drops Maximum back to Tor the minute the pass lapses, on a 60s timer — and a mirror that only
    /// re-seeds in `.onAppear` would keep showing the dead lane as selected.
    private var liveProtection: MaxProtection { PrivacyManager.shared.maxProtection }

    /// One lane option. The Searxly VPN needs an active pass — the included 45-day welcome comp on a
    /// fresh install, or one bought in Settings → VPN once that ends — so without one the row says so
    /// and offers the way to get it. Picking it anyway would just snap back to Tor (setMaxProtection
    /// holds the lane closed rather than hand the kill switch a network that can't come up), and a
    /// control that silently undoes your tap is worse than one that explains itself.
    @ViewBuilder
    private func protectionRow(_ p: MaxProtection) -> some View {
        if p == .vpn && !PrivacyManager.shared.canSelectVPNProtection {
            protectionRowSurface(p, selected: false) {
                Button("Get a pass") { onNavigate?(.vpn) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button {
                PrivacyManager.shared.setMaxProtection(p)
            } label: {
                protectionRowSurface(p, selected: liveProtection == p) {
                    Image(systemName: liveProtection == p ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(liveProtection == p ? SettingsTheme.inkFill : SettingsTheme.hairline)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func protectionRowSurface<Trailing: View>(
        _ p: MaxProtection, selected: Bool, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let locked = (p == .vpn && !PrivacyManager.shared.canSelectVPNProtection)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: p.systemImage)
                .font(.system(size: 14))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if p == .vpn, let days = vpnPassDaysRemaining {
                        Text("\(days)d left")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(SettingsTheme.fillSubtle, in: Capsule())
                    }
                }
                Text(p.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if locked {
                    Text(vpnLockedReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? SettingsTheme.fillFaint : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? SettingsTheme.inkFill.opacity(0.4) : SettingsTheme.hairline, lineWidth: 1))
        .opacity(locked ? 0.7 : 1)
    }

    /// Days left on the VPN pass, when there is one — drives the "45d left" chip on the VPN lane.
    private var vpnPassDaysRemaining: Int? {
        guard let pass = vpnService.currentPass, pass.isActive, !pass.isOwner else { return nil }
        return pass.daysRemaining
    }

    private var vpnLockedReason: String {
        vpnService.currentPass == nil
            ? "Needs an active pass — buy one in Settings → VPN."
            : "Your Searxly VPN has ended. Buy a pass to use this lane again."
    }

    private var editablePrivacyModeSection: some View {
        SettingsSection(
            title: "Privacy Mode",
            footer: "Normal and Encrypted keep every site working. Maximum Privacy hides your IP behind the Searxly VPN or Tor — or blocks all traffic if neither is up — and scrambles your browser fingerprint. Much harder to track, but some sites may break."
        ) {
            Picker("", selection: $appPrivacyMode) {
                ForEach(AppPrivacyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: appPrivacyMode) { oldValue, newValue in
                guard newValue != PrivacyManager.shared.appPrivacyMode else { return }
                applyAppPrivacyMode(newValue, revertTo: oldValue)
            }

            Text(appPrivacyMode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appPrivacyMode == .maximum {
                SettingsDivider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide my IP with")
                            .font(.callout)
                        Text(maxProtection.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $maxProtection) {
                        ForEach(MaxProtection.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: maxProtection) { _, newValue in
                        PrivacyManager.shared.setMaxProtection(newValue)
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                appPrivacyMode = PrivacyManager.shared.appPrivacyMode
                maxProtection = PrivacyManager.shared.maxProtection
            }
        }
    }

    // MARK: - 1a. Security level (Tor-Browser-style slider) — Maximum only

    private var securityLevelSection: some View {
        SettingsSection(
            title: "Security Level",
            footer: "Like Tor Browser's slider. Higher levels shrink what a malicious page can do — the biggest residual risk in any browser is a JavaScript-engine exploit (historically the way Tor users have been deanonymised). Safest turns JavaScript off on the web; your local search still works. Reload a page to apply a change."
        ) {
            Picker("", selection: $securityLevel) {
                ForEach(MaximumSecurityLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: securityLevel) { _, newValue in
                MaximumSecurity.shared.setLevel(newValue)
            }

            Text(securityLevel.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            DispatchQueue.main.async { securityLevel = MaximumSecurity.shared.level }
        }
    }

    // MARK: - 1b. Amnesic mode

    private var amnesicSection: some View {
        SettingsSection(
            title: "Amnesic mode",
            footer: "When on, Searxly runs entirely in memory — browsing history, open tabs, cookies, and cache are never written to disk and are gone the moment you quit. Downloads land in a session folder that vanishes too, unless you keep them from the Downloads sheet. Your bookmarks, saved passwords, and settings are kept. Takes full effect at the next launch."
        ) {
            SettingsToggleRow(
                title: "Leave no trace on disk",
                description: "RAM-only browsing: nothing about what you do this session survives quitting.",
                isOn: $amnesiaPreference,
                badge: AmnesiaMode.isActive ? "Active" : (amnesiaPreference ? "Next launch" : nil)
            )
            .onChange(of: amnesiaPreference) { _, newValue in
                AmnesiaMode.preference = newValue
            }

            if amnesiaPreference && !AmnesiaMode.isActive {
                Text("Relaunch Searxly to start an amnesic session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if AmnesiaMode.isActive && !amnesiaPreference {
                Text("Amnesic mode stays active until you relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 1c. Operational security (Searxly Maximum)

    private var operationalSecuritySection: some View {
        SettingsSection(
            title: "Operational Security",
            footer: "Controls for leaks that live outside the web engine — the HTTP locale header, screen capture, and keyboard event taps. Each one states its cost; nothing here is free."
        ) {
            SettingsToggleRow(
                title: "Uniform locale",
                description: UniformLocale.overriddenByLanguageChoice
                    ? "Suspended: your explicit app-language choice (Settings → Search → Language) takes precedence, so the Accept-Language header follows that instead."
                    : "Sends en-US as the Accept-Language header so requests can't be narrowed by your real locale — and can't be fingerprinted by the header contradicting the pinned en-US that pages read from JavaScript. The app interface runs in English. Applies fully at the next launch.",
                isOn: $uniformLocale
            )
            .disabled(UniformLocale.overriddenByLanguageChoice)
            .onChange(of: uniformLocale) { _, newValue in
                UniformLocale.enabled = newValue
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Exclude windows from screen capture",
                description: "Every Searxly window renders black in screenshots, screen recordings, and shared screens (Zoom, Teams, …). Cost: your own screenshots of Searxly stop working too.",
                isOn: $captureExclusion
            )
            .onChange(of: captureExclusion) { _, newValue in
                CaptureExclusion.enabled = newValue
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Secure keyboard entry",
                description: "While the address bar is focused, other processes' event taps can't read your keystrokes — the same protection Terminal offers. Cost: text expanders and keystroke utilities pause while the field is focused.",
                isOn: $secureKeyboardEntry
            )
            .onChange(of: secureKeyboardEntry) { _, newValue in
                SecureInputGuard.enabled = newValue
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                uniformLocale = UniformLocale.enabled
                captureExclusion = CaptureExclusion.enabled
                secureKeyboardEntry = SecureInputGuard.enabled
            }
        }
    }

    // MARK: - 2. Browsing

    private var browsingSection: some View {
        SettingsSection(title: "Browsing") {
            SettingsToggleRow(
                title: Localization.string("save_browsing_history"),
                description: "Keeps a list of sites you visit. Off by default is more private.",
                isOn: $historyEnabled
            )
            .onChange(of: historyEnabled) { _, newValue in
                // Persist synchronously (not in a deferred Task): otherwise toggling and then
                // immediately quitting can terminate the app before the task runs, and the
                // quit-time save preserves the old on-disk value — the setting silently reverts.
                PrivacyManager.shared.setHistoryEnabled(newValue)
            }

            SettingsDivider()

            SettingsToggleRow(
                title: Localization.string("default_new_tabs_private"),
                description: "⌘T opens a Private tab instead of a standard tab. ⌘⇧T always opens Private explicitly.",
                isOn: $defaultNewTabsToPrivate
            )
            .onChange(of: defaultNewTabsToPrivate) { _, newValue in
                // Persist synchronously — same durability reason as history above.
                PrivacyManager.shared.setDefaultNewTabsToPrivate(newValue)
            }

            if Edition.isMaximum {
                SettingsDivider()

                SettingsToggleRow(
                    title: "Auto-upgrade to .onion when offered",
                    description: "When a site advertises a Tor onion mirror, open it automatically — end-to-end encrypted, with no exit node. Otherwise Searxly just offers a banner.",
                    isOn: Binding(
                        get: { OnionPreferences.autoUpgrade },
                        set: { OnionPreferences.autoUpgrade = $0 }
                    ),
                    badge: OnionPreferences.autoUpgrade ? "On" : nil
                )
            }

            if historyEnabled {
                // Encryption-aware: says "encrypted at rest" only when it actually is.
                Text(PrivacyManager.shared.historyStorageWarning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                historyEnabled = PrivacyManager.shared.historyEnabled
                defaultNewTabsToPrivate = PrivacyManager.shared.defaultNewTabsToPrivate
            }
        }
    }

    // MARK: - 3. Content filtering

    private var filteringSection: some View {
        SettingsSection(
            title: "Content filtering",
            footer: "Ad blocking uses bundled uBlock Origin filter lists, fully offline. Reload open pages after changing it."
        ) {
            SettingsToggleRow(
                title: "Block ads and trackers on websites",
                description: "Removes ads, trackers, and annoyances while pages load.",
                isOn: Binding(
                    // Call directly: setEnabled persists the flag synchronously and defers its
                    // own (heavy) rule compilation internally. Wrapping it in a Task risked the
                    // write being lost if the app quit before the task ran.
                    get: { AdBlockManager.shared.isEnabled },
                    set: { newValue in AdBlockManager.shared.setEnabled(newValue) }
                ),
                badge: AdBlockManager.shared.isEnabled ? "On" : nil
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "SafeSearch — filter sensitive results",
                description: "Like Google SafeSearch: strict upstream filtering plus a local blocklist. Not perfect; turn off for unfiltered results.",
                isOn: Binding(
                    get: { SearchContentSafety.shared.isEnabled },
                    set: { SearchContentSafety.shared.isEnabled = $0 }
                ),
                badge: SearchContentSafety.shared.isEnabled ? "On" : nil
            )
        }
    }

    // MARK: - 3b. Request shields (link cleaning, GPC, HTTPS-only)

    private var requestShieldsSection: some View {
        SettingsSection(
            title: "Link & Request Privacy",
            footer: Edition.isMaximum
                ? "Always on in Searxly Maximum. These clean the request itself — the parts Tor and fingerprint defenses can't reach, because they travel inside the URL and headers."
                : "These clean the request itself: the tracking IDs in links, the opt-out header, and the connection's security."
        ) {
            shieldRow(
                title: "Strip tracking parameters from links",
                description: "Removes cross-site tags like fbclid and utm_* from addresses before they load — a tracking ID in a URL survives everything else.",
                keyPath: \.stripTrackingParams,
                set: { PrivacyShieldSettings.shared.stripTrackingParams = $0 }
            )
            SettingsDivider()
            shieldRow(
                title: "Send Global Privacy Control",
                description: "Adds the Sec-GPC signal to every page — a legally recognized opt-out from sale and sharing of your data under laws like California's CPRA.",
                keyPath: \.gpcSignal,
                set: { PrivacyShieldSettings.shared.gpcSignal = $0 }
            )
            SettingsDivider()
            shieldRow(
                title: "HTTPS-only connections",
                description: "Upgrades insecure http:// pages to https:// so traffic can't load in the clear.",
                keyPath: \.httpsOnly,
                set: { PrivacyShieldSettings.shared.httpsOnly = $0 }
            )
            SettingsDivider()
            SettingsToggleRow(
                title: "Warn about dangerous sites",
                description: "Checks pages against a bundled, offline list of known malicious and phishing sites and warns before they load. The check runs entirely on this Mac — no URL is ever sent anywhere (unlike Google Safe Browsing).",
                isOn: Binding(
                    get: { PhishingGuard.isEnabled },
                    set: { PhishingGuard.isEnabled = $0 }
                ),
                badge: PhishingGuard.isEnabled ? "On" : nil
            )
        }
    }

    /// One shield toggle. Locked ON (disabled, "On" badge) in Searxly Maximum; editable in base.
    private func shieldRow(title: String, description: String,
                           keyPath: KeyPath<PrivacyShieldSettings, Bool>,
                           set: @escaping (Bool) -> Void) -> some View {
        SettingsToggleRow(
            title: title,
            description: description,
            isOn: Binding(
                get: { PrivacyShieldSettings.shared[keyPath: keyPath] },
                set: { set($0) }
            ),
            badge: PrivacyShieldSettings.shared.isLocked ? "On" : nil
        )
        .disabled(PrivacyShieldSettings.shared.isLocked)
    }

    // MARK: - 4. Your data on this Mac

    private var dataSection: some View {
        Group {
            SettingsSection(
                title: "Your data on this Mac",
                footer: "Copy a recovery code after enabling encryption — without it, encrypted data cannot be recovered if your Keychain is lost."
            ) {
                SettingsToggleRow(
                    title: Localization.string("encrypt_local_data"),
                    description: "Encrypts history, bookmarks, instances, and tab state using CryptoKit and your Keychain.",
                    isOn: $dataEncryptionEnabled,
                    badge: dataEncryptionEnabled ? "On" : nil
                )
                .onChange(of: dataEncryptionEnabled) { oldValue, newValue in
                    let action = { PrivacyManager.shared.setDataEncryptionEnabled(newValue) }
                    if let reauth = requestReauth, AppLockManager.shared.requiresPINForSensitiveActions {
                        reauth(action) { dataEncryptionEnabled = oldValue }
                    } else {
                        action()
                    }
                }

                if dataEncryptionEnabled {
                    SettingsDivider()

                    SettingsActionChip(
                        title: Localization.string("copy_recovery_code"),
                        systemImage: "key"
                    ) {
                        if let export = onExportRecovery {
                            export()
                        } else if PrivacyManager.shared.copyEncryptionRecoveryCodeToClipboard() {
                            clearedMessage = Localization.string("recovery_code_copied")
                            showClearConfirmation = true
                        } else {
                            clearedMessage = Localization.string("no_encryption_key")
                            showClearConfirmation = true
                        }
                    }
                }

                SettingsDivider()

                SettingsActionChip(
                    title: Localization.string("clear_browsing_data"),
                    systemImage: "trash",
                    role: .destructive
                ) {
                    showingClearData = true
                }

                Text("Choose exactly what to remove — history, cookies, cache, and more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                DispatchQueue.main.async {
                    dataEncryptionEnabled = PrivacyManager.shared.dataEncryptionEnabled
                }
            }

            // Honest, state-aware storage note: orange only while data is actually unencrypted.
            SettingsCallout(
                title: "How your data is protected",
                message: PrivacyManager.shared.strongerDataWarning,
                tint: dataEncryptionEnabled ? .secondary : .orange,
                systemImage: dataEncryptionEnabled ? "lock.fill" : "externaldrive.fill"
            )

            SettingsCallout(
                title: Localization.string("what_is_stored"),
                message: Localization.string("stored_items"),
                tint: .secondary,
                systemImage: "info.circle"
            )
        }
    }

    // MARK: - 5. Get set up

    private var setupSection: some View {
        SettingsSection(
            title: "Get set up",
            footer: DefaultBrowserManager.shared.isDefault
                ? "Searxly is your default browser — links from Mail, Messages, and other apps open here."
                : "Make Searxly your default so links from other apps open here — then your private browsing covers everything, not just what you start in the app."
        ) {
            if DefaultBrowserManager.shared.isDefault {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                    Text("Searxly is your default browser.")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
            } else {
                SettingsProminentAction(
                    title: "Make Searxly the Default Browser",
                    systemImage: "globe",
                    action: { DefaultBrowserManager.shared.makeDefault() }
                )
                .help("Asks macOS to set Searxly as the handler for http and https links.")
            }

            SettingsDivider()

            SettingsProminentAction(
                title: "Import Data from Another Browser",
                systemImage: "square.and.arrow.down.on.square",
                tint: .secondary,
                action: {
                    NotificationCenter.default.post(name: .importDataRequested, object: nil)
                }
            )
            .help(PasswordVaultManager.isAvailable
                  ? "Brings bookmarks (exported HTML) and passwords (CSV) over from Safari, Chrome, Firefox, and others."
                  : "Brings bookmarks (exported HTML) over from Safari, Chrome, Firefox, and others.")
        }
        .onAppear { DefaultBrowserManager.shared.refresh() }
    }

    // MARK: - Mode application

    /// Applies an app privacy mode from the picker. Encrypted/Maximum enable encryption + App Lock,
    /// so they're gated behind re-auth when a vault PIN is required; on cancel the picker reverts
    /// to `previous`. All dependent toggles resync from PrivacyManager afterwards.
    private func applyAppPrivacyMode(_ mode: AppPrivacyMode, revertTo previous: AppPrivacyMode? = nil) {
        let run = {
            PrivacyManager.shared.setAppPrivacyMode(mode)
            appPrivacyMode = PrivacyManager.shared.appPrivacyMode
            maxProtection = PrivacyManager.shared.maxProtection
            historyEnabled = PrivacyManager.shared.historyEnabled
            dataEncryptionEnabled = PrivacyManager.shared.dataEncryptionEnabled
            defaultNewTabsToPrivate = PrivacyManager.shared.defaultNewTabsToPrivate
        }

        if mode != .normal, let reauth = requestReauth, AppLockManager.shared.requiresPINForSensitiveActions {
            reauth(run, { appPrivacyMode = previous ?? PrivacyManager.shared.appPrivacyMode })
        } else {
            run()
        }
    }
}
