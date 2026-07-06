//
//  WalletSwap.swift
//  Searxly
//
//  Token swaps on Base via the 0x Swap API (allowance-holder endpoint, which returns a
//  ready-to-sign transaction). Requires a free 0x API key (Settings → Wallet). Toggle-gated.
//

import Foundation

struct SwapQuote {
    let sellToken: WalletToken
    let buyToken: WalletToken
    let sellAmount: Decimal
    let buyAmountRaw: [UInt8]        // base units of buyToken
    let minBuyAmountRaw: [UInt8]
    let to: String                  // tx target
    let data: String                // tx calldata
    let value: String               // tx value (for native ETH sells)
    let gas: String?                // 0x-computed gas limit (hex) — accurate for the swap route
    let feeBps: Int                 // Searxly fee applied to this quote, in basis points (for disclosure)
    let needsAllowanceTo: String?   // spender to approve (nil for native ETH sells)
    var isV4: Bool = false          // true → native Uniswap v4 route (SEARXLY), not a 0x route
    var permit2Spender: String? = nil  // v4 sells: the UniversalRouter to authorize via Permit2; else nil

    /// The disclosed Searxly fee as a percentage string, e.g. "0.8%".
    var feePercentText: String {
        let pct = Double(feeBps) / 100
        return (pct == pct.rounded() ? String(format: "%.0f", pct) : String(format: "%.2g", pct)) + "%"
    }

    var buyAmountDisplay: String { formatBase(buyAmountRaw, decimals: buyToken.decimals) }
    var minBuyAmountDisplay: String { formatBase(minBuyAmountRaw, decimals: buyToken.decimals) }

    /// Buy amount as a Double — for fiat + exchange-rate display only (never for signing).
    var buyAmountDouble: Double {
        var v = 0.0
        for b in buyAmountRaw { v = v * 256 + Double(b) }
        return v / pow(10.0, Double(buyToken.decimals))
    }

    /// How many buy-tokens 1 sell-token buys, at this quote (for the "1 X ≈ Y" pricing row).
    var unitPrice: Double {
        let sell = (sellAmount as NSDecimalNumber).doubleValue
        return sell > 0 ? buyAmountDouble / sell : 0
    }

    private func formatBase(_ bytes: [UInt8], decimals: Int) -> String {
        var v = 0.0
        for b in bytes { v = v * 256 + Double(b) }
        let amt = v / pow(10.0, Double(decimals))
        if amt == 0 { return "0" }
        if amt < 0.0001 { return String(format: "%.8f", amt) }
        return String(format: "%.6f", amt)
    }
}

/// A user-visible stage of swap execution, reported as the wallet works through the legs
/// (a swap can be up to three transactions: ERC-20 approval → Permit2 authorization → swap,
/// each waiting to confirm on-chain). Drives the progress UI in WalletSwapView.
enum SwapStage: Equatable {
    case checking               // pre-flight: gas balance + allowance reads
    case approving(String)      // signing + broadcasting the ERC-20 approval for a symbol
    case authorizing            // Permit2 → UniversalRouter authorization (v4 sells only)
    case confirmingApproval     // an approval is broadcast; waiting for it to mine
    case submitting             // signing + broadcasting the swap itself
}

/// Stages of a single-transaction flow (send / revoke): fetching chain params (nonce, fees, gas
/// estimate), then signing + broadcasting. Multi-leg swaps use `SwapStage` instead.
enum SendStage: Equatable {
    case preparing
    case submitting
}

enum WalletSwap {
    /// The 0x convention for "native ETH".
    static let nativeETH = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    static func token0xAddress(_ token: WalletToken) -> String {
        token.contractAddress ?? nativeETH
    }

    enum SwapError: LocalizedError {
        case noKey, badResponse(String), notConfigured
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add a free 0x API key in Settings → Wallet to enable swaps."
            case .notConfigured: return "Swaps are turned off. Enable them in Settings → Wallet."
            case .badResponse(let m): return m
            }
        }
    }

    /// Fetches a swap quote. `taker` is the wallet address. If a fee'd quote can't be routed, retries
    /// once WITHOUT the Searxly fee — some thin-liquidity pairs (e.g. SEARXLY) only quote without the
    /// extra fee leg, so the user can still swap (Searxly just forgoes its fee on that trade).
    static func quote(sell: WalletToken, buy: WalletToken, sellAmount: Decimal, taker: String,
                      chainId: Int = WalletConfig.baseChainID,
                      feeBps: Int = WalletConfig.swapFeeBps) async -> Result<SwapQuote, SwapError> {
        // Native Uniswap v4 for ETH/WETH↔SEARXLY: no API key, no gateway, fully on-chain. The pool is a
        // Doppler v4 pool, priced via the V4 Quoter and executed through the UniversalRouter (see
        // UniswapV4). On any failure (e.g. a transient RPC miss) we fall through to the 0x path below,
        // so SEARXLY stays swappable either way.
        if WalletFeatures.swaps, chainId == WalletConfig.baseChainID, UniswapV4.supports(sell: sell, buy: buy),
           let v4 = await UniswapV4.quoteAndBuild(sell: sell, buy: buy, sellAmount: sellAmount,
                                                  taker: taker, rpc: WalletConfig.defaultRPCURLs.first ?? "") {
            return .success(SwapQuote(
                sellToken: sell, buyToken: buy, sellAmount: sellAmount,
                buyAmountRaw: v4.amountOut, minBuyAmountRaw: v4.minAmountOut,
                to: v4.to, data: v4.dataHex, value: v4.valueHex,
                gas: "0x" + String(v4.gas, radix: 16), feeBps: 0, needsAllowanceTo: nil,
                isV4: true,
                permit2Spender: v4.permit2Token == nil ? nil : WalletConfig.universalRouterV4))
        }

        // No Searxly fee on ANY swap that involves SEARXLY — buying it, selling it, anything. A
        // deliberate incentive to use the token (the swap UI then discloses a 0% fee).
        let waiveFee = isSearxly(sell) || isSearxly(buy)

        let primary = await fetchQuote(sell: sell, buy: buy, sellAmount: sellAmount,
                                       taker: taker, chainId: chainId, applyFee: !waiveFee, feeBps: feeBps)
        // If a fee'd quote can't be routed, retry once without the fee (helps thin-liquidity pairs).
        if !waiveFee, case .failure(.badResponse(let message)) = primary, isNoRoute(message) {
            let noFee = await fetchQuote(sell: sell, buy: buy, sellAmount: sellAmount,
                                         taker: taker, chainId: chainId, applyFee: false, feeBps: feeBps)
            if case .success = noFee { return noFee }
        }
        return primary
    }

    /// True for the SEARXLY token (matched by id, symbol, or contract) — swaps involving it are free.
    private static func isSearxly(_ token: WalletToken) -> Bool {
        token.id == "SEARXLY"
            || token.symbol.uppercased() == "SEARXLY"
            || token.contractAddress?.lowercased() == WalletConfig.searxlyTokenAddress.lowercased()
    }

    /// Whether a quote failure looks like a routing/liquidity miss (worth retrying without the fee).
    private static func isNoRoute(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("route") || m.contains("liquidity")
    }

    private static func fetchQuote(sell: WalletToken, buy: WalletToken, sellAmount: Decimal, taker: String,
                                   chainId: Int, applyFee: Bool,
                                   feeBps: Int = WalletConfig.swapFeeBps) async -> Result<SwapQuote, SwapError> {
        guard WalletFeatures.swaps else { return .failure(.notConfigured) }
        // Prefer the user's own 0x key (talks to 0x directly). Otherwise route through the Searxly
        // gateway, which holds the key server-side — so swaps work with no per-user key.
        let userKey = WalletFeatures.zeroExAPIKey
        let useGateway = userKey.isEmpty
        guard !useGateway || SearxlyGateway.isConfigured else { return .failure(.noKey) }
        let base = useGateway ? SearxlyGateway.zeroExBase : WalletConfig.swapAPIBase

        let sellAmountBase = WeiConverter.baseUnitDecimalString(amount: sellAmount, decimals: sell.decimals)
        var items: [URLQueryItem] = [
            .init(name: "chainId", value: String(chainId)),
            .init(name: "sellToken", value: token0xAddress(sell)),
            .init(name: "buyToken", value: token0xAddress(buy)),
            .init(name: "sellAmount", value: sellAmountBase),
            .init(name: "taker", value: taker),
        ]
        if applyFee {
            // Searxly fee — 0x collects it on-chain (in the buy token) and routes it to the treasury,
            // so `buyAmount`/`minBuyAmount` come back already net of the fee.
            items += [
                .init(name: "swapFeeRecipient", value: WalletConfig.swapFeeRecipient),
                .init(name: "swapFeeBps", value: String(feeBps)),
                .init(name: "swapFeeToken", value: token0xAddress(buy)),
            ]
        }
        var comps = URLComponents(string: "\(base)/swap/allowance-holder/quote")
        comps?.queryItems = items
        guard let url = comps?.url else { return .failure(.badResponse("Bad URL")) }

        var req = URLRequest(url: url)
        if useGateway {
            // The gateway attaches the real 0x-api-key + 0x-version itself.
            req.setValue(SearxlyGateway.bearer, forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(userKey, forHTTPHeaderField: "0x-api-key")
            req.setValue("v2", forHTTPHeaderField: "0x-version")
        }
        req.timeoutInterval = 20

        // Fail closed in Maximum Privacy when protection is down: a swap quote carries the taker
        // address, so it must not leave from the user's real IP (Tor mode / VPN not yet up). Native
        // egress kill switch, same as search. Inert outside Maximum.
        guard PrivacyGate.egressAllowedFast else { return .failure(.badResponse("Network error")) }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.badResponse("Network error"))
        }
        if let reason = (json["reason"] as? String) ?? (json["message"] as? String), json["transaction"] == nil {
            return .failure(.badResponse(reason))
        }
        guard let tx = json["transaction"] as? [String: Any],
              let to = tx["to"] as? String,
              let callData = tx["data"] as? String,
              let buyAmount = json["buyAmount"] as? String else {
            return .failure(.badResponse("No route to swap \(sell.symbol) → \(buy.symbol) at this amount. Try a different amount, or sell ETH or USDC instead."))
        }
        let minBuy = (json["minBuyAmount"] as? String) ?? buyAmount
        let value = (tx["value"] as? String).map { hexFromDecimalString($0) } ?? "0x0"
        // 0x returns the route-aware gas limit; prefer it over a local re-estimate (which can revert
        // or fall back to a too-low default and cost an out-of-gas failure on multi-hop swaps).
        let gas = (tx["gas"] as? String).map { hexFromDecimalString($0) }

        // Allowance needed only when selling an ERC-20 (native ETH needs none).
        var spender: String? = nil
        if sell.contractAddress != nil,
           let issues = json["issues"] as? [String: Any],
           let allowance = issues["allowance"] as? [String: Any],
           let s = allowance["spender"] as? String {
            spender = s
        }

        return .success(SwapQuote(
            sellToken: sell, buyToken: buy, sellAmount: sellAmount,
            buyAmountRaw: WeiConverter.decimalStringToBytes(buyAmount),
            minBuyAmountRaw: WeiConverter.decimalStringToBytes(minBuy),
            to: to, data: callData, value: value, gas: gas,
            feeBps: applyFee ? feeBps : 0, needsAllowanceTo: spender))
    }

    /// 0x returns `value` as a decimal string; our tx builder wants hex.
    private static func hexFromDecimalString(_ s: String) -> String {
        if s.hasPrefix("0x") { return s }
        let bytes = WeiConverter.decimalStringToBytes(s)
        if bytes.isEmpty || (bytes.count == 1 && bytes[0] == 0) { return "0x0" }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
