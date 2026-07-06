//
//  SearxlyAIPass.swift
//  Searxly
//
//  A redeemed Searxly AI pass: proof the user paid USDC + the access window it bought. Persisted
//  device-locally (it's not sensitive — just a public tx hash + an expiry).
//

import Foundation

struct SearxlyAIPass: Codable, Equatable, Identifiable {
    var id: String
    var planId: String
    /// The USDC payment transaction on Base (kept for support / future server-side verification).
    var txHash: String
    var activatedAt: Date
    var expiresAt: Date

    var isActive: Bool { Date() < expiresAt }
    var secondsRemaining: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }
    var daysRemaining: Int { Int(ceil(secondsRemaining / 86_400)) }

    var plan: SearxlyAIPlan? { SearxlyAIPlan.plan(id: planId) }
}
