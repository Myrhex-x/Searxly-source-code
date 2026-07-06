//
//  WalletPriceHistory.swift
//  Searxly
//
//  Price-history (chart) data for tokens. Series come from keyless public price APIs keyed ONLY by
//  the token / pool address — the wallet address is never sent, so a chart reveals nothing about the
//  user (same privacy surface as the live price the wallet already fetches every refresh).
//
//  Base-first: token series are pulled from Base pools (GeckoTerminal `networks/base/...`); "ETH" uses
//  the global ETH asset price (CoinGecko), since ETH on Base is the same asset as ETH anywhere.
//

import Foundation
import Observation

/// A single point on a price chart.
struct PricePoint: Identifiable, Equatable {
    let t: Date
    let v: Double
    var id: TimeInterval { t.timeIntervalSince1970 }
}

/// The time window a chart covers, with the matching feed parameters for each source.
enum ChartRange: String, CaseIterable, Identifiable {
    case min5, hour1, day1, week1, month1, year1, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .min5:   return "5M"
        case .hour1:  return "1H"
        case .day1:   return "1D"
        case .week1:  return "1W"
        case .month1: return "1M"
        case .year1:  return "1Y"
        case .all:    return "ALL"
        }
    }

    /// CoinGecko `market_chart` window (used for the ETH series). Auto-granularity:
    /// 1 → ~5-min, 7 → hourly, 30/365 → daily, max → full history.
    var coinGeckoDays: String {
        switch self {
        case .min5:   return "1"     // 5-min granularity; trimmed to the last few minutes below
        case .hour1:  return "1"     // fetched at 5-min, then trimmed to the last hour
        case .day1:   return "1"
        case .week1:  return "7"
        case .month1: return "30"
        case .year1:  return "365"
        case .all:    return "max"
        }
    }

    /// GeckoTerminal OHLCV parameters (used for on-chain Base token series).
    var ohlcv: (timeframe: String, aggregate: Int, limit: Int) {
        switch self {
        case .min5:   return ("minute", 1,  6)     // last ~5 one-min candles (liquid coins)
        case .hour1:  return ("minute", 1,  60)    // last 60 one-min candles
        case .day1:   return ("minute", 15, 96)    // 24h of 15-min candles
        case .week1:  return ("hour",   1,  168)   // 7d hourly
        case .month1: return ("day",    1,  30)    // 30d daily
        case .year1:  return ("day",    1,  365)   // 1y daily
        case .all:    return ("day",    1,  1000)  // full history (cap 1000 candles)
        }
    }

    /// For the CoinGecko (ETH) path: trim the fetched series to this many seconds, or nil to keep all.
    /// Used by the short ranges, since CoinGecko's shortest window is one day.
    var coinGeckoTrimSeconds: TimeInterval? {
        switch self {
        case .min5:  return 900     // ~last 15 min (a handful of 5-min points so the line still draws)
        case .hour1: return 3600
        default:     return nil
        }
    }
}

/// Fetches + caches token price series for the chart UI. In-memory TTL cache so re-opening a token or
/// toggling ranges doesn't refetch. Cleared on relaunch (charts are public data, nothing to persist).
@MainActor
@Observable
final class WalletPriceHistoryStore {
    static let shared = WalletPriceHistoryStore()
    private init() {}

    private struct Cached { let at: Date; let points: [PricePoint] }
    private var cache: [String: Cached] = [:]

    /// Range-aware freshness: the live-feel ranges expire fast enough for the detail view's refresh
    /// loop to actually show new candles; the slow ranges barely move, so spare the (keyless,
    /// rate-limited) APIs.
    private func ttl(for range: ChartRange) -> TimeInterval {
        switch range {
        case .min5, .hour1:         return 45
        case .day1:                 return 300
        case .week1, .month1, .year1, .all: return 900
        }
    }

    /// Returns the price series for a token over a range, using a cached copy when fresh.
    func series(for token: WalletToken, range: ChartRange) async -> [PricePoint] {
        let key = "\(token.chainId):\(token.id):\(range.rawValue)"
        if let c = cache[key], Date().timeIntervalSince(c.at) < ttl(for: range) { return c.points }
        let points = await WalletNetwork.priceHistory(token: token, range: range)
        if !points.isEmpty { cache[key] = Cached(at: Date(), points: points) }
        return points
    }
}
