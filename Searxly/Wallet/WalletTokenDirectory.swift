//
//  WalletTokenDirectory.swift
//  Searxly
//
//  A searchable directory of well-known coins per chain, so the user can find a coin by typing its
//  name ("USDC") — Phantom-style — instead of pasting a contract address, and so token rows can show
//  each coin's REAL logo. The data is the standard Uniswap-format token list CoinGecko publishes per
//  chain (verified contract addresses + logo URLs). CoinGecko is already the wallet's price source, so
//  this adds no new third party. The list is cached to disk and refreshed at most once a day.
//
//  Privacy: the list request is keyed only by the chain (no wallet address). Logos load from CoinGecko's
//  asset CDN, keyed only by a PUBLIC contract — the same surface as the live prices already fetched.
//

import Foundation
import Observation

/// One coin in the directory (a row of the CoinGecko token list).
struct DirectoryToken: Codable, Identifiable, Equatable {
    let chainId: Int
    let address: String
    let name: String
    let symbol: String
    let decimals: Int
    let logoURI: String?

    var id: String { "\(chainId):\(address.lowercased())" }
}

@MainActor
@Observable
final class WalletTokenDirectory {
    static let shared = WalletTokenDirectory()
    private init() {}

    /// Loaded directory per chain id. Reading this in a view body subscribes the view, so logos/search
    /// results fill in automatically the moment a chain's list finishes loading.
    private(set) var tokensByChain: [Int: [DirectoryToken]] = [:]
    private var inFlight: Set<Int> = []

    /// DexScreener logo fallback for coins not in the CoinGecko list. contract(lowercased) → image URL,
    /// or "" once checked and found to have none (so it isn't re-fetched).
    private var dexLogos: [String: String] = [:]
    private var dexInFlight: Set<String> = []

    /// CoinGecko "asset platform" slug for a chain id — the path segment of its token list.
    private func listSlug(forChain id: Int) -> String? {
        switch id {
        case 8453:  return "base"
        case 1:     return "ethereum"
        case 10:    return "optimistic-ethereum"
        case 42161: return "arbitrum-one"
        case 137:   return "polygon-pos"
        default:    return nil
        }
    }

    /// True once a chain's list is available (from disk or network).
    func isReady(chainId: Int) -> Bool { tokensByChain[chainId] != nil }

    // MARK: - Loading

    /// Loads a chain's directory if needed: instantly from the disk cache, then refreshes from the
    /// network when the cache is missing or older than a day. Idempotent — safe to call from every
    /// token icon's `onAppear`.
    func ensureLoaded(chainId: Int) {
        guard listSlug(forChain: chainId) != nil, !inFlight.contains(chainId) else { return }

        // 1) Disk cache → instant, offline-friendly.
        if tokensByChain[chainId] == nil,
           let url = cacheURL(forChain: chainId),
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode([DirectoryToken].self, from: data),
           !cached.isEmpty {
            tokensByChain[chainId] = cached
        }

        // 2) Refresh from the network when missing or stale (>24h).
        let age = cacheAge(forChain: chainId)
        let stale = age == nil || age! > 86_400
        guard tokensByChain[chainId] == nil || stale else { return }
        inFlight.insert(chainId)
        Task { await refresh(chainId: chainId) }
    }

    private func refresh(chainId: Int) async {
        defer { inFlight.remove(chainId) }
        guard let slug = listSlug(forChain: chainId),
              let url = URL(string: "https://tokens.coingecko.com/\(slug)/all.json"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        // Uniswap token-list schema: { "tokens": [ { chainId, address, name, symbol, decimals, logoURI } ] }.
        struct ListFile: Decodable { let tokens: [DirectoryToken] }
        guard let parsed = try? JSONDecoder().decode(ListFile.self, from: data) else { return }
        let onChain = parsed.tokens.filter { $0.chainId == chainId }
        guard !onChain.isEmpty else { return }

        tokensByChain[chainId] = onChain
        if let cache = cacheURL(forChain: chainId), let encoded = try? JSONEncoder().encode(onChain) {
            try? encoded.write(to: cache, options: .atomic)
        }
    }

    // MARK: - Queries

    /// Up to `limit` coins matching `query` by symbol/name, ranked: exact symbol → symbol-prefix →
    /// name-prefix → contains. Skips coins already in the wallet (`excluding`, lowercased contracts).
    func search(_ query: String, chainId: Int, excluding: Set<String> = [], limit: Int = 20) -> [DirectoryToken] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let all = tokensByChain[chainId] else { return [] }

        func rank(_ t: DirectoryToken) -> Int {
            let sym = t.symbol.lowercased(), name = t.name.lowercased()
            if sym == q { return 0 }
            if sym.hasPrefix(q) { return 1 }
            if name.hasPrefix(q) { return 2 }
            if sym.contains(q) || name.contains(q) { return 3 }
            return 99
        }

        return all
            .filter { !excluding.contains($0.address.lowercased()) && rank($0) < 99 }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if a.symbol.count != b.symbol.count { return a.symbol.count < b.symbol.count }
                return a.symbol.lowercased() < b.symbol.lowercased()
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The real logo URL for a contract on a chain, if the directory knows it.
    func logoURI(chainId: Int, contract: String) -> String? {
        tokensByChain[chainId]?.first { $0.address.lowercased() == contract.lowercased() }?.logoURI
    }

    // MARK: - Logo resolution (CoinGecko list → DexScreener fallback)

    /// The best logo URL for a contract: the CoinGecko list logo (crisp `/large/` variant) when listed,
    /// else a DexScreener image once it's been fetched. Pure read — call `ensureLogo` to trigger the
    /// fetch. Returns nil until something resolves (the icon shows its drawn mark meanwhile).
    func resolvedLogo(chainId: Int, contract: String) -> String? {
        if let uri = logoURI(chainId: chainId, contract: contract) {
            return uri.replacingOccurrences(of: "/thumb/", with: "/large/")
        }
        let dex = dexLogos[contract.lowercased()]
        return (dex?.isEmpty == false) ? dex : nil
    }

    /// Ensures a coin's logo can resolve: loads the chain list, and if the coin isn't in CoinGecko's
    /// list, fetches its logo from DexScreener (which covers essentially every traded coin). Call from
    /// a view's `.task` — never from `body` — so it doesn't mutate observed state mid-render.
    func ensureLogo(chainId: Int, contract: String?) async {
        ensureLoaded(chainId: chainId)
        guard let contract else { return }                  // native coin → no contract to look up
        if logoURI(chainId: chainId, contract: contract) != nil { return }
        if !isReady(chainId: chainId) {                     // give the cold first-load a moment
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if logoURI(chainId: chainId, contract: contract) == nil {
            await fetchDexLogo(contract: contract)
        }
    }

    private func fetchDexLogo(contract: String) async {
        let key = contract.lowercased()
        guard dexLogos[key] == nil, !dexInFlight.contains(key) else { return }
        dexInFlight.insert(key)
        defer { dexInFlight.remove(key) }
        dexLogos[key] = await Self.dexScreenerImageURL(contract: key) ?? ""   // "" = checked, none found
    }

    /// The token image DexScreener has for a contract (the logo the project uploaded), if any.
    private static func dexScreenerImageURL(contract: String) async -> String? {
        guard let url = URL(string: "https://api.dexscreener.com/latest/dex/tokens/\(contract)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairs = json["pairs"] as? [[String: Any]] else { return nil }
        for pair in pairs {
            if let info = pair["info"] as? [String: Any],
               let img = info["imageUrl"] as? String, !img.isEmpty {
                return img
            }
        }
        return nil
    }

    // MARK: - Disk cache

    private func cacheURL(forChain id: Int) -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("SearxlyWallet", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("tokenlist-\(id).json")
    }

    private func cacheAge(forChain id: Int) -> TimeInterval? {
        guard let url = cacheURL(forChain: id),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }
}
