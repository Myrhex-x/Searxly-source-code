//
//  AddTokenSheet.swift
//  Searxly
//
//  Add any coin on Base by pasting its contract address. The app reads the token's symbol, name, and
//  decimals straight from the contract over the user's own RPC — no name search, no third-party
//  lookup, no hand-typing four fields. If the address isn't a standard ERC-20, the fields stay
//  editable so it can still be added by hand.
//

import SwiftUI

struct AddTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var wallet = WalletManager.shared

    @State private var address = ""
    @State private var meta: WalletNetwork.TokenMeta?
    @State private var isLoading = false
    @State private var showFields = false        // reveal editable fields (lookup failed, or "Edit")
    @State private var error = ""
    @State private var directory = WalletTokenDirectory.shared
    @FocusState private var focused: Bool

    // Pre-filled from the on-chain read; editable for odd tokens.
    @State private var symbol = ""
    @State private var name = ""
    @State private var decimals = "18"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    addressField

                    if isLoading {
                        statusRow(spinner: true, "Reading token from chain…")
                    } else if let meta, !showFields {
                        previewCard(meta)
                    } else if showFields {
                        detailFields
                    } else if isValidAddress {
                        EmptyView()
                    } else if !query.isEmpty {
                        searchResults
                    } else {
                        hint
                    }

                    if !error.isEmpty {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(error.contains("already") ? WalletTheme.textSecondary
                                                                       : WalletTheme.negative)
                    }

                    actionRow
                }
                .padding(24)
            }
        }
        .frame(width: 420, height: 470)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
        .task(id: address) { await lookup() }
        .onAppear { focused = true; directory.ensureLoaded(chainId: wallet.activeChain.id) }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Coin").font(.system(size: 15, weight: .semibold))
                Text("Search a coin, or paste its address").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { dismiss() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Address field

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search or paste address").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("USDC, ETH… or 0x address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focused)
                Button {
                    address = NSPasteboard.general.string(forType: .string)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? address
                } label: {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Paste")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .walletGlass(radius: 9, fill: WalletTheme.surfaceField)
            if address.hasPrefix("0x") && !isValidAddress {
                Text("A Base address starts with 0x and is 42 characters.")
                    .font(.system(size: 11)).foregroundStyle(WalletTheme.negative)
            }
        }
    }

    // MARK: - States

    private var hint: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Paste the coin's contract address — Searxly reads its name, symbol, and decimals straight from the chain. Find the address on Basescan’s token page.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .walletGlass(radius: 10, fill: WalletTheme.surface)
    }

    private func statusRow(spinner: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            if spinner { ProgressView().controlSize(.small).scaleEffect(0.8) }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func previewCard(_ m: WalletNetwork.TokenMeta) -> some View {
        HStack(spacing: 12) {
            TokenIconView(token: WalletToken(id: address, symbol: m.symbol.isEmpty ? "?" : m.symbol,
                                             name: m.name, contractAddress: address,
                                             decimals: m.decimals, isCustom: true), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.symbol.isEmpty ? "Unknown symbol" : m.symbol)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                Text(m.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(m.decimals) decimals").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
        }
        .padding(14)
        .walletGlass(radius: 12)
    }

    private var detailFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Token Symbol", "e.g. USDC", $symbol)
            field("Token Name", "e.g. USD Coin", $name)
            field("Decimals", "18", $decimals)
        }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .walletGlass(radius: 9, fill: WalletTheme.surfaceField)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }.buttonStyle(.bordered).controlSize(.regular)
            // The bottom "Add" button is only for the paste-an-address path; search results are added
            // by tapping the row itself.
            if isValidAddress || showFields {
                if meta != nil && !showFields {
                    Button("Edit details") { showFields = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(addLabel) { add() }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.regular)
                    .disabled(!canAdd)
            } else {
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Search (find a coin by name, Phantom-style)

    private var query: String { address.trimmingCharacters(in: .whitespaces) }

    @ViewBuilder
    private var searchResults: some View {
        // Don't exclude coins already in the wallet — built-ins like USDC are always "present", so
        // excluding them is exactly why an exact "USDC" search used to return only look-alikes. Tapping
        // a coin you already hold just reveals it (addCustomToken handles the already-tracked case).
        let results = directory.search(query, chainId: wallet.activeChain.id)
        if results.isEmpty {
            let ready = directory.isReady(chainId: wallet.activeChain.id)
            statusRow(spinner: !ready,
                      ready ? "No match. Paste the coin’s 0x contract address to add it."
                            : "Loading coin list…")
        } else {
            VStack(spacing: 8) {
                ForEach(results) { token in
                    Button { addDirectoryToken(token) } label: { directoryRow(token) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func directoryRow(_ t: DirectoryToken) -> some View {
        HStack(spacing: 12) {
            TokenIconView(token: WalletToken(id: t.address, symbol: t.symbol, name: t.name,
                                             contractAddress: t.address, decimals: t.decimals,
                                             isCustom: true, chainId: t.chainId), size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                Text(t.name).font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(WalletTheme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .walletGlass(radius: 12)
        .contentShape(Rectangle())
    }

    private func addDirectoryToken(_ t: DirectoryToken) {
        wallet.addCustomToken(contractAddress: t.address, symbol: t.symbol, name: t.name, decimals: t.decimals)
        dismiss()
    }

    // MARK: - Logic

    private func lookup() async {
        let a = address.trimmingCharacters(in: .whitespaces)
        meta = nil; error = ""; showFields = false
        guard isValidAddress else { isLoading = false; return }
        if alreadyAdded { error = "This coin is already in your wallet."; isLoading = false; return }
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce paste/typing
        if Task.isCancelled { return }
        isLoading = true
        let m = await WalletNetwork.tokenMetadata(contract: a, rpc: wallet.activeRPCURL)
        if Task.isCancelled { return }
        isLoading = false
        if let m {
            meta = m
            symbol = m.symbol; name = m.name; decimals = String(m.decimals)
        } else {
            showFields = true
            error = "Couldn't read this token automatically — enter its details below, or double-check the address."
        }
    }

    private func add() {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard isValidAddress, let dec = Int(decimals) else { error = "Enter a valid address and decimals."; return }
        if alreadyAdded { error = "This coin is already in your wallet."; return }
        let sym = symbol.trimmingCharacters(in: .whitespaces).isEmpty ? "TOKEN" : symbol.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces).isEmpty ? sym : name.trimmingCharacters(in: .whitespaces)
        wallet.addCustomToken(contractAddress: a, symbol: sym, name: nm, decimals: dec)
        dismiss()
    }

    // MARK: - Derived

    private var isValidAddress: Bool {
        let a = address.trimmingCharacters(in: .whitespaces)
        return a.hasPrefix("0x") && a.count == 42
    }

    private var alreadyAdded: Bool {
        wallet.tokens.contains { $0.contractAddress?.lowercased() == address.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private var addLabel: String {
        if let s = meta?.symbol, !s.isEmpty, !showFields { return "Add \(s)" }
        return "Add Coin"
    }

    private var canAdd: Bool {
        guard isValidAddress, Int(decimals) != nil, !alreadyAdded else { return false }
        if meta != nil && !showFields { return true }
        return !symbol.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
