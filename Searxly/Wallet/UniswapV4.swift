//
//  UniswapV4.swift
//  Searxly
//
//  Native on-chain Uniswap v4 swaps for $SEARXLY — no aggregator, no API key. SEARXLY's only
//  liquidity is a Doppler v4 pool (SEARXLY/WETH, dynamic fee + fee-taking hook) on Base, so we drive
//  Uniswap v4 directly: the V4 Quoter prices a swap (read-only eth_call, so the dynamic + hook fee are
//  reflected), and the UniversalRouter executes it. Native-ETH swaps wrap/unwrap WETH around the
//  router; selling an ERC-20 pulls it from the user via Permit2.
//
//  Every constant here was verified ON-CHAIN before shipping: the PoolKey from the pool's Initialize
//  event, and the exact router calldata by decoding real swaps + simulating our own bytes against the
//  deployed router (see WalletConfig.universalRouterV4). The encoders below reproduce that layout
//  byte-for-byte.
//

import Foundation

enum UniswapV4 {

    /// UniversalRouter sentinel: "the router itself" (used as a wrap/take recipient mid-route).
    static let addressThis = "0x0000000000000000000000000000000000000002"

    /// The result of pricing + encoding a v4 swap, shaped to drop into the existing SwapQuote/executeSwap.
    struct Built {
        let amountOut: [UInt8]      // base units of the buy token (from the Quoter)
        let minAmountOut: [UInt8]   // amountOut minus slippage
        let to: String              // UniversalRouter
        let valueHex: String        // ETH value (native-ETH buys) or "0x0"
        let dataHex: String         // execute(...) calldata
        let gas: UInt64             // suggested gas limit (over-estimating is free — you pay actual)
        let permit2Token: String?   // ERC-20 to authorize via Permit2 before swapping; nil for ETH input
    }

    // MARK: - Pair classification

    /// True only for ETH/WETH ↔ SEARXLY on Base — the one pair we route natively.
    static func supports(sell: WalletToken, buy: WalletToken) -> Bool {
        sell.chainId == WalletConfig.baseChainID && buy.chainId == WalletConfig.baseChainID
            && ((isSearxly(sell) && isETHLike(buy)) || (isSearxly(buy) && isETHLike(sell)))
    }

    private static func isSearxly(_ t: WalletToken) -> Bool {
        t.id == "SEARXLY" || t.symbol.uppercased() == "SEARXLY"
            || t.contractAddress?.lowercased() == WalletConfig.searxlyTokenAddress.lowercased()
    }

    private static func isETHLike(_ t: WalletToken) -> Bool {
        t.isNative || t.contractAddress?.lowercased() == WalletConfig.wethAddress.lowercased()
    }

    // MARK: - Price + build (the entry point WalletSwap calls)

    static func quoteAndBuild(sell: WalletToken, buy: WalletToken, sellAmount: Decimal,
                              taker: String, rpc: String) async -> Built? {
        guard supports(sell: sell, buy: buy), !taker.isEmpty else { return nil }
        let inputIsNative = sell.isNative
        let outputIsNative = buy.isNative
        // The pool trades SEARXLY/WETH; native ETH is wrapped/unwrapped around it, so the pool-side
        // currency for a native side is WETH.
        let swapIn = inputIsNative ? WalletConfig.wethAddress : (sell.contractAddress ?? "")
        let swapOut = outputIsNative ? WalletConfig.wethAddress : (buy.contractAddress ?? "")
        guard !swapIn.isEmpty, !swapOut.isEmpty else { return nil }

        let amountIn = WeiConverter.baseUnitBytes(amount: sellAmount, decimals: sell.decimals)
        guard !isZero(amountIn) else { return nil }

        guard let q = await quote(swapIn: swapIn, amountIn: amountIn, rpc: rpc), !isZero(q.out) else { return nil }
        let minOut = applySlippage(q.out, bps: WalletConfig.v4SlippageBps)
        let deadline = UInt64(Date().timeIntervalSince1970) + 1800   // 30 min

        let swap = buildSwap(swapIn: swapIn, swapOut: swapOut,
                             inputIsNative: inputIsNative, outputIsNative: outputIsNative,
                             amountIn: amountIn, amountOutMin: minOut, recipient: taker, deadline: deadline)

        return Built(amountOut: q.out, minAmountOut: minOut, to: swap.to, valueHex: swap.valueHex,
                     dataHex: swap.dataHex, gas: max(q.gas + 300_000, 600_000),
                     permit2Token: inputIsNative ? nil : swapIn)
    }

    // MARK: - Quote (V4 Quoter, read-only)

    /// Calls `quoteExactInputSingle((PoolKey,bool,uint128,bytes))` (selector 0xaa9d21cb) and returns
    /// (amountOut base units, gasEstimate). Empty hookData — validated to price this Doppler pool.
    static func quote(swapIn: String, amountIn: [UInt8], rpc: String) async -> (out: [UInt8], gas: UInt64)? {
        let zeroForOne = swapIn.lowercased() == WalletConfig.searxlyTokenAddress.lowercased()
        var d = Data([0xaa, 0x9d, 0x21, 0xcb])
        d.append(word(UInt64(0x20)))                                  // offset to params tuple
        d.append(wordAddress(WalletConfig.searxlyTokenAddress))       // PoolKey.currency0 (SEARXLY)
        d.append(wordAddress(WalletConfig.wethAddress))               // PoolKey.currency1 (WETH)
        d.append(word(UInt64(WalletConfig.searxlyPoolFee)))
        d.append(word(UInt64(WalletConfig.searxlyPoolTickSpacing)))
        d.append(wordAddress(WalletConfig.searxlyPoolHooks))
        d.append(word(UInt64(zeroForOne ? 1 : 0)))
        d.append(word(amountIn))                                      // exactAmount (uint128)
        d.append(word(UInt64(0x100)))                                 // offset to hookData (8 words)
        d.append(word(UInt64(0)))                                     // hookData length = 0
        let dataHex = "0x" + d.map { String(format: "%02x", $0) }.joined()

        let res = await WalletNetwork.rawCall(method: "eth_call",
                    params: [["to": WalletConfig.v4QuoterAddress, "data": dataHex], "latest"], rpc: rpc)
        guard let hex = res.result as? String else { return nil }
        let bytes = RLP.dataFromHex(hex)
        guard bytes.count >= 64 else { return nil }                   // (uint256 amountOut, uint256 gasEstimate)
        let out = trimLeading([UInt8](bytes.prefix(32)))
        var gas: UInt64 = 0
        for b in bytes.subdata(in: 32..<64).suffix(8) { gas = (gas << 8) | UInt64(b) }
        return (out, gas)
    }

    // MARK: - Swap calldata (UniversalRouter.execute)

    /// Builds the full `execute(bytes,bytes[],uint256)` calldata. Four shapes, all from one template:
    /// native-ETH input wraps first (SETTLE pays from the router); ERC-20 input is pulled from the user
    /// via Permit2 (SETTLE payerIsUser=true); native-ETH output takes WETH to the router then unwraps.
    static func buildSwap(swapIn: String, swapOut: String, inputIsNative: Bool, outputIsNative: Bool,
                          amountIn: [UInt8], amountOutMin: [UInt8], recipient: String,
                          deadline: UInt64) -> (to: String, valueHex: String, dataHex: String) {
        let actions = Data([0x07, 0x0b, 0x0e])   // SWAP_EXACT_IN, SETTLE, TAKE
        let params = [
            exactInputParams(currencyIn: swapIn, intermediate: swapOut, amountIn: amountIn, amountOutMin: amountOutMin),
            settle(currency: swapIn, payerIsUser: !inputIsNative),
            take(currency: swapOut, recipient: outputIsNative ? addressThis : recipient),
        ]
        let v4Input = twoDyn(actions, bytesArray(params))

        var commands = Data()
        var inputs: [Data] = []
        if inputIsNative {
            commands.append(0x0b)                                    // WRAP_ETH
            inputs.append(wrapETH(recipient: addressThis, amount: amountIn))
        }
        commands.append(0x10)                                        // V4_SWAP
        inputs.append(v4Input)
        if outputIsNative {
            commands.append(0x0c)                                    // UNWRAP_WETH
            inputs.append(unwrapWETH(recipient: recipient, amountMin: amountOutMin))
        }
        let data = executeCalldata(commands: commands, inputs: inputs, deadline: deadline)
        let valueHex = inputIsNative ? hexUint(amountIn) : "0x0"
        return (WalletConfig.universalRouterV4, valueHex, "0x" + data.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Permit2

    /// `Permit2.approve(token, spender, uint160 max, uint48 maxExpiration)` (selector 0x87517c45) —
    /// authorizes the UniversalRouter to pull `token` from the user. One-time per token.
    static func permit2ApproveData(token: String, spender: String) -> Data {
        var d = Data([0x87, 0x51, 0x7c, 0x45])
        d.append(wordAddress(token))
        d.append(wordAddress(spender))
        d.append(word([UInt8](repeating: 0xff, count: 20)))          // uint160 max
        d.append(word(UInt64(0xffffffffffff)))                       // uint48 max expiration
        return d
    }

    /// `Permit2.allowance(owner, token, spender)` → (uint160 amount, uint48 expiration, uint48 nonce);
    /// selector 0x927da105. Lets us skip a redundant approval when one is already live.
    static func permit2Allowance(owner: String, token: String, spender: String,
                                 rpc: String) async -> (amount: [UInt8], expiration: UInt64)? {
        var d = Data([0x92, 0x7d, 0xa1, 0x05])
        d.append(wordAddress(owner))
        d.append(wordAddress(token))
        d.append(wordAddress(spender))
        let dataHex = "0x" + d.map { String(format: "%02x", $0) }.joined()
        let res = await WalletNetwork.rawCall(method: "eth_call",
                    params: [["to": WalletConfig.permit2Address, "data": dataHex], "latest"], rpc: rpc)
        guard let hex = res.result as? String else { return nil }
        let bytes = RLP.dataFromHex(hex)
        guard bytes.count >= 64 else { return nil }
        let amount = trimLeading([UInt8](bytes.prefix(32)))
        var exp: UInt64 = 0
        for b in bytes.subdata(in: 32..<64).suffix(8) { exp = (exp << 8) | UInt64(b) }
        return (amount, exp)
    }

    // MARK: - v4 action params

    /// abi.encode(ExactInputParams) for the deployed router: a 1-hop PathKey + an empty
    /// `minHopPriceX36[]`. Layout verified against a live swap (15 words).
    private static func exactInputParams(currencyIn: String, intermediate: String,
                                         amountIn: [UInt8], amountOutMin: [UInt8]) -> Data {
        var d = Data()
        d.append(word(UInt64(0x20)))                                 // offset to the (dynamic) tuple
        d.append(wordAddress(currencyIn))                            // currencyIn
        d.append(word(UInt64(0xa0)))                                 // offset → path[]
        d.append(word(UInt64(0x1a0)))                                // offset → minHopPriceX36[]
        d.append(word(amountIn))                                     // amountIn (uint128)
        d.append(word(amountOutMin))                                 // amountOutMinimum (uint128)
        d.append(word(UInt64(1)))                                    // path length = 1
        d.append(word(UInt64(0x20)))                                 // offset → path[0]
        d.append(wordAddress(intermediate))                         // PathKey.intermediateCurrency
        d.append(word(UInt64(WalletConfig.searxlyPoolFee)))          // PathKey.fee (dynamic flag)
        d.append(word(UInt64(WalletConfig.searxlyPoolTickSpacing)))  // PathKey.tickSpacing
        d.append(wordAddress(WalletConfig.searxlyPoolHooks))         // PathKey.hooks
        d.append(word(UInt64(0xa0)))                                 // offset → hookData
        d.append(word(UInt64(0)))                                    // hookData length = 0
        d.append(word(UInt64(0)))                                    // minHopPriceX36 length = 0
        return d
    }

    /// SETTLE: (currency, OPEN_DELTA, payerIsUser). payerIsUser=false pays from the router's balance
    /// (wrapped ETH); true pulls the ERC-20 from the user via Permit2.
    private static func settle(currency: String, payerIsUser: Bool) -> Data {
        var d = wordAddress(currency)
        d.append(word(UInt64(0)))                                    // amount = OPEN_DELTA (full debt)
        d.append(word(UInt64(payerIsUser ? 1 : 0)))
        return d
    }

    /// TAKE: (currency, recipient, OPEN_DELTA). recipient = the user, or the router when the output
    /// will be unwrapped to native ETH afterwards.
    private static func take(currency: String, recipient: String) -> Data {
        var d = wordAddress(currency)
        d.append(wordAddress(recipient))
        d.append(word(UInt64(0)))                                    // amount = OPEN_DELTA (full credit)
        return d
    }

    private static func wrapETH(recipient: String, amount: [UInt8]) -> Data {
        var d = wordAddress(recipient); d.append(word(amount)); return d
    }
    private static func unwrapWETH(recipient: String, amountMin: [UInt8]) -> Data {
        var d = wordAddress(recipient); d.append(word(amountMin)); return d
    }

    // MARK: - UniversalRouter execute / V4_SWAP framing

    /// execute(bytes commands, bytes[] inputs, uint256 deadline) — selector 0x3593564c.
    private static func executeCalldata(commands: Data, inputs: [Data], deadline: UInt64) -> Data {
        let ec = dynBytes(commands)
        var d = Data([0x35, 0x93, 0x56, 0x4c])
        d.append(word(UInt64(96)))                                   // offset → commands
        d.append(word(UInt64(96 + ec.count)))                        // offset → inputs
        d.append(word(deadline))
        d.append(ec)
        d.append(bytesArray(inputs))
        return d
    }

    /// V4_SWAP input = abi.encode(bytes actions, bytes[] params).
    private static func twoDyn(_ actions: Data, _ paramsArray: Data) -> Data {
        let ea = dynBytes(actions)
        var d = word(UInt64(64))                                     // offset → actions
        d.append(word(UInt64(64 + ea.count)))                        // offset → params
        d.append(ea)
        d.append(paramsArray)
        return d
    }

    // MARK: - ABI primitives

    /// A dynamic `bytes`: length word, data, right-padded to a 32-byte boundary.
    private static func dynBytes(_ data: Data) -> Data {
        var out = word(UInt64(data.count))
        out.append(data)
        let pad = (32 - data.count % 32) % 32
        if pad > 0 { out.append(Data(repeating: 0, count: pad)) }
        return out
    }

    /// A dynamic `bytes[]`: count, then a relative offset per element, then the encoded elements.
    private static func bytesArray(_ items: [Data]) -> Data {
        var out = word(UInt64(items.count))
        var tail = Data()
        var offset = 32 * items.count
        for it in items {
            out.append(word(UInt64(offset)))
            let enc = dynBytes(it)
            tail.append(enc)
            offset += enc.count
        }
        out.append(tail)
        return out
    }

    /// Left-pads a big-endian byte value to a 32-byte ABI word.
    private static func word(_ bytes: [UInt8]) -> Data {
        let b = bytes.count > 32 ? Array(bytes.suffix(32)) : bytes
        return Data(repeating: 0, count: 32 - b.count) + Data(b)
    }
    private static func word(_ v: UInt64) -> Data { word(intBytes(v)) }

    /// 12 zero bytes + the 20-byte address.
    private static func wordAddress(_ address: String) -> Data {
        let raw = [UInt8](RLP.dataFromHex(address))
        let a = raw.count > 20 ? Array(raw.suffix(20)) : raw
        return Data(repeating: 0, count: 32 - a.count) + Data(a)
    }

    private static func intBytes(_ v: UInt64) -> [UInt8] {
        if v == 0 { return [0] }
        var x = v; var out = [UInt8]()
        while x > 0 { out.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return out
    }

    private static func hexUint(_ bytes: [UInt8]) -> String {
        let b = trimLeading(bytes)
        if isZero(b) { return "0x0" }
        return "0x" + b.map { String(format: "%02x", $0) }.joined()
    }

    private static func trimLeading(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        while b.count > 1 && b.first == 0 { b.removeFirst() }
        return b
    }

    private static func isZero(_ bytes: [UInt8]) -> Bool {
        bytes.isEmpty || bytes.allSatisfy { $0 == 0 }
    }

    /// amountOut * (10000 - bps) / 10000, in Decimal (exact for the integer base-unit magnitudes here).
    private static func applySlippage(_ amountOut: [UInt8], bps: Int) -> [UInt8] {
        var value = Decimal(0)
        for b in amountOut { value = value * 256 + Decimal(UInt64(b)) }
        var scaled = value * Decimal(10000 - bps) / Decimal(10000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return WeiConverter.decimalStringToBytes("\(rounded)")
    }
}
