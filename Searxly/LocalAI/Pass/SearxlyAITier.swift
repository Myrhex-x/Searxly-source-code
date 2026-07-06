//
//  SearxlyAITier.swift
//  Searxly
//
//  The access level a user currently has for Searxly AI (the paid cloud tier). It determines the daily
//  prompt allowance. On-device backends (Apple Intelligence / local Ollama) are NEVER metered — these
//  tiers apply only to the Searxly AI cloud, whose inference Searxly pays for.
//

import Foundation

enum SearxlyAITier: String, Codable, CaseIterable, Identifiable {
    case free          // no pass, no qualifying $SEARXLY holdings
    case pass          // active USDC pass
    case holder        // holds the required amount of $SEARXLY
    case payAndHold    // both an active pass AND qualifying holdings

    var id: String { rawValue }

    /// Prompts allowed per UTC day for this tier.
    var dailyPromptLimit: Int {
        switch self {
        case .free:       return SearxlyAIConfig.freeDailyPrompts
        case .pass:       return SearxlyAIConfig.passDailyPrompts
        case .holder:     return SearxlyAIConfig.holderDailyPrompts
        case .payAndHold: return SearxlyAIConfig.payAndHoldDailyPrompts
        }
    }

    var label: String {
        switch self {
        case .free:       return "Free"
        case .pass:       return "Pass"
        case .holder:     return "Holder"
        case .payAndHold: return "Pass + Holder"
        }
    }
}
