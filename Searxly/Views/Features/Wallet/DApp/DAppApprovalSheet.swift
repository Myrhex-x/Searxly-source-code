//
//  DAppApprovalSheet.swift
//  Searxly
//
//  The approval prompt a dApp triggers (connect / sign / send). Origin-bound and,
//  for signing, biometric-or-PIN gated. Matches the wallet's black & white design.
//

import SwiftUI

/// Invisible host that presents the dApp approval sheet whenever the provider bridge
/// has a pending request. Mounted once at the ContentView level.
struct DAppApprovalHost: View {
    @State private var bridge = WalletProviderBridge.shared

    var body: some View {
        Color.clear
            // Read-only binding: the sheet is resolved ONLY via its own Cancel/Approve buttons
            // (each calls approval.decide exactly once). The setter is intentionally inert so that
            // SwiftUI re-presenting the next queued approval can't accidentally reject it.
            .sheet(item: Binding<DAppApproval?>(get: { bridge.pendingApproval }, set: { _ in })) { approval in
                DAppApprovalSheet(approval: approval)
            }
    }
}

struct DAppApprovalSheet: View {
    let approval: DAppApproval

    @State private var wallet = WalletManager.shared
    @State private var pin = ""
    @State private var pinError = false
    @State private var processing = false
    @State private var sim: WalletNetwork.SimResult? = nil
    @State private var simLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            ScrollView { content.padding(20) }
        }
        .frame(width: 380)
        .frame(minHeight: 420, maxHeight: 620)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)   // resolve only via Cancel/Approve so nothing is left hanging
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            SearxlyWalletBadge(size: 40, cornerRadius: 11, glassEnabled: true)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(WalletTheme.textTertiary)
                Text(displayOrigin)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Requesting site")
            .accessibilityValue(displayOrigin)
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch approval.kind {
        case .connect:       return "Connection Request"
        case .signMessage:   return "Signature Request"
        case .signTypedData: return "Signature Request"
        case .transaction:   return "Transaction Request"
        case .switchChain:   return "Switch Network"
        }
    }

    private var displayOrigin: String {
        approval.origin.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 16) {
            if let warn = approval.phishingWarning { dangerBanner(warn) }
            switch approval.kind {
            case .connect:
                connectBody
            case .signMessage(let text):
                signBody(detailTitle: "Message", detail: text)
            case .signTypedData(let preview):
                typedDataBody(preview)
            case .transaction(let preview):
                transactionBody(preview)
            case .switchChain(let chainName):
                switchChainBody(chainName)
            }
        }
    }

    private func switchChainBody(_ chainName: String) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 16)).foregroundStyle(WalletTheme.textSecondary)
                Text("This site wants to switch your wallet's network to **\(chainName)**.")
                    .font(.system(size: 13)).foregroundStyle(WalletTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .walletGlass(radius: 12, fill: WalletTheme.surface)

            safetyNote

            HStack(spacing: 10) {
                cancelButton
                Button { approval.decide("") } label: {   // switching needs no key
                    Text("Switch to \(chainName)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Loud red banner for a flagged (likely-scam) origin.
    private func dangerBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 14)).foregroundStyle(WalletTheme.negative)
            VStack(alignment: .leading, spacing: 2) {
                Text("Warning: possible scam site")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(WalletTheme.negative)
                Text(text)
                    .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(WalletTheme.negative.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WalletTheme.negative.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var connectBody: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                permissionRow(icon: "eye", text: "See your wallet address & balance")
                permissionRow(icon: "paperplane", text: "Request approval for transactions you confirm")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .walletGlass(radius: 12, fill: WalletTheme.surface)

            safetyNote

            HStack(spacing: 10) {
                cancelButton
                let risky = approval.phishingWarning != nil
                Button {
                    approval.decide("")   // connect needs no key
                } label: {
                    Text(risky ? "Connect anyway" : "Connect")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(risky ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(risky ? WalletTheme.negative.opacity(0.85) : Color.white,
                                    in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// EIP-712 typed-data request — shows the actual decoded fields the user is signing, plus a loud
    /// warning for unlimited approvals and for a domain chain that doesn't match the active network.
    private func typedDataBody(_ p: TypedDataPreview) -> some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIGNING").font(.system(size: 10, weight: .semibold)).foregroundStyle(WalletTheme.textTertiary)
                Text(p.domainName.map { "\($0) · \(p.primaryType)" } ?? p.primaryType)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if p.chainMismatch {
                warningBanner("This request is for chain \(p.chainId.map(String.init) ?? "?"), but your wallet is on \(p.activeChainName). Only continue if you understand why.")
            }

            if !p.lines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(p.lines.enumerated()), id: \.element.id) { idx, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(WalletTheme.textSecondary)
                                .padding(.leading, CGFloat(line.indent) * 12)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 1) {
                                if !line.value.isEmpty {
                                    Text(line.value)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(line.flag == "UNLIMITED" ? WalletTheme.negative : .white)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                                if let flag = line.flag, flag != "UNLIMITED" {
                                    Text(flag).font(.system(size: 9)).foregroundStyle(WalletTheme.textTertiary)
                                }
                            }
                        }
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        if idx < p.lines.count - 1 { Divider().opacity(0.06) }
                    }
                }
                .walletGlass(radius: 12, fill: WalletTheme.surface)
            }

            if p.hasUnlimited {
                warningBanner("This grants UNLIMITED spending approval by signature. Only continue if you fully trust this site.")
            } else {
                safetyNote
            }
            authSection
        }
    }

    private func signBody(detailTitle: String, detail: String) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detailTitle.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WalletTheme.textTertiary)
                Text(detail.isEmpty ? "(empty)" : detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(14)
            .walletGlass(radius: 12, fill: WalletTheme.surface)

            safetyNote
            authSection
        }
    }

    private func transactionBody(_ preview: TxPreview) -> some View {
        VStack(spacing: 14) {
            // Plain-language summary of what the transaction actually does.
            if let effect = effectLine(preview) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).padding(.top, 1)
                    Text(effect).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12).walletGlass(radius: 12)
            }

            VStack(spacing: 0) {
                detailRow("To", value: abbreviated(preview.to), mono: true,
                          accessibilityValueOverride: "address \(preview.to)")
                Divider().opacity(0.08)
                detailRow("Amount", value: "\(preview.valueEth) \(wallet.activeChain.nativeSymbol)")
                Divider().opacity(0.08)
                detailRow("Network", value: wallet.activeChain.name)
            }
            .walletGlass(radius: 12, fill: WalletTheme.surface)

            simulationStatus

            if preview.isUnlimitedApproval {
                warningBanner("This grants unlimited spending approval. Only continue if you trust this site.")
            } else {
                safetyNote
            }
            authSection
        }
        .task { await runSimulation(preview) }
    }

    // MARK: - Simulation (eth_call dry-run) + calldata decode

    @ViewBuilder
    private var simulationStatus: some View {
        if simLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Simulating transaction…").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            }
        } else if let sim {
            switch sim {
            case .success:
                simLabel("Simulation passed — this should succeed.", icon: "checkmark.seal.fill", color: WalletTheme.positive)
            case .revert(let reason):
                simLabel("Likely to FAIL\(reason == "would fail" ? "" : ": \(reason)") — you'd still pay gas.",
                         icon: "xmark.octagon.fill", color: WalletTheme.negative)
            case .unknown:
                EmptyView()
            }
        }
    }

    private func simLabel(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private func runSimulation(_ p: TxPreview) async {
        guard let from = wallet.activeAddress else { return }
        simLoading = true
        sim = await WalletNetwork.simulateCall(from: from, to: p.to, valueHex: p.valueHex, dataHex: p.dataHex, rpc: wallet.activeRPCURL)
        simLoading = false
    }

    /// Decodes common ERC-20 calldata into a plain-language effect, resolving the token via the
    /// wallet's known list for symbol/decimals. nil when there's nothing meaningful to say.
    private func effectLine(_ p: TxPreview) -> String? {
        let data = p.dataHex ?? "0x"
        guard data.count >= 10 else {
            return p.valueEth == "0" ? nil : "Send \(p.valueEth) ETH"
        }
        let selector = String(data.dropFirst(2).prefix(8)).lowercased()
        let token = wallet.tokens.first { $0.contractAddress?.lowercased() == p.to.lowercased() }
        let sym = token?.symbol ?? "tokens"
        let decimals = token?.decimals ?? 18
        let words = abiWords(data)
        switch selector {
        case "a9059cbb":   // transfer(address,uint256)
            guard words.count >= 2 else { return "Token transfer" }
            return "Send \(formatAmount(words[1], decimals: decimals)) \(sym) to \(abbreviated(addressFromWord(words[0])))"
        case "095ea7b3":   // approve(address,uint256)
            guard words.count >= 2 else { return "Token approval" }
            let amt = p.isUnlimitedApproval ? "Unlimited" : formatAmount(words[1], decimals: decimals)
            return "Allow \(abbreviated(addressFromWord(words[0]))) to spend \(amt) \(sym)"
        default:
            return "Contract call · 0x\(selector)"
        }
    }

    private func abiWords(_ data: String) -> [String] {
        var s = Substring(data.dropFirst(10))   // strip "0x" + 4-byte selector
        var words: [String] = []
        while s.count >= 64 { words.append(String(s.prefix(64))); s = s.dropFirst(64) }
        return words
    }

    private func addressFromWord(_ w: String) -> String { "0x" + String(w.suffix(40)) }

    private func formatAmount(_ word: String, decimals: Int) -> String {
        var v = 0.0
        var s = Substring(word)
        while s.count >= 2 {
            if let b = UInt8(s.prefix(2), radix: 16) { v = v * 256 + Double(b) }
            s = s.dropFirst(2)
        }
        let a = v / pow(10.0, Double(decimals))
        if a == 0 { return "0" }
        if a < 0.0001 { return String(format: "%.8f", a) }
        return String(format: "%.4f", a)
    }

    // MARK: - Auth (biometric + PIN)

    private var authSection: some View {
        VStack(spacing: 12) {
            if processing {
                ProgressView().padding(.vertical, 16)
            } else {
                if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                    Button { authorizeBiometric() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: WalletBiometric.symbol).font(.system(size: 14))
                            Text("Authorize with \(WalletBiometric.label)")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 11)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Text("or enter your PIN").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                } else {
                    Text("Enter your PIN to authorize").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
                }

                if !WalletFeatures.usesPassphrase {
                    HStack(spacing: 12) {
                        ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                            Circle().fill(i < pin.count ? Color.white : WalletTheme.surfaceStrong).frame(width: 11, height: 11)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("PIN entry")
                    .accessibilityValue("\(pin.count) of \(WalletConfig.pinLength) digits entered")
                }
                if pinError {
                    Text("Incorrect").font(.system(size: 12)).foregroundStyle(WalletTheme.negative)
                }
                PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { authorizePIN() }
                    .frame(maxWidth: 220)

                cancelButton
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { approval.decide(nil) }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
    }

    private func authorizePIN() {
        guard pin.count == WalletConfig.pinLength else { return }
        guard wallet.attemptPIN(pin) else { pinError = true; pin = ""; return }
        processing = true
        approval.decide(pin)
    }

    private func authorizeBiometric() {
        Task {
            if let p = await wallet.authorizeSigningWithBiometrics(reason: title) {
                processing = true
                approval.decide(p)
            }
        }
    }

    // MARK: - Bits

    private func permissionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary)
        }
    }

    /// `accessibilityValueOverride` reads the full value to VoiceOver when the visible text is abbreviated.
    private func detailRow(_ label: String, value: String, mono: Bool = false,
                           accessibilityValueOverride: String? = nil) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValueOverride ?? value)
    }

    private var safetyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
            Text("Only approve requests from sites you trust. Searxly never shares your keys.")
                .font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
        }
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(WalletTheme.warning)
            Text(text).font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
        }
        .padding(12)
        .background(WalletTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WalletTheme.warning.opacity(0.25), lineWidth: 0.8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private func abbreviated(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }
}
