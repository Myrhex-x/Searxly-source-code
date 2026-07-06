//
//  SearxlyAIPlan.swift
//  Searxly
//
//  A purchasable, time-boxed Searxly AI pass. Like the Managed VPN, crypto can't auto-charge a card, so
//  each plan is a fixed window the user pays for up front (and re-buys to extend). An active pass unlocks
//  the `.pass` tier — or `.payAndHold` when combined with qualifying $SEARXLY holdings.
//

import Foundation

struct SearxlyAIPlan: Identifiable, Codable, Equatable, Hashable {
    /// Stable id (must match the gateway's price table once server-side verification ships).
    let id: String
    /// UI label ("30 days").
    let label: String
    /// Access duration in days.
    let days: Int
    /// Price in USDC.
    let priceUSDC: Decimal

    /// Rough "per month" figure for comparison in the UI.
    var pricePerMonthUSDC: Decimal {
        guard days > 0 else { return priceUSDC }
        return (priceUSDC / Decimal(days)) * 30
    }

    /// The catalog shown in the UI. Prices MUST match the gateway's table once it verifies the USDC
    /// amount actually received before granting access.
    static let catalog: [SearxlyAIPlan] = [
        SearxlyAIPlan(id: "ai-30d", label: "30 days", days: 30, priceUSDC: 4),
    ]

    static func plan(id: String) -> SearxlyAIPlan? { catalog.first { $0.id == id } }

    /// The default monthly plan (the only one today).
    static var monthly: SearxlyAIPlan { catalog[0] }
}
