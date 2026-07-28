//
//  WalletSettingsSection.swift
//  Searxly
//
//  Content for the Wallet pane in Settings (also shown in the wallet popup's gear sheet). Composed
//  from the shared Settings design system (SettingsLayout) so it reads as clean grouped cards and
//  matches the rest of Settings. Logic/bindings are unchanged — this file is layout only.
//

import SwiftUI

struct WalletSettingsSection: View {
    @AppStorage("reduceLiquidGlass") private var reduceLiquidGlass = false
    @State private var wallet = WalletManager.shared
    @State private var permissions = DAppPermissionStore.shared
    @State private var customRPC = ""
    @State private var showDeleteConfirm = false
    @State private var showRevealPhrase = false
    @State private var showApprovals = false
    @State private var wc = WalletConnectManager.shared
    @State private var wcProjectId = ""
    @State private var wcURI = ""

    @State private var showChangeSecret = false
    // Biometric enable flow
    @State private var showBiometricSetup = false
    @State private var biometricPIN = ""
    @State private var biometricError = false

    // Hybrid feature toggles (bound directly to the same UserDefaults keys WalletFeatures reads)
    @AppStorage(WalletConfig.Keys.enableFullHistory)    private var fullHistory = false
    @AppStorage(WalletConfig.Keys.enableTokenDiscovery) private var tokenDiscovery = false
    @AppStorage(WalletConfig.Keys.enableSwaps)          private var swaps = false
    @AppStorage(WalletConfig.Keys.enableBuy)            private var buy = false
    @AppStorage(WalletConfig.Keys.enableENS)            private var ens = false
    @AppStorage(WalletConfig.Keys.enablePriceCharts)    private var priceCharts = true
    // API keys live in the Keychain (via WalletFeatures), loaded on appear and written through on change.
    @State private var basescanKey = ""
    @State private var zeroExKey = ""
    @AppStorage(WalletConfig.Keys.dappProviderEnabled)  private var dappProvider = true
    @AppStorage(WalletConfig.Keys.rotatePerDApp)        private var rotatePerDApp = false
    @AppStorage(WalletConfig.Keys.incomingAlerts)       private var incomingAlerts = true

    private var isSetup: Bool { wallet.unlockState != .notSetup }

    /// The wallet is an opt-in surface. This pane is always reachable so the feature can be turned
    /// on; everything below the toggle only renders once it is.
    @AppStorage(WalletConfig.Keys.surfaceEnabled) private var walletSurfaceEnabled = WalletConfig.surfaceEnabledDefault
    /// Shown the moment the surface toggle is switched ON, so nobody enables a beta self-custody
    /// wallet without seeing the "keep it small" warning. Cancel reverts the toggle.
    @State private var showBetaEnableConfirm = false

    private var surfaceToggleSection: some View {
        SettingsSection(
            title: "Enable",
            footer: walletSurfaceEnabled
                ? "Shown in the sidebar and the ☰ menu. Turning this off hides the wallet everywhere — your keys and funds are untouched."
                : "The wallet is off. Nothing wallet-related runs or is shown until you enable it."
        ) {
            SettingsToggleRow(
                title: "Show Wallet in Searxly",
                description: "A self-custody crypto wallet is optional — enable it only if you want it.",
                isOn: $walletSurfaceEnabled,
                badge: "Beta",
                badgeTint: SettingsTheme.warning
            )
        }
        .onChange(of: walletSurfaceEnabled) { wasOn, isOn in
            // Warn ONLY on a fresh enable (not on the cancel-revert, and not when toggling off).
            if isOn && !wasOn { showBetaEnableConfirm = true }
        }
        .confirmationDialog(
            "Enable the wallet? It's in beta.",
            isPresented: $showBetaEnableConfirm,
            titleVisibility: .visible
        ) {
            Button("Enable Wallet") { }   // already on — just dismiss
            Button("Cancel", role: .cancel) { walletSurfaceEnabled = false }
        } message: {
            Text("The Searxly wallet is fully self-custody — you alone hold the keys, and no one (not even Searxly) can recover funds for you. It's still BETA software: don't store large amounts here yet, keep only small funds while it matures, and write down your 12-word recovery phrase the moment you create a wallet — it's the only way back in.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            headerBlock
            SettingsCallout(
                title: "Experimental — beta software",
                message: "The wallet is fully self-custody and has been audited, but it is still in beta. Be cautious: keep only small amounts here while it matures, and always write down your recovery phrase.",
                tint: SettingsTheme.warning,
                systemImage: "exclamationmark.triangle.fill"
            )
            surfaceToggleSection
            if walletSurfaceEnabled {
                statusSection
                networksSection
                if isSetup {
                    securitySection
                    privacySection
                    walletConnectSection
                }
                featuresSection
                if isSetup { backupSection }
                if isSetup { dangerSection }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .onAppear {
            customRPC = wallet.customRPCURL
            basescanKey = WalletFeatures.basescanAPIKey
            zeroExKey = WalletFeatures.zeroExAPIKey
            wcProjectId = wc.projectId
        }
        .onChange(of: basescanKey) { _, v in WalletFeatures.basescanAPIKey = v }
        .onChange(of: zeroExKey) { _, v in
            WalletFeatures.zeroExAPIKey = v
            // Adding a 0x key is a clear intent to swap — enable the feature so the user doesn't
            // have to flip two switches.
            if !v.trimmingCharacters(in: .whitespaces).isEmpty && !swaps { swaps = true }
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteWalletSheet(
                // Normally PIN-gated (anti-accident). But if the seed can't be read at all (a storage /
                // Secure-Enclave failure), requiring a PIN that can never succeed would trap the user —
                // so in that case allow the delete without a PIN. No funds are at risk: an unreadable
                // seed can't sign anyway, and the recovery code / 12-word phrase still restores.
                requiresPIN: WalletKeychain.seedCiphertextReadable(),
                onCancel: { showDeleteConfirm = false },
                onConfirmed: { wallet.deleteWallet(); showDeleteConfirm = false }
            )
        }
        .sheet(isPresented: $showRevealPhrase) {
            RevealRecoveryPhraseSheet(onClose: { showRevealPhrase = false })
        }
        .sheet(isPresented: $showChangeSecret) {
            ChangeSecretSheet()
        }
        .sheet(isPresented: $showApprovals) {
            WalletApprovalsSheet(onClose: { showApprovals = false })
        }
        .alert("Enable \(WalletBiometric.label)", isPresented: $showBiometricSetup) {
            SecureField("Enter your PIN", text: $biometricPIN)
            Button("Enable") {
                biometricError = !wallet.enableBiometricUnlock(pin: biometricPIN)
                biometricPIN = ""
            }
            Button("Cancel", role: .cancel) { biometricPIN = ""; biometricError = false }
        } message: {
            Text(biometricError
                 ? "Incorrect PIN. Try again."
                 : "Confirm your PIN to enable biometric unlock.")
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                WalletBillfoldMark(color: .secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text("Searxly Wallet")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        SettingsBadge(text: "Beta", tint: SettingsTheme.warning)
                    }
                    Text("Multi-chain · self-custody")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            }
            Text("A private crypto wallet built into Searxly. Your keys are encrypted and never leave this Mac — no account, no company can touch your funds but you.")
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // The flip side of self-custody, stated where the wallet introduces itself rather than
            // only in Settings ▸ Legal: nobody can undo a mistake for you, and Searxly is not a
            // broker, exchange, or adviser. Nothing here is financial advice.
            Text("Because it's self-custody, transactions are irreversible and lost recovery phrases can't be restored — by us or anyone. Searxly isn't a broker, exchange, or financial adviser, and nothing in the wallet is financial advice. See Settings ▸ Legal.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        SettingsSection(title: "Status") {
            switch wallet.unlockState {
            case .notSetup:
                statusRow(icon: "exclamationmark.circle", label: "Not set up", color: SettingsTheme.textSecondary)
                Text("Open the wallet from the sidebar to set it up.")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.textSecondary)
            case .locked:
                statusRow(icon: "lock.fill", label: "Locked", color: SettingsTheme.warning)
                if let address = wallet.activeAddress { addressRow(address) }
            case .unlocked:
                statusRow(icon: "lock.open.fill", label: "Unlocked", color: SettingsTheme.green)
                if let address = wallet.activeAddress { addressRow(address) }
                SettingsActionChip(title: "Lock wallet", systemImage: "lock") { wallet.lock() }
                    .fixedSize()
            }
        }
    }

    // MARK: - Networks

    private var networksSection: some View {
        SettingsSection(title: "Networks",
                        footer: "The same address works on every network — switch from the network button in the wallet.") {
            SettingsLabeledField(title: "Supported networks",
                                 description: "\(WalletChain.all.count) EVM networks.") {
                VStack(spacing: 9) {
                    ForEach(WalletChain.all) { chain in
                        HStack(spacing: 9) {
                            ChainMark(chainId: chain.id, size: 20)
                            Text(chain.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(SettingsTheme.textPrimary)
                            Spacer()
                            Text(chain.nativeSymbol)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SettingsTheme.textTertiary)
                        }
                    }
                }
            }

            SettingsDivider()

            SettingsLabeledField(title: "Custom RPC (privacy)",
                                 description: "By default Searxly uses \(WalletConfig.defaultRPCURLs.first ?? "mainnet.base.org"). Point to your own node to avoid any third-party RPC.") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://your-node.example.com", text: $customRPC)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    HStack(spacing: 8) {
                        SettingsActionChip(title: "Save") {
                            wallet.customRPCURL = customRPC.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .fixedSize()
                        .disabled(customRPC.trimmingCharacters(in: .whitespaces) == wallet.customRPCURL)
                        if !wallet.customRPCURL.isEmpty {
                            SettingsActionChip(title: "Reset") { wallet.customRPCURL = ""; customRPC = "" }
                                .fixedSize()
                        }
                    }
                    if !wallet.customRPCURL.isEmpty {
                        Text("Using: \(wallet.customRPCURL)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SettingsTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        SettingsSection(title: "Security") {
            if wallet.biometricAvailable {
                SettingsToggleRow(title: "Unlock with \(WalletBiometric.label)",
                                  description: "Also required to authorize every signature and transaction.",
                                  isOn: biometricBinding)
            } else {
                Text("Biometrics are unavailable on this Mac. The wallet uses your \(WalletFeatures.usesPassphrase ? "passphrase" : "6-digit PIN").")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            SettingsPickerRow(title: "Auto-lock",
                              description: "Re-lock the wallet after you stop using it, so it's never left open.",
                              selection: autoLockBinding) {
                Picker("", selection: autoLockBinding) {
                    ForEach(WalletAutoLock.allCases) { opt in Text(opt.label).tag(opt) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsDivider()

            SettingsProminentAction(title: "Change PIN / passphrase", systemImage: "lock.rotation") {
                showChangeSecret = true
            }
        }
    }

    // MARK: - Privacy & connections

    private var privacySection: some View {
        SettingsSection(title: "Privacy & Connections") {
            SettingsToggleRow(title: "Let websites connect to your wallet",
                              description: "Exposes window.ethereum so dApps can request a connection. Turn off to hide the wallet from every site (more private; sites can't detect it).",
                              isOn: $dappProvider)
            SettingsToggleRow(title: "Use a fresh address for each website",
                              description: "Every dApp gets its own dedicated address, so sites can't be linked to one identity. Same recovery phrase restores everything.",
                              isOn: $rotatePerDApp)

            SettingsDivider()

            SettingsProminentAction(title: "Manage token approvals", systemImage: "checkmark.shield") {
                showApprovals = true
            }
            Text("See which sites can move your tokens and revoke any you don't recognise — the main way funds get drained.")
                .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsDivider()

            Text("Connected sites")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(SettingsTheme.textPrimary)
            if permissions.connectedOrigins.isEmpty {
                Text("No sites are connected. When a dApp in Searxly connects, it appears here.")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.textSecondary)
            } else {
                ForEach(permissions.connectedOrigins, id: \.self) { origin in connectedSiteRow(origin) }
            }
        }
    }

    private func connectedSiteRow(_ origin: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(SettingsTheme.textSecondary)
            Text(origin.replacingOccurrences(of: "https://", with: ""))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(SettingsTheme.textPrimary).lineLimit(1)
            if let label = accountLabel(for: origin) {
                Text("· \(label)").font(.system(size: 11)).foregroundStyle(SettingsTheme.textTertiary).lineLimit(1)
            }
            Spacer()
            SettingsActionChip(title: "Disconnect") {
                permissions.disconnect(origin)
                WalletProviderBridge.shared.emitAccountsChanged([])
            }
            .fixedSize()
        }
    }

    // MARK: - WalletConnect

    private var walletConnectSection: some View {
        SettingsSection(title: "WalletConnect",
                        footer: "Connect to apps that aren't open in Searxly (mobile dApps and other sites) by pasting their link.") {
            SettingsToggleRow(title: "Enable WalletConnect",
                              description: "Pair with apps via a WalletConnect link.",
                              isOn: wcEnabledBinding)

            if wc.enabled {
                SettingsCallout(title: "Not fully private",
                                message: "WalletConnect routes through a public relay that sees connection metadata and your IP. Message contents stay end-to-end encrypted and your keys never leave this device.",
                                tint: SettingsTheme.warning)

                SettingsLabeledField(title: "WalletConnect project id",
                                     description: "Free, from cloud.walletconnect.com") {
                    HStack(spacing: 8) {
                        SecureField("Paste project id…", text: $wcProjectId)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        SettingsActionChip(title: "Save") { wc.projectId = wcProjectId }.fixedSize()
                    }
                }

                SettingsLabeledField(title: "Connect with a link",
                                     description: wc.status.isEmpty ? nil : wc.status) {
                    HStack(spacing: 8) {
                        TextField("wc:…", text: $wcURI)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        SettingsActionChip(title: "Connect", disabled: !wcURI.hasPrefix("wc:")) {
                            let u = wcURI; wcURI = ""
                            Task { await wc.pair(uri: u) }
                        }
                        .fixedSize()
                    }
                }

                ForEach(wc.sessions) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(SettingsTheme.textSecondary)
                        Text(s.name).font(.system(size: 12)).foregroundStyle(SettingsTheme.textPrimary).lineLimit(1)
                        Spacer()
                        SettingsActionChip(title: "Disconnect") { wc.disconnect(topic: s.topic) }.fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        SettingsSection(title: "Features",
                        footer: "Off by default for privacy. Each uses the external service named; turning one on is the only time Searxly contacts it.") {
            SettingsToggleRow(title: "Notify on received funds",
                              description: "Local alert when an address receives — no new data leaves your device.",
                              isOn: $incomingAlerts)
            SettingsToggleRow(title: "Full transaction history",
                              description: "Incoming + outgoing history via a block explorer.",
                              isOn: $fullHistory)
            SettingsToggleRow(title: "Auto-discover tokens",
                              description: "Detects tokens you hold.",
                              isOn: $tokenDiscovery)
            SettingsToggleRow(title: "ENS (.eth) name resolution",
                              description: "Resolves .eth names via Ethereum mainnet.",
                              isOn: $ens)
            SettingsToggleRow(title: "Swaps",
                              description: "In-wallet swaps through the 0x aggregator, using your own API key.",
                              isOn: $swaps)
            SettingsToggleRow(title: "Buy crypto",
                              description: "Card on-ramp widget (Onramper).",
                              isOn: $buy)
            SettingsToggleRow(title: "Price charts",
                              description: "In-app token charts. Data is keyed by the token's address — your wallet address is never sent.",
                              isOn: $priceCharts)

            if fullHistory || tokenDiscovery {
                SettingsDivider()
                SettingsLabeledField(title: "Etherscan API key (optional — not required)") {
                    SecureField("Paste key…", text: $basescanKey)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                }
            }
            if swaps {
                SettingsLabeledField(title: "0x API key (required — your own key, used directly)") {
                    SecureField("Paste key…", text: $zeroExKey)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                }
            }

            SettingsDivider()

            SettingsPickerRow(title: "Default network fee", selection: gasSpeedBinding) {
                Picker("", selection: gasSpeedBinding) {
                    ForEach(GasSpeed.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            SettingsPickerRow(title: "Display currency",
                              description: "Non-USD fetches an exchange rate from frankfurter.app. No wallet data is sent.",
                              selection: fiatBinding) {
                Picker("", selection: fiatBinding) {
                    ForEach(FiatCurrency.allCases) { c in Text(c.label).tag(c) }
                }
                .labelsHidden().frame(width: 120)
            }
        }
    }

    // MARK: - Backup & recovery

    private var backupSection: some View {
        SettingsSection(title: "Backup & Recovery",
                        footer: "Confirm it's you, then view your 12 words or save a password-encrypted backup file. Make sure no one is watching.") {
            SettingsProminentAction(title: "Show recovery phrase or save a backup", systemImage: "eye") {
                showRevealPhrase = true
            }
        }
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        SettingsSection(title: "Danger Zone",
                        footer: "Your seed phrase can restore the wallet elsewhere — but if you didn't back it up, access is gone permanently.") {
            SettingsActionChip(title: "Delete wallet from this device", systemImage: "trash", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    // MARK: - Bindings

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { wallet.biometricUnlockEnabled },
            set: { on in
                if on { showBiometricSetup = true }     // enabling needs PIN confirmation
                else { wallet.disableBiometricUnlock() }
            }
        )
    }

    private var gasSpeedBinding: Binding<GasSpeed> {
        Binding(get: { WalletFeatures.defaultGasSpeed }, set: { WalletFeatures.defaultGasSpeed = $0 })
    }

    private var fiatBinding: Binding<FiatCurrency> {
        Binding(get: { wallet.fiatCurrency }, set: { wallet.fiatCurrency = $0 })
    }

    private var wcEnabledBinding: Binding<Bool> {
        Binding(get: { wc.enabled }, set: { wc.enabled = $0 })
    }

    private var autoLockBinding: Binding<WalletAutoLock> {
        Binding(get: { wallet.autoLock }, set: { wallet.autoLock = $0 })
    }

    // MARK: - Small rows

    @ViewBuilder
    private func statusRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func addressRow(_ address: String) -> some View {
        HStack(spacing: 6) {
            Text(abbreviated(address))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(SettingsTheme.textSecondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(SettingsTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy address")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(SettingsTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(SettingsTheme.textPrimary)
        }
    }

    private func abbreviated(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    /// The account a connected origin uses — shown only when there's more than one account.
    private func accountLabel(for origin: String) -> String? {
        guard wallet.accounts.count > 1, let idx = permissions.accountIndex(for: origin) else { return nil }
        return wallet.accounts.first { $0.index == idx }?.label
    }
}
