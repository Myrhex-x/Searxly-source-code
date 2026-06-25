//
//  WalletSettingsSection.swift
//  Searxly
//
//  Content for the Wallet pane in Settings.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 11) {
                    // Same wallet glyph as the sidebar button — one icon for the whole feature.
                    WalletBillfoldMark(color: .secondary)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Searxly Wallet")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Base L2 · \(WalletConfig.searxlyTokenSymbol) token")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                Text("A private crypto wallet built into Searxly. Your keys are encrypted and never leave this Mac — no account, no company can touch your funds but you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Wallet status
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Status")

                switch wallet.unlockState {
                case .notSetup:
                    statusRow(icon: "exclamationmark.circle", label: "Not set up", color: .secondary)
                    Text("Open the wallet from the sidebar to set up your wallet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                case .locked:
                    statusRow(icon: "lock.fill", label: "Locked", color: WalletTheme.warning)
                    if let address = wallet.activeAddress {
                        addressRow(address)
                    }

                case .unlocked:
                    statusRow(icon: "lock.open.fill", label: "Unlocked", color: SERPDesign.accentGreen)
                    if let address = wallet.activeAddress {
                        addressRow(address)
                    }
                    Button("Lock Wallet") { wallet.lock() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Divider()

            // Token info
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("$SEARXLY Token")

                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Contract", value: abbreviated(WalletConfig.searxlyTokenAddress))
                    infoRow("Network", value: WalletConfig.baseChainName)
                    infoRow("Decimals", value: "\(WalletConfig.searxlyTokenDecimals)")
                }

                Button {
                    if let url = URL(string: "\(WalletConfig.explorerBaseURL)/token/\(WalletConfig.searxlyTokenAddress)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("View on Basescan", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Custom RPC
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Privacy: Custom RPC")

                Text("By default Searxly uses \(WalletConfig.defaultRPCURLs.first ?? "mainnet.base.org"). Set your own private node to avoid relying on any third-party RPC provider.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("https://your-node.example.com", text: $customRPC)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button("Save") {
                        wallet.customRPCURL = customRPC.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(customRPC.trimmingCharacters(in: .whitespaces) == wallet.customRPCURL)

                    if !wallet.customRPCURL.isEmpty {
                        Button("Reset") {
                            wallet.customRPCURL = ""
                            customRPC = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !wallet.customRPCURL.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(WalletTheme.textSecondary)
                            .font(.system(size: 11))
                        Text("Using: \(wallet.customRPCURL)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if wallet.unlockState != .notSetup {
                Divider()

                // Security — biometric unlock
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Security")
                    if wallet.biometricAvailable {
                        Toggle(isOn: biometricBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock with \(WalletBiometric.label)")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Also required to authorize every signature and transaction.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    } else {
                        Text("Biometrics are unavailable on this Mac. The wallet uses your \(WalletFeatures.usesPassphrase ? "passphrase" : "6-digit PIN").")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }

                    // Change the unlock secret — and switch between a 6-digit PIN and a stronger passphrase.
                    Button {
                        showChangeSecret = true
                    } label: {
                        Label("Change PIN / passphrase", systemImage: "lock.rotation")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("A passphrase is far harder to brute-force than a 6-digit PIN. Your recovery phrase is unaffected.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $dappProvider) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Let websites connect to your wallet")
                                .font(.system(size: 13, weight: .medium))
                            Text("Exposes window.ethereum so dApps can request a connection. Turn off to hide the wallet from every site (more private; sites can't detect it).")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    // Per-dApp rotating addresses (unlinkability)
                    Toggle(isOn: $rotatePerDApp) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use a fresh address for each website")
                                .font(.system(size: 13, weight: .medium))
                            Text("Every dApp you connect gets its own dedicated address, so sites can't be linked to one identity. Funds for a site land on its address; switch to it from Accounts to use them. Same recovery phrase restores everything.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    // Auto-lock
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-lock")
                                .font(.system(size: 13, weight: .medium))
                            Text("Re-lock the wallet after you stop using it, so it's never left open.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Picker("", selection: autoLockBinding) {
                            ForEach(WalletAutoLock.allCases) { opt in Text(opt.label).tag(opt) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }

                    // Token approvals — review & revoke what can move your tokens
                    Button {
                        showApprovals = true
                    } label: {
                        Label("Manage token approvals", systemImage: "checkmark.shield")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("See which sites can move your tokens and revoke any you don't recognise — the main way funds get drained.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Reveal recovery phrase (re-show the 12 words, gated by biometric/PIN)
                    Button {
                        showRevealPhrase = true
                    } label: {
                        Label("Show recovery phrase or save a backup", systemImage: "eye")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("Confirm it's you, then view your 12 words or save a password-encrypted backup file. Make sure no one is watching.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Connected sites
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Connected Sites")
                    if permissions.connectedOrigins.isEmpty {
                        Text("No sites are connected. When a dApp in Searxly connects to your wallet, it appears here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(permissions.connectedOrigins, id: \.self) { origin in
                            HStack {
                                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(origin.replacingOccurrences(of: "https://", with: ""))
                                    .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                if let label = accountLabel(for: origin) {
                                    Text("· \(label)")
                                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                                Button("Disconnect") {
                                    permissions.disconnect(origin)
                                    WalletProviderBridge.shared.emitAccountsChanged([])
                                }
                                .buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                    }
                }

                Divider()

                // WalletConnect (opt-in, off by default)
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("WalletConnect")
                    Toggle(isOn: wcEnabledBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable WalletConnect")
                                .font(.system(size: 13, weight: .medium))
                            Text("Connect to apps that aren't open in Searxly (mobile dApps and other sites) by pasting their WalletConnect link.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    if wc.enabled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(WalletTheme.warning).padding(.top, 1)
                            Text("Not fully private: WalletConnect routes through a public relay server that sees connection metadata and your IP. Message contents stay end-to-end encrypted and your keys never leave this device.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(WalletTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("WalletConnect project id (free, from cloud.walletconnect.com)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                SecureField("Paste project id…", text: $wcProjectId)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                                Button("Save") { wc.projectId = wcProjectId }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Paste a WalletConnect link to connect")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                TextField("wc:…", text: $wcURI)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                                Button("Connect") {
                                    let u = wcURI; wcURI = ""
                                    Task { await wc.pair(uri: u) }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(!wcURI.hasPrefix("wc:"))
                            }
                            if !wc.status.isEmpty {
                                Text(wc.status).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }

                        if !wc.sessions.isEmpty {
                            ForEach(wc.sessions) { s in
                                HStack {
                                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(s.name).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Button("Disconnect") { wc.disconnect(topic: s.topic) }
                                        .buttonStyle(.bordered).controlSize(.mini)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            // Wallet features (hybrid privacy — all off by default)
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Wallet Features")
                Text("Off by default for privacy. Each uses an external service named below; turning one on is the only time Searxly contacts it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                featureToggle($incomingAlerts, "Notify on received funds", "Local alert when an address receives — no new data leaves your device")
                featureToggle($fullHistory, "Full transaction history", "Incoming + outgoing transaction history")
                featureToggle($tokenDiscovery, "Auto-discover tokens", "Detects tokens you hold")
                featureToggle($ens, "ENS (.eth) name resolution", "Resolves .eth names via Ethereum mainnet")
                featureToggle($swaps, "Swaps", "In-wallet token swaps via the 0x API")
                featureToggle($buy, "Buy crypto", "Card on-ramp widget (Onramper)")

                if fullHistory || tokenDiscovery {
                    apiKeyField("Etherscan API key (optional — not required)", text: $basescanKey)
                }
                if swaps {
                    apiKeyField(SearxlyGateway.isConfigured
                                ? "0x API key (optional — Searxly provides one)"
                                : "0x API key (required for swaps)", text: $zeroExKey)
                }

                // Default gas speed
                HStack {
                    Text("Default network fee").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: gasSpeedBinding) {
                        ForEach(GasSpeed.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                }

                // Display currency
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Display currency").font(.system(size: 13))
                        Text("Non-USD fetches an exchange rate from an external service (frankfurter.app). No wallet data is sent.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("", selection: fiatBinding) {
                        ForEach(FiatCurrency.allCases) { c in Text(c.label).tag(c) }
                    }
                    .frame(width: 110).labelsHidden()
                }

                // Price charts (a display feature — on by default). Chart data uses the same public
                // price APIs (keyed by the token/pool address) the live price already does.
                featureToggle($priceCharts, "Price charts",
                              "In-app token charts. Data is keyed by the token's address — your wallet address is never sent.")
            }

            if wallet.unlockState != .notSetup {
                Divider()

                // Danger zone
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Danger Zone")

                    Text("Deleting your wallet removes it from this device. Your seed phrase can restore it elsewhere — but if you didn't back it up, access is gone permanently.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Wallet from This Device", systemImage: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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

    // MARK: - Feature helpers

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
        Binding(
            get: { WalletFeatures.defaultGasSpeed },
            set: { WalletFeatures.defaultGasSpeed = $0 }
        )
    }

    private var fiatBinding: Binding<FiatCurrency> {
        Binding(
            get: { wallet.fiatCurrency },
            set: { wallet.fiatCurrency = $0 }
        )
    }

    private var wcEnabledBinding: Binding<Bool> {
        Binding(get: { wc.enabled }, set: { wc.enabled = $0 })
    }

    private var autoLockBinding: Binding<WalletAutoLock> {
        Binding(
            get: { wallet.autoLock },
            set: { wallet.autoLock = $0 }
        )
    }

    @ViewBuilder
    private func featureToggle(_ binding: Binding<Bool>, _ title: String, _ subtitle: String) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func apiKeyField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            SecureField("Paste key…", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.leading, 4)
    }

    // MARK: - Sub-components

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }

    @ViewBuilder
    private func statusRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func addressRow(_ address: String) -> some View {
        HStack(spacing: 6) {
            Text(abbreviated(address))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy address")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
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
