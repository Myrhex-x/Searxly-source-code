//
//  WalletConfig.swift
//  Searxly
//
//  Static constants for the Searxly embedded wallet (Base L2).
//

import Foundation

enum WalletConfig {
    // MARK: - $SEARXLY token (Base mainnet)
    static let searxlyTokenAddress   = "0x0fdc79b868bc4a6295cd94397f61890f68c38ba3"
    static let searxlyTokenSymbol    = "SEARXLY"
    static let searxlyTokenName      = "Searxly"
    static let searxlyTokenDecimals  = 18

    // MARK: - Base L2 network
    // `nonisolated` so these plain constants can be used as default-argument values and inside
    // nonisolated networking code (the module defaults to MainActor isolation).
    nonisolated static let baseChainID: Int = 8453
    nonisolated static let baseChainIDHex   = "0x2105"
    static let baseChainName         = "Base"

    // MARK: - RPC endpoints (first is default; second is fallback)
    static let defaultRPCURLs: [String] = [
        "https://mainnet.base.org",
        "https://base.llamarpc.com",
        "https://base-mainnet.public.blastapi.io",
    ]

    // MARK: - Price feed (DexScreener — no auth, tracks DEX pairs for tiny tokens)
    static let priceAPIURL = "https://api.dexscreener.com/latest/dex/tokens/\(searxlyTokenAddress)"

    // MARK: - Price-history feeds (charts) — keyless, keyed by public token/pool addresses only
    /// CoinGecko market-chart endpoint base (used for the ETH price series — ETH is a global asset).
    static let coinGeckoAPIBase = "https://api.coingecko.com/api/v3"
    /// GeckoTerminal on-chain OHLCV (CoinGecko's keyless on-chain product). Base network slug = "base".
    static let geckoTerminalAPIBase = "https://api.geckoterminal.com/api/v2"
    static let geckoTerminalNetwork = "base"

    // MARK: - Explorer
    static let explorerBaseURL       = "https://basescan.org"

    // MARK: - External services (hybrid features — only contacted when the user opts in)
    /// Basescan-style API (Etherscan v2 multichain endpoint with chainid=8453). No key needed
    /// for low-rate reads; an optional user key raises limits.
    static let historyAPIBase        = "https://api.etherscan.io/v2/api"
    /// 0x Swap API (v2) host. Requires a free 0x API key (entered in Settings → Wallet).
    static let swapAPIBase           = "https://api.0x.org"

    // MARK: - Swap fee (Searxly's revenue)
    /// Searxly's swap fee in basis points (65 = 0.65%, under Phantom's ~0.85%). Collected ON-CHAIN by
    /// the 0x settlement contract and routed to `swapFeeRecipient` — there is NO extra transaction and
    /// no fee-handling in our signing code. Charged on SWAPS ONLY, never on plain sends/transfers, and
    /// waived entirely for any swap involving SEARXLY (see WalletSwap.quote). Disclosed in the swap UI.
    static let swapFeeBps: Int       = 65
    /// Treasury address that receives the swap fee. EIP-55 checksummed; verified before shipping.
    /// Same address collects on every supported EVM chain. Change here to rotate the treasury.
    static let swapFeeRecipient      = "0x491Af9aA3C6Fae935D20FfeE254eA16822392976"
    /// On-ramp widget (no card data ever touches Searxly; the provider's own UI handles it).
    static func onrampURL(address: String) -> String {
        "https://buy.onramper.com/?mode=buy&onlyCryptos=eth_base,usdc_base&wallets=eth_base:\(address),usdc_base:\(address)&themeName=dark"
    }

    // MARK: - Basenames / ENS registries
    /// Base L2 Basename L2 resolver (reverse) — resolved via RPC, always on.
    static let basenameL2Resolver    = "0xC6d566A56A1aFf6508b41f6c90ff131615583BCD"
    /// Ethereum mainnet RPC for optional ENS `.eth` resolution (only used when the toggle is on).
    static let ethMainnetRPC         = "https://eth.llamarpc.com"

    // MARK: - HD derivation path (BIP-44, Ethereum coin type = 60)
    static let derivationPath        = "m/44'/60'/0'/0"

    // MARK: - PIN / passphrase policy
    static let pinLength             = 6
    /// Minimum length for an alphanumeric passphrase (the high-security alternative to the 6-digit PIN).
    static let minPassphraseLength   = 8
    static let recoveryCodeLength    = 32   // hex chars (16 random bytes)

    // MARK: - UserDefaults keys
    enum Keys {
        static let walletConfigured  = "Wallet.isConfigured"
        static let pinSalt           = "Wallet.pinSalt"
        static let pinHash           = "Wallet.pinHash"
        static let usesPassphrase    = "Wallet.usesPassphrase"   // secret is an alphanumeric passphrase, not a 6-digit PIN
        static let recoveryHash      = "Wallet.recoveryHash"
        static let customRPCURL      = "Wallet.customRPCURL"
        static let lastKnownAddress  = "Wallet.lastKnownAddress"
        static let customTokens      = "Wallet.customTokens"   // JSON-encoded [WalletToken]
        static let biometricEnabled  = "Wallet.biometricEnabled"
        static let pinFailedAttempts = "Wallet.pinFailedAttempts"
        static let pinLockedUntil    = "Wallet.pinLockedUntil"
        static let localActivity     = "Wallet.localActivity"  // JSON-encoded [WalletActivityEntry]
        static let defaultGasSpeed   = "Wallet.defaultGasSpeed"
        static let autoLock          = "Wallet.autoLock"       // WalletAutoLock raw value
        static let activeAccount     = "Wallet.activeAccount"  // active HD account index
        static let activeChain       = "Wallet.activeChain"    // active EVM chain id
        static let hiddenTokens      = "Wallet.hiddenTokens"   // token IDs hidden from the list
        static let revealedTokens    = "Wallet.revealedTokens" // built-in coins the user pinned visible at $0
        static let fiatCurrency      = "Wallet.fiatCurrency"   // display currency code
        static let priceAlerts       = "Wallet.priceAlerts"    // JSON-encoded [WalletPriceAlert]
        static let incomingAlerts    = "Wallet.feature.incomingAlerts"  // notify on received funds

        // Whether websites can see/connect to the wallet (window.ethereum). Default ON.
        static let dappProviderEnabled  = "Wallet.feature.dappProvider"

        // Hybrid feature toggles (all default OFF → zero external calls)
        static let enableFullHistory    = "Wallet.feature.fullHistory"
        static let enableTokenDiscovery = "Wallet.feature.tokenDiscovery"
        static let enableSwaps          = "Wallet.feature.swaps"
        static let enableBuy            = "Wallet.feature.buy"
        static let enableENS            = "Wallet.feature.ens"
        static let enablePriceCharts    = "Wallet.feature.priceCharts"
        static let rotatePerDApp        = "Wallet.feature.rotatePerDApp"

        // Optional user-supplied API keys for provider-backed features
        static let basescanAPIKey    = "Wallet.basescanAPIKey"
        static let zeroExAPIKey      = "Wallet.zeroExAPIKey"
    }
}

/// Display currency for fiat values. Conversion uses a keyless exchange-rate feed (frankfurter.app,
/// ECB data) — only fetched when a non-USD currency is selected.
enum FiatCurrency: String, CaseIterable, Identifiable {
    case usd, eur, gbp, jpy, cad, aud, chf

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }
    var symbol: String {
        switch self {
        case .usd, .cad, .aud: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .jpy: return "¥"
        case .chf: return "Fr "
        }
    }
    var label: String { "\(code) \(symbol.trimmingCharacters(in: .whitespaces))" }
}

/// When an unlocked wallet automatically re-locks itself. Opt-in (default `never`).
enum WalletAutoLock: String, CaseIterable, Identifiable {
    case never, oneMinute, fiveMinutes, fifteenMinutes, onResign
    var id: String { rawValue }

    var label: String {
        switch self {
        case .never:          return "Never"
        case .oneMinute:      return "1 min"
        case .fiveMinutes:    return "5 min"
        case .fifteenMinutes: return "15 min"
        case .onResign:       return "On switch"
        }
    }

    /// Idle timeout in seconds, or nil when the option isn't time-based.
    var timeout: TimeInterval? {
        switch self {
        case .oneMinute:      return 60
        case .fiveMinutes:    return 300
        case .fifteenMinutes: return 900
        default:              return nil
        }
    }

    /// Lock as soon as Searxly stops being the active app.
    var locksOnResign: Bool { self == .onResign }
}

/// Reads the hybrid feature toggles. Everything defaults to OFF so the wallet makes
/// no third-party calls until the user explicitly enables a feature in Settings → Wallet.
enum WalletFeatures {
    private static func flag(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    private static func setFlag(_ key: String, _ on: Bool) { UserDefaults.standard.set(on, forKey: key) }

    /// Whether the wallet's unlock secret is a long alphanumeric passphrase (true) or the 6-digit PIN
    /// (false, default). Set at setup or via Settings → Change PIN/Passphrase. Drives which input the
    /// secret-entry control shows; the crypto (PBKDF2 + verifier) is identical for both.
    static var usesPassphrase: Bool {
        get { flag(WalletConfig.Keys.usesPassphrase) }
        set { setFlag(WalletConfig.Keys.usesPassphrase, newValue) }
    }

    /// Website wallet exposure (window.ethereum). Defaults to ON when unset.
    static var dappProvider: Bool {
        get {
            UserDefaults.standard.object(forKey: WalletConfig.Keys.dappProviderEnabled) == nil
                ? true
                : flag(WalletConfig.Keys.dappProviderEnabled)
        }
        set { setFlag(WalletConfig.Keys.dappProviderEnabled, newValue) }
    }

    static var fullHistory: Bool {
        get { flag(WalletConfig.Keys.enableFullHistory) } set { setFlag(WalletConfig.Keys.enableFullHistory, newValue) }
    }
    /// Auto-find coins an address holds. Discovery sends the address to an explorer, so it stays
    /// opt-in by default — EXCEPT when the Searxly gateway is configured, where the lookup is fronted
    /// by Searxly's own infra (Blockscout), not a third party. In that case it defaults ON so coins you
    /// receive simply appear, instead of silently missing until you paste a contract address by hand.
    /// An explicit choice in Settings → Wallet always wins over the default.
    static var tokenDiscovery: Bool {
        get {
            UserDefaults.standard.object(forKey: WalletConfig.Keys.enableTokenDiscovery) == nil
                ? SearxlyGateway.isConfigured
                : flag(WalletConfig.Keys.enableTokenDiscovery)
        }
        set { setFlag(WalletConfig.Keys.enableTokenDiscovery, newValue) }
    }
    static var swaps: Bool {
        get { flag(WalletConfig.Keys.enableSwaps) } set { setFlag(WalletConfig.Keys.enableSwaps, newValue) }
    }
    static var buy: Bool {
        get { flag(WalletConfig.Keys.enableBuy) } set { setFlag(WalletConfig.Keys.enableBuy, newValue) }
    }
    static var ens: Bool {
        get { flag(WalletConfig.Keys.enableENS) } set { setFlag(WalletConfig.Keys.enableENS, newValue) }
    }
    /// Auto-assign a fresh, dedicated HD address to each new dApp origin so connected sites can't be
    /// linked to one on-chain identity. Opt-in (default OFF). Addresses are pre-derived while the
    /// wallet is unlocked, so connecting needs no extra prompt.
    static var rotatePerDApp: Bool {
        get { flag(WalletConfig.Keys.rotatePerDApp) } set { setFlag(WalletConfig.Keys.rotatePerDApp, newValue) }
    }
    /// Notify when an address receives funds. Defaults ON when unset — uses only the balance polling
    /// the wallet already does (no new data surface).
    static var incomingAlerts: Bool {
        get {
            UserDefaults.standard.object(forKey: WalletConfig.Keys.incomingAlerts) == nil
                ? true
                : flag(WalletConfig.Keys.incomingAlerts)
        }
        set { setFlag(WalletConfig.Keys.incomingAlerts, newValue) }
    }
    /// In-app price charts. Defaults to ON when unset: chart data comes from the same public price
    /// APIs (keyed by the token/pool address) the live price already uses — no extra user-data surface.
    static var priceCharts: Bool {
        get {
            UserDefaults.standard.object(forKey: WalletConfig.Keys.enablePriceCharts) == nil
                ? true
                : flag(WalletConfig.Keys.enablePriceCharts)
        }
        set { setFlag(WalletConfig.Keys.enablePriceCharts, newValue) }
    }

    // API keys are user-entered service secrets — stored in the Keychain (device-only, excluded
    // from backups), not plaintext UserDefaults. The getter migrates any old plaintext value once.
    static var basescanAPIKey: String {
        get { keychainKey(load: WalletKeychain.loadBasescanKey,
                          save: WalletKeychain.saveBasescanKey,
                          legacyKey: WalletConfig.Keys.basescanAPIKey) }
        set { WalletKeychain.saveBasescanKey(newValue)
              UserDefaults.standard.removeObject(forKey: WalletConfig.Keys.basescanAPIKey) }
    }
    static var zeroExAPIKey: String {
        get { keychainKey(load: WalletKeychain.loadZeroExKey,
                          save: WalletKeychain.saveZeroExKey,
                          legacyKey: WalletConfig.Keys.zeroExAPIKey) }
        set { WalletKeychain.saveZeroExKey(newValue)
              UserDefaults.standard.removeObject(forKey: WalletConfig.Keys.zeroExAPIKey) }
    }

    private static func keychainKey(load: () -> String?, save: (String) -> Void, legacyKey: String) -> String {
        if let k = load() { return k }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
            save(legacy)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return legacy
        }
        return ""
    }

    static var defaultGasSpeed: GasSpeed {
        get { GasSpeed(rawValue: UserDefaults.standard.string(forKey: WalletConfig.Keys.defaultGasSpeed) ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: WalletConfig.Keys.defaultGasSpeed) }
    }
}
