//
//  SearxlyAIConfig.swift
//  Searxly
//
//  Operator-side configuration for Searxly AI access (the paid cloud tier).
//
//  Money path: USDC on Base, paid from the in-app self-custody wallet to the SAME treasury the Managed
//  VPN and the swap fee use (`WalletConfig.swapFeeRecipient`) — so all Searxly revenue lands in one
//  address.
//
//  ⚠️ These client-side limits + the holder check are the UX gate (layer 1). A modified client could
//  bypass them, so the AUTHORITATIVE enforcement belongs on the gateway: verify the SIWE-proved
//  address's on-chain $SEARXLY balance + an active pass, and count prompts server-side. That is the next
//  step; this ships the full product experience and the payment rail today.
//

import Foundation

enum SearxlyAIConfig {
    // MARK: - Payment (USDC on Base → shared treasury)

    /// Treasury that receives Searxly AI payments. Reuses the wallet/VPN treasury so revenue lands in one
    /// place — identical to `ManagedVPNConfig.treasury` and `WalletConfig.swapFeeRecipient`.
    static var treasury: String { WalletConfig.swapFeeRecipient }

    // MARK: - Daily prompt allowances (per UTC day)

    static let freeDailyPrompts       = 10
    static let passDailyPrompts       = 100
    static let holderDailyPrompts     = 250
    static let payAndHoldDailyPrompts = 400

    // MARK: - Holder gate ($SEARXLY)

    /// Target USD value a holder must hold to qualify. The on-chain requirement is a TOKEN COUNT derived
    /// from this and the live price (see `holderTokensRequired`), so a price dip never raises the bar on
    /// an existing holder mid-window. Marketed as "≈ $10 at launch", enforced in tokens.
    static let holderTargetUSD: Decimal = 10

    /// Fallback token count used when the live price feed is unavailable (≈ $10 at launch price).
    static let holderFallbackTokens: Decimal = 3_500_000

    /// How long a holder stays qualified after they last met the threshold. This grace window is what
    /// makes a price-derived threshold safe: a temporary dip (or a briefly-unavailable price feed) can't
    /// instantly revoke access — the window simply lapses and is re-evaluated.
    static let holderWindowDays: Double = 30

    /// Token amount required to qualify as a holder, computed from the live price. Falls back to a fixed
    /// count when the price is unknown. (Equivalent to `holderTargetUSD / price`.)
    static func holderTokensRequired(priceUSD: Double) -> Decimal {
        guard priceUSD > 0 else { return holderFallbackTokens }
        return holderTargetUSD / Decimal(priceUSD)
    }
}
