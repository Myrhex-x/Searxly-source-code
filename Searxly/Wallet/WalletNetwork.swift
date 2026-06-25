//
//  WalletNetwork.swift
//  Searxly
//
//  JSON-RPC calls to Base L2 + price feeds (CoinGecko + DexScreener).
//

import Foundation

enum WalletNetwork {

    // MARK: - ETH balance

    static func ethBalance(address: String, rpc: String) async -> Decimal? {
        let result = await jsonRPC(rpc: rpc, method: "eth_getBalance",
                                   params: [address, "latest"])
        guard let hex = result as? String else { return nil }
        return hexWeiToDecimalETH(hex)
    }

    // MARK: - ERC-20 balanceOf

    static func erc20Balance(tokenAddress: String, walletAddress: String,
                              decimals: Int, rpc: String) async -> Decimal? {
        // balanceOf(address) selector = keccak256("balanceOf(address)")[0:4] = 0x70a08231
        let selector = "0x70a08231"
        let paddedAddr = walletAddress.dropFirst(2).lowercased().leftPadded(toLength: 64)
        let data = selector + paddedAddr
        let callObj: [String: String] = ["to": tokenAddress, "data": data]
        let result = await jsonRPC(rpc: rpc, method: "eth_call",
                                   params: [callObj, "latest"])
        guard let hex = result as? String, hex.count > 2 else { return nil }
        return hexToDecimal(hex.dropFirst(2), decimals: decimals)
    }

    // MARK: - Prices

    struct PriceResult {
        var ethUSD: Double = 0
        var searxlyUSD: Double = 0
        var searxlyChange24h: Double = 0
        var usdcUSD: Double = 1.0   // USDC is pegged
    }

    /// Fetches the native-coin USD price (CoinGecko) and, when `searxlyAddress` is provided
    /// (i.e. on Base), the SEARXLY DEX price. On non-Base chains pass `searxlyAddress: nil`.
    static func fetchPrices(nativeCoinGeckoID: String = "ethereum",
                            searxlyAddress: String?) async -> PriceResult {
        var result = PriceResult()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let native = await coinGeckoPrice(id: nativeCoinGeckoID) {
                    result.ethUSD = native
                }
            }
            if let searxlyAddress {
                group.addTask {
                    if let (price, change) = await dexScreenerPrice(tokenAddress: searxlyAddress) {
                        result.searxlyUSD = price
                        result.searxlyChange24h = change
                    }
                }
            }
        }
        return result
    }

    // MARK: - Fiat exchange rate (USD → currency), keyless ECB data via frankfurter.app

    static func fxRate(usdTo code: String) async -> Double? {
        // frankfurter.dev is the current canonical host (api.frankfurter.app now only 301-redirects
        // here; calling .dev/v1 directly avoids relying on a redirect that may be removed later).
        guard code != "USD",
              let url = URL(string: "https://api.frankfurter.dev/v1/latest?from=USD&to=\(code)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Any],
              let rate = rates[code] as? Double else { return nil }
        return rate
    }

    // MARK: - CoinGecko (ETH price, no API key needed for simple calls)

    private static func coinGeckoPrice(id: String) async -> Double? {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(id)&vs_currencies=usd") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coin = json[id] as? [String: Any],
              let price = coin["usd"] as? Double else { return nil }
        return price
    }

    // MARK: - DexScreener (SEARXLY / tiny token price)

    private static func dexScreenerPrice(tokenAddress: String) async -> (Double, Double)? {
        guard let url = URL(string: "https://api.dexscreener.com/latest/dex/tokens/\(tokenAddress)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairs = json["pairs"] as? [[String: Any]],
              let first = pairs.first else { return nil }
        let priceStr = first["priceUsd"] as? String ?? "0"
        let price = Double(priceStr) ?? 0
        let change = (first["priceChange"] as? [String: Any])?["h24"] as? Double ?? 0
        return (price, change)
    }

    // MARK: - Token metadata ("Add coin" by contract address)

    struct TokenMeta: Equatable { let symbol: String; let name: String; let decimals: Int }

    /// Reads an ERC-20's symbol / name / decimals straight from the contract in ONE batched RPC call
    /// (the user's own node — no external service, no name search, nothing leaves to a third party).
    /// Returns nil when the address doesn't behave like an ERC-20 (so the UI can fall back to manual
    /// entry). symbol/name are ABI-decoded; older bytes32-style tokens are handled too.
    static func tokenMetadata(contract: String, rpc: String) async -> TokenMeta? {
        let results = await jsonRPCBatch(rpc: rpc, calls: [
            (1, "eth_call", [["to": contract, "data": "0x95d89b41"], "latest"]),   // symbol()
            (2, "eth_call", [["to": contract, "data": "0x06fdde03"], "latest"]),   // name()
            (3, "eth_call", [["to": contract, "data": "0x313ce567"], "latest"]),   // decimals()
        ])
        // decimals() is the discriminator: a real ERC-20 answers with a uint8. No answer → not a token.
        guard let decHex = results[3] as? String,
              let dec = UInt64(String(decHex.hasPrefix("0x") ? decHex.dropFirst(2) : Substring(decHex)).suffix(16), radix: 16),
              dec <= 36
        else { return nil }
        let symbol = (results[1] as? String).flatMap { decodeABIString($0) } ?? ""
        let name   = (results[2] as? String).flatMap { decodeABIString($0) } ?? symbol
        return TokenMeta(symbol: symbol, name: name.isEmpty ? symbol : name, decimals: Int(dec))
    }

    /// Decodes an ABI-encoded `string` return (`[32 offset][32 length][bytes]`), with a fallback for
    /// older tokens that return a fixed `bytes32` symbol.
    private static func decodeABIString(_ hex: String) -> String? {
        let data = RLP.dataFromHex(hex)
        func be(_ d: Data) -> Int { d.suffix(8).reduce(0) { ($0 << 8) | Int($1) } }
        guard data.count >= 64 else {
            let trimmed = data.prefix { $0 != 0 }            // bytes32: trim zero padding
            let s = String(decoding: trimmed, as: UTF8.self)
            return s.isEmpty ? nil : s
        }
        let offset = be(data.subdata(in: 0..<32))
        guard offset >= 0, offset + 32 <= data.count else { return nil }
        let length = be(data.subdata(in: offset..<offset + 32))
        let start = offset + 32
        guard length > 0, length < 256, start + length <= data.count else { return nil }
        let s = String(decoding: data.subdata(in: start..<start + length), as: UTF8.self)
        let cleaned = s.trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespaces))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Price history (charts)
    //
    // PRIVACY: every request here is keyed only by a PUBLIC token contract / pool address (or the
    // global "ethereum" id) — the user's wallet address is never sent. Identical privacy surface to
    // the live price already fetched on each refresh. Base-first: token series come from Base pools.

    /// Price series for a token over a range. The native coin → its global CoinGecko price (ETH on
    /// Base/OP/Arbitrum/Ethereum, POL on Polygon); on-chain tokens → GeckoTerminal OHLCV for the
    /// token's top pool ON ITS CHAIN; stablecoins → a flat $1 line. The chain comes from the token
    /// itself (`token.chainId`), so charts are correct on every supported network.
    static func priceHistory(token: WalletToken, range: ChartRange) async -> [PricePoint] {
        let chain = WalletChain.by(id: token.chainId) ?? .base
        guard let contract = token.contractAddress else {
            var pts = await coinGeckoMarketChart(id: chain.coinGeckoNativeID, days: range.coinGeckoDays)
            // CoinGecko's shortest window is one day; trim to the requested short window (e.g. 1H).
            if let trim = range.coinGeckoTrimSeconds, let last = pts.last?.t {
                let cutoff = last.addingTimeInterval(-trim)
                pts = pts.filter { $0.t >= cutoff }
            }
            return pts
        }
        if token.isStablecoin { return flatSeries(value: 1.0, range: range) }
        guard let pool = await topPoolAddress(forToken: contract, dexSlug: chain.dexScreenerSlug) else { return [] }
        return await geckoTerminalOHLCV(pool: pool, range: range, network: chain.geckoTerminalSlug)
    }

    /// The highest-liquidity pool for a token ON `dexSlug`'s chain, via the (already-trusted)
    /// DexScreener tokens endpoint. Used as the GeckoTerminal OHLCV pool. Sends only the token address.
    static func topPoolAddress(forToken contract: String, dexSlug: String = "base") async -> String? {
        guard let url = URL(string: "https://api.dexscreener.com/latest/dex/tokens/\(contract)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairs = json["pairs"] as? [[String: Any]] else { return nil }
        let onChain = pairs.filter { ($0["chainId"] as? String)?.lowercased() == dexSlug.lowercased() }
        let pool = (onChain.isEmpty ? pairs : onChain).max { liquidityUSD($0) < liquidityUSD($1) }
        return pool?["pairAddress"] as? String
    }

    private static func liquidityUSD(_ pair: [String: Any]) -> Double {
        ((pair["liquidity"] as? [String: Any])?["usd"] as? Double) ?? 0
    }

    private static func geckoTerminalOHLCV(pool: String, range: ChartRange, network: String = "base") async -> [PricePoint] {
        let p = range.ohlcv
        var comps = URLComponents(string: "\(WalletConfig.geckoTerminalAPIBase)/networks/\(network)/pools/\(pool)/ohlcv/\(p.timeframe)")
        comps?.queryItems = [
            .init(name: "aggregate", value: String(p.aggregate)),
            .init(name: "limit", value: String(p.limit)),
            .init(name: "currency", value: "usd"),
        ]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let attrs = dataObj["attributes"] as? [String: Any],
              let list = attrs["ohlcv_list"] as? [[Any]] else { return [] }
        var points: [PricePoint] = []
        for row in list where row.count >= 5 {
            guard let ts = (row[0] as? NSNumber)?.doubleValue,
                  let close = (row[4] as? NSNumber)?.doubleValue else { continue }
            points.append(PricePoint(t: Date(timeIntervalSince1970: ts), v: close))
        }
        return points.sorted { $0.t < $1.t }   // GeckoTerminal returns newest-first
    }

    private static func coinGeckoMarketChart(id: String, days: String) async -> [PricePoint] {
        guard let url = URL(string: "\(WalletConfig.coinGeckoAPIBase)/coins/\(id)/market_chart?vs_currency=usd&days=\(days)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prices = json["prices"] as? [[Any]] else { return [] }
        var points: [PricePoint] = []
        for row in prices where row.count >= 2 {
            guard let ms = (row[0] as? NSNumber)?.doubleValue,
                  let price = (row[1] as? NSNumber)?.doubleValue else { continue }
            points.append(PricePoint(t: Date(timeIntervalSince1970: ms / 1000), v: price))
        }
        return points
    }

    private static func flatSeries(value: Double, range: ChartRange) -> [PricePoint] {
        let days = Double(range.coinGeckoDays) ?? 365   // "max" → ~a year of flat line
        let now = Date()
        return [PricePoint(t: now.addingTimeInterval(-days * 86_400), v: value),
                PricePoint(t: now, v: value)]
    }

    // MARK: - Transaction RPC

    /// Pending transaction count (the next nonce) for an address.
    static func transactionCount(address: String, rpc: String) async -> UInt64? {
        let result = await jsonRPC(rpc: rpc, method: "eth_getTransactionCount", params: [address, "pending"])
        guard let hex = result as? String else { return nil }
        return hexToUInt64(hex)
    }

    /// Suggested priority fee (tip) in wei.
    static func maxPriorityFee(rpc: String) async -> UInt64? {
        let result = await jsonRPC(rpc: rpc, method: "eth_maxPriorityFeePerGas", params: [])
        guard let hex = result as? String else { return nil }
        return hexToUInt64(hex)
    }

    /// Current base fee per gas in wei (from the latest block header).
    static func baseFee(rpc: String) async -> UInt64? {
        let result = await jsonRPC(rpc: rpc, method: "eth_getBlockByNumber", params: ["latest", false])
        guard let block = result as? [String: Any],
              let hex = block["baseFeePerGas"] as? String else { return nil }
        return hexToUInt64(hex)
    }

    /// Estimates gas for a transaction. Returns nil on revert / failure.
    static func estimateGas(from: String, to: String, valueHex: String, dataHex: String, rpc: String) async -> UInt64? {
        var call: [String: String] = ["from": from, "to": to]
        if valueHex != "0x0" && valueHex != "0x" { call["value"] = valueHex }
        if dataHex != "0x" { call["data"] = dataHex }
        let result = await jsonRPC(rpc: rpc, method: "eth_estimateGas", params: [call, "latest"])
        guard let hex = result as? String else { return nil }
        return hexToUInt64(hex)
    }

    /// Broadcasts a signed raw transaction. Returns (txHash, errorMessage).
    static func sendRawTransaction(_ rawHex: String, rpc: String) async -> (txHash: String?, error: String?) {
        let full = await jsonRPCFull(rpc: rpc, method: "eth_sendRawTransaction", params: [rawHex])
        if let hash = full.result as? String { return (hash, nil) }
        return (nil, full.error ?? "Broadcast failed")
    }

    enum ReceiptStatus { case pending, success, failed }

    /// Polls a transaction's receipt. `.pending` = not yet mined.
    static func transactionReceipt(hash: String, rpc: String) async -> ReceiptStatus {
        let result = await jsonRPC(rpc: rpc, method: "eth_getTransactionReceipt", params: [hash])
        guard let receipt = result as? [String: Any], let statusHex = receipt["status"] as? String else {
            return .pending
        }
        return (hexToUInt64(statusHex) ?? 0) == 1 ? .success : .failed
    }

    /// Generic read-only passthrough for the dApp provider (no signing).
    static func rawCall(method: String, params: [Any], rpc: String) async -> (result: Any?, error: String?) {
        await jsonRPCFull(rpc: rpc, method: method, params: params)
    }

    // MARK: - Token approvals (allowance scanning + revoke support)

    /// keccak256("Approval(address,address,uint256)")
    static let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

    /// Unique (token, spender) pairs from ERC-20 Approval logs where `owner` granted the approval.
    /// Returns nil if the RPC rejects the query (e.g. block-range limits) so callers can show a hint.
    static func approvalSpenders(owner: String, tokenContracts: [String], rpc: String) async -> [(token: String, spender: String)]? {
        guard !tokenContracts.isEmpty else { return [] }
        let ownerTopic = "0x" + String(owner.dropFirst(2)).lowercased().leftPadded(toLength: 64)
        let filter: [String: Any] = [
            "fromBlock": "0x0",
            "toBlock": "latest",
            "address": tokenContracts,
            "topics": [approvalTopic, ownerTopic],
        ]
        let full = await jsonRPCFull(rpc: rpc, method: "eth_getLogs", params: [filter])
        if full.error != nil { return nil }
        guard let logs = full.result as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        var pairs: [(String, String)] = []
        for log in logs {
            guard let addr = (log["address"] as? String)?.lowercased(),
                  let topics = log["topics"] as? [String], topics.count >= 3 else { continue }
            let spender = "0x" + String(topics[2].suffix(40)).lowercased()
            let key = addr + spender
            if !seen.contains(key) { seen.insert(key); pairs.append((addr, spender)) }
        }
        return pairs
    }

    /// Full-history Approval-log scan via the Basescan/Etherscan logs API — works without an
    /// archive RPC (public RPCs cap getLogs ranges). Returns nil if the API errors / has no key.
    static func approvalSpendersViaExplorer(owner: String, tokenContracts: [String]) async -> [(token: String, spender: String)]? {
        let ownerTopic = "0x" + String(owner.dropFirst(2)).lowercased().leftPadded(toLength: 64)
        // The v2 logs endpoint requires a key — satisfied by the user's own key OR the gateway's.
        guard !WalletFeatures.basescanAPIKey.isEmpty || SearxlyGateway.isConfigured else { return nil }

        var seen = Set<String>()
        var pairs: [(String, String)] = []
        var anySuccess = false

        for token in tokenContracts {
            guard let req = explorerRequest([
                .init(name: "chainid", value: String(WalletConfig.baseChainID)),
                .init(name: "module", value: "logs"),
                .init(name: "action", value: "getLogs"),
                .init(name: "address", value: token),
                .init(name: "topic0", value: approvalTopic),
                .init(name: "topic1", value: ownerTopic),
                .init(name: "topic0_1_opr", value: "and"),
            ], preferUserKey: true),
                  let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let result = json["result"] as? [[String: Any]] {
                anySuccess = true
                for log in result {
                    guard let topics = log["topics"] as? [String], topics.count >= 3 else { continue }
                    let spender = "0x" + String(topics[2].suffix(40)).lowercased()
                    let k = token.lowercased() + spender
                    if !seen.contains(k) { seen.insert(k); pairs.append((token.lowercased(), spender)) }
                }
            } else if (json["status"] as? String) == "0",
                      (json["message"] as? String)?.localizedCaseInsensitiveContains("no records") == true {
                anySuccess = true   // valid empty result
            }
        }
        return anySuccess ? pairs : nil
    }

    /// Live ERC-20 `allowance(owner, spender)` as a big-endian byte array (nil on failure).
    static func allowance(token: String, owner: String, spender: String, rpc: String) async -> [UInt8]? {
        let data = "0xdd62ed3e"
            + String(owner.dropFirst(2)).lowercased().leftPadded(toLength: 64)
            + String(spender.dropFirst(2)).lowercased().leftPadded(toLength: 64)
        let result = await jsonRPC(rpc: rpc, method: "eth_call", params: [["to": token, "data": data], "latest"])
        guard let hex = result as? String else { return nil }
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes = [UInt8]()
        var s = Substring(clean)
        while s.count >= 2 {
            let pair = s.prefix(2); s = s.dropFirst(2)
            if let b = UInt8(pair, radix: 16) { bytes.append(b) } else { return nil }
        }
        // Trim leading zeros to a minimal big-endian representation.
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }

    // MARK: - Transaction dry-run (eth_call) — "would this succeed?"

    enum SimResult { case success, revert(String), unknown }

    /// Dry-runs a transaction with eth_call. A revert means the real transaction would fail too —
    /// catching it here saves the user a wasted gas fee and flags suspicious calls.
    static func simulateCall(from: String, to: String, valueHex: String?, dataHex: String?, rpc: String) async -> SimResult {
        var call: [String: String] = ["from": from, "to": to]
        if let v = valueHex, v != "0x0", v != "0x" { call["value"] = v }
        if let d = dataHex, d != "0x", !d.isEmpty { call["data"] = d }
        let full = await jsonRPCFull(rpc: rpc, method: "eth_call", params: [call, "latest"])
        if let err = full.error {
            // Only a genuine execution revert means the real tx would fail. A transport / parse /
            // rate-limit error from the RPC is inconclusive — say nothing rather than false-alarm.
            let lower = err.lowercased()
            let isRevert = lower.contains("revert") || lower.contains("vm exception")
                || lower.contains("out of gas") || lower.contains("insufficient funds")
                || lower.contains("exceeds balance") || lower.contains("exceeds allowance")
            guard isRevert else { return .unknown }
            let trimmed = err.replacingOccurrences(of: "execution reverted: ", with: "")
                             .replacingOccurrences(of: "execution reverted", with: "")
            return .revert(trimmed.isEmpty ? "would fail" : trimmed)
        }
        return full.result != nil ? .success : .unknown
    }

    // MARK: - JSON-RPC

    private static func jsonRPC(rpc: String, method: String, params: [Any]) async -> Any? {
        await jsonRPCFull(rpc: rpc, method: method, params: params).result
    }

    private static func jsonRPCFull(rpc: String, method: String, params: [Any]) async -> (result: Any?, error: String?) {
        // Failover: try the requested RPC, then the OTHER public endpoints FOR THE SAME CHAIN if a
        // node is unreachable or returns garbage. We only add fallbacks that belong to the chain the
        // requested RPC is on — a user's custom (private) RPC matches no chain list, so it's used
        // alone and we never silently leak to (or cross-chain to) public nodes.
        var candidates = [rpc]
        for u in failoverList(for: rpc) where !candidates.contains(u) { candidates.append(u) }
        var lastError: String? = "Network error"
        for url in candidates {
            let r = await singleRPC(rpc: url, method: method, params: params)
            if r.reachable { return (r.result, r.error) }   // node answered (even an RPC error) — done
            lastError = r.error
        }
        return (nil, lastError)
    }

    /// Public failover endpoints that belong to the SAME chain as `rpc`. Empty for a custom/private
    /// RPC (matches no chain list) so it's never silently replaced by a public node.
    private static func failoverList(for rpc: String) -> [String] {
        for chain in WalletChain.all where chain.rpcURLs.contains(rpc) { return chain.rpcURLs }
        return []
    }

    /// One JSON-RPC call. `reachable` is true when the node returned a real JSON-RPC response
    /// (a result OR a `{error}`), false on a transport failure / garbage body → caller fails over.
    private static func singleRPC(rpc: String, method: String, params: [Any]) async -> (result: Any?, error: String?, reachable: Bool) {
        guard let url = URL(string: rpc) else { return (nil, "Invalid RPC URL", false) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return (nil, "Encoding failed", true) }
        req.httpBody = bodyData
        req.timeoutInterval = 12

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, "Network error", false) }
        // A rate-limited (429) or overloaded (5xx) node hasn't really answered — mark it unreachable
        // so we fail over to the next endpoint instead of returning a nil balance that shows as "0".
        if let http = resp as? HTTPURLResponse, http.statusCode == 429 || http.statusCode >= 500 {
            return (nil, "HTTP \(http.statusCode)", false)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, "Invalid response", false) }
        if let error = json["error"] as? [String: Any] {
            return (nil, error["message"] as? String ?? "RPC error", true)
        }
        return (json["result"], nil, true)
    }

    // MARK: - Batched JSON-RPC (one HTTP round-trip for many calls)

    /// All token balances in a SINGLE batched RPC round-trip — `eth_getBalance` for the native coin
    /// and `eth_call(balanceOf)` for each ERC-20, sent as one JSON array. Public Base/ETH nodes all
    /// support batching, so this collapses a refresh's 7+ reads into one request and stops a
    /// rate-limited node from throttling the burst (which surfaced as a stuck "0" balance). Returns
    /// balances keyed by the caller's token id; a token whose call failed is simply absent, so the
    /// caller can keep its previous value rather than wipe it to 0.
    static func batchBalances(walletAddress: String,
                              tokens: [(id: String, contract: String?, decimals: Int)],
                              rpc: String) async -> [String: Decimal] {
        guard !tokens.isEmpty else { return [:] }
        var calls: [(id: Int, method: String, params: [Any])] = []
        var meta: [Int: (id: String, decimals: Int, native: Bool)] = [:]
        for (i, t) in tokens.enumerated() {
            let cid = i + 1
            if let contract = t.contract {
                let paddedAddr = walletAddress.dropFirst(2).lowercased().leftPadded(toLength: 64)
                let callObj: [String: String] = ["to": contract, "data": "0x70a08231" + paddedAddr]
                calls.append((cid, "eth_call", [callObj, "latest"]))
                meta[cid] = (t.id, t.decimals, false)
            } else {
                calls.append((cid, "eth_getBalance", [walletAddress, "latest"]))
                meta[cid] = (t.id, t.decimals, true)
            }
        }
        let results = await jsonRPCBatch(rpc: rpc, calls: calls)
        var out: [String: Decimal] = [:]
        for (cid, m) in meta {
            guard let hex = results[cid] as? String else { continue }
            let value = m.native ? hexWeiToDecimalETH(hex)
                                 : (hex.count > 2 ? hexToDecimal(hex.dropFirst(2), decimals: m.decimals) : nil)
            if let value { out[m.id] = value }
        }
        return out
    }

    /// Sends a batch, failing over across same-chain endpoints (same policy as `jsonRPCFull`).
    private static func jsonRPCBatch(rpc: String, calls: [(id: Int, method: String, params: [Any])]) async -> [Int: Any] {
        guard !calls.isEmpty else { return [:] }
        var candidates = [rpc]
        for u in failoverList(for: rpc) where !candidates.contains(u) { candidates.append(u) }
        for url in candidates {
            if let r = await singleBatch(rpc: url, calls: calls) { return r }
        }
        return [:]
    }

    private static func singleBatch(rpc: String, calls: [(id: Int, method: String, params: [Any])]) async -> [Int: Any]? {
        guard let url = URL(string: rpc) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = calls.map { ["jsonrpc": "2.0", "id": $0.id, "method": $0.method, "params": $0.params] }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode == 429 || http.statusCode >= 500 { return nil }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [Int: Any] = [:]
        for item in arr {
            if let id = item["id"] as? Int, let result = item["result"] { out[id] = result }
        }
        return out.isEmpty ? nil : out   // nothing usable → let the caller fail over
    }

    // MARK: - Hex → UInt64

    static func hexToUInt64(_ hex: String) -> UInt64? {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(clean, radix: 16)
    }

    // MARK: - Full history (Basescan/Etherscan v2 — only when the toggle is on)

    @MainActor
    static func fetchHistory(address: String, chainId: Int = WalletConfig.baseChainID,
                             nativeSymbol: String = "ETH") async -> [WalletActivityEntry] {
        var entries: [WalletActivityEntry] = []

        if let normal = await etherscanAccount(action: "txlist", address: address, chainId: chainId) {
            for tx in normal.prefix(25) {
                guard let hash = tx["hash"] as? String else { continue }
                let from = (tx["from"] as? String) ?? ""
                let to = (tx["to"] as? String) ?? ""
                let isSend = from.lowercased() == address.lowercased()
                let eth = (Double((tx["value"] as? String) ?? "0") ?? 0) / 1e18
                let ts = Double((tx["timeStamp"] as? String) ?? "0") ?? 0
                let failed = (tx["isError"] as? String) == "1"
                // Skip 0-value contract noise unless it's a plain transfer.
                if eth == 0 && (tx["input"] as? String ?? "0x") != "0x" { continue }
                entries.append(WalletActivityEntry(
                    hash: hash, kind: isSend ? .send : .receive, tokenSymbol: nativeSymbol,
                    amount: formatAmount(eth), counterparty: isSend ? to : from,
                    timestamp: Date(timeIntervalSince1970: ts),
                    status: failed ? .failed : .confirmed, fromExplorer: true))
            }
        }

        if let tokens = await etherscanAccount(action: "tokentx", address: address) {
            for tx in tokens.prefix(25) {
                guard let hash = tx["hash"] as? String else { continue }
                let from = (tx["from"] as? String) ?? ""
                let to = (tx["to"] as? String) ?? ""
                let isSend = from.lowercased() == address.lowercased()
                let decimals = Int((tx["tokenDecimal"] as? String) ?? "18") ?? 18
                let raw = Double((tx["value"] as? String) ?? "0") ?? 0
                let amount = raw / pow(10.0, Double(decimals))
                let ts = Double((tx["timeStamp"] as? String) ?? "0") ?? 0
                entries.append(WalletActivityEntry(
                    hash: hash, kind: isSend ? .send : .receive,
                    tokenSymbol: (tx["tokenSymbol"] as? String) ?? "?",
                    amount: formatAmount(amount), counterparty: isSend ? to : from,
                    timestamp: Date(timeIntervalSince1970: ts),
                    status: .confirmed, fromExplorer: true))
            }
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Discovers ERC-20 tokens the address has interacted with (Basescan tokentx). Toggle-gated.
    @MainActor
    static func discoverTokens(address: String, chainId: Int = WalletConfig.baseChainID) async -> [(contract: String, symbol: String, name: String, decimals: Int)] {
        guard WalletFeatures.tokenDiscovery,
              let rows = await etherscanAccount(action: "tokentx", address: address, chainId: chainId)
        else { return [] }
        var seen = Set<String>()
        var result: [(String, String, String, Int)] = []
        for row in rows {
            guard let contract = (row["contractAddress"] as? String)?.lowercased(), !seen.contains(contract) else { continue }
            seen.insert(contract)
            result.append((contract,
                           (row["tokenSymbol"] as? String) ?? "?",
                           (row["tokenName"] as? String) ?? "Token",
                           Int((row["tokenDecimal"] as? String) ?? "18") ?? 18))
        }
        return result
    }

    private static func etherscanAccount(action: String, address: String,
                                         chainId: Int = WalletConfig.baseChainID) async -> [[String: Any]]? {
        guard let req = explorerRequest([
            .init(name: "chainid", value: String(chainId)),
            .init(name: "module", value: "account"),
            .init(name: "action", value: action),
            .init(name: "address", value: address),
            .init(name: "sort", value: "desc"),
            .init(name: "page", value: "1"),
            .init(name: "offset", value: "25"),
        ]),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else { return nil }
        return result
    }

    /// Builds a GET request to the explorer API. History/discovery (`account`) ALWAYS prefer the
    /// Searxly gateway when it's configured: it fronts Blockscout, which is free and — unlike a user's
    /// *free* Etherscan key — actually covers Base, so a stray personal key can't silently break
    /// history. Only the approval-logs scan passes `preferUserKey: true`, because Blockscout's getLogs
    /// is limited and a user's (paid) Etherscan key works better there. Pass items WITHOUT an `apikey`.
    private static func explorerRequest(_ items: [URLQueryItem], preferUserKey: Bool = false) -> URLRequest? {
        let userKey = WalletFeatures.basescanAPIKey
        let useGateway = preferUserKey ? (userKey.isEmpty && SearxlyGateway.isConfigured)
                                       : SearxlyGateway.isConfigured

        var query = items
        var comps = URLComponents(string: useGateway ? SearxlyGateway.etherscanBase : WalletConfig.historyAPIBase)
        if !useGateway {
            // Direct to Etherscan: attach the user's key, or a low-rate placeholder when keyless.
            query.append(.init(name: "apikey", value: userKey.isEmpty ? "YourApiKeyToken" : userKey))
        }
        comps?.queryItems = query
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        if useGateway { req.setValue(SearxlyGateway.bearer, forHTTPHeaderField: "Authorization") }
        return req
    }

    private static func formatAmount(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v < 0.0001 { return String(format: "%.8f", v) }
        return String(format: "%.4f", v)
    }

    // MARK: - Name resolution (Basenames on Base always-on; ENS .eth behind a toggle)

    /// Forward-resolves a name (e.g. "vitalik.eth" or "name.base.eth") to a 0x address.
    static func resolveName(_ name: String) async -> String? {
        let lower = name.lowercased()
        guard lower.contains(".") else { return nil }

        let registry: String
        let rpc: String
        if lower.hasSuffix(".base.eth") || lower.hasSuffix(".base") {
            registry = "0xB94704422c2a1E396835A571837Aa5AE53285a95"   // Base Registry
            rpc = WalletConfig.defaultRPCURLs.first ?? ""
        } else if lower.hasSuffix(".eth") {
            guard WalletFeatures.ens else { return nil }
            registry = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"   // ENS mainnet registry
            rpc = WalletConfig.ethMainnetRPC
        } else {
            return nil
        }

        let node = namehash(lower)
        // registry.resolver(node) → selector 0x0178b8bf
        guard let resolverWord = await ethCallWord(to: registry, selector: "0178b8bf", argHex: node, rpc: rpc),
              let resolver = addressFromWord(resolverWord),
              resolver != "0x0000000000000000000000000000000000000000" else { return nil }
        // resolver.addr(node) → selector 0x3b3b57de
        guard let addrWord = await ethCallWord(to: resolver, selector: "3b3b57de", argHex: node, rpc: rpc),
              let address = addressFromWord(addrWord),
              address != "0x0000000000000000000000000000000000000000" else { return nil }
        return address
    }

    private static func ethCallWord(to: String, selector: String, argHex: String, rpc: String) async -> String? {
        let arg = argHex.hasPrefix("0x") ? String(argHex.dropFirst(2)) : argHex
        let data = "0x" + selector + arg.leftPadded(toLength: 64)
        let result = await jsonRPC(rpc: rpc, method: "eth_call", params: [["to": to, "data": data], "latest"])
        return result as? String
    }

    private static func addressFromWord(_ word: String) -> String? {
        let clean = word.hasPrefix("0x") ? String(word.dropFirst(2)) : word
        guard clean.count >= 64 else { return nil }
        return "0x" + String(clean.suffix(40))
    }

    /// ENS namehash (keccak-based, recursive).
    private static func namehash(_ name: String) -> String {
        var node = [UInt8](repeating: 0, count: 32)
        if !name.isEmpty {
            for label in name.split(separator: ".").reversed() {
                let labelHash = [UInt8](Keccak256.hash(Data(label.utf8)))
                node = [UInt8](Keccak256.hash(Data(node + labelHash)))
            }
        }
        return "0x" + node.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Hex conversion helpers

    private static func hexWeiToDecimalETH(_ hex: String) -> Decimal? {
        guard let raw = hexToBigEndianBytes(hex) else { return nil }
        // raw bytes → Double division (sufficient precision for display)
        let eth = Double(bigEndianBytes: raw) / 1e18
        return Decimal(eth)
    }

    private static func hexToDecimal(_ hex: Substring, decimals: Int) -> Decimal? {
        guard let raw = hexToBigEndianBytes(String(hex)) else { return nil }
        let divisor = pow(10.0, Double(decimals))
        return Decimal(Double(bigEndianBytes: raw) / divisor)
    }

    /// Parses a hex amount into a minimal big-endian byte array. Handles both shapes the RPC returns:
    /// `eth_getBalance` gives a minimal quantity hex, while `eth_call` (e.g. ERC-20 `balanceOf`) gives
    /// a full 32-byte zero-padded word (64 hex chars). Leading zeros are stripped first so a real
    /// uint256 result isn't rejected — the earlier 16-byte cap made every non-zero token balance read 0.
    private static func hexToBigEndianBytes(_ hex: String) -> [UInt8]? {
        var h = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        while h.first == "0" { h.removeFirst() }
        if h.isEmpty { return [0] }                 // value was zero (or all-zero padding)
        if h.count % 2 != 0 { h = "0" + h }
        guard h.count <= 64 else { return nil }     // anything past uint256 shouldn't occur on-chain
        var bytes = [UInt8]()
        var i = h.startIndex
        while i < h.endIndex {
            let next = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        return bytes
    }
}

private extension Double {
    init(bigEndianBytes bytes: [UInt8]) {
        // Interpret 16 big-endian bytes as a 128-bit unsigned int, return as Double
        var value: Double = 0
        for b in bytes { value = value * 256 + Double(b) }
        self = value
    }
}

private extension String {
    func leftPadded(toLength length: Int) -> String {
        let pad = length - count
        return pad > 0 ? String(repeating: "0", count: pad) + self : self
    }
}
