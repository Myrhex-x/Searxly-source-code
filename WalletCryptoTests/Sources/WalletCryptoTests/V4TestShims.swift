//
//  V4TestShims.swift
//
//  Minimal stand-ins for the app-coupled types that the symlinked production UniswapV4.swift
//  references (WalletConfig / WalletToken / WalletNetwork), so it compiles in this standalone test
//  package. The constants mirror the real WalletConfig; the network call is a stub because the golden
//  tests exercise only the pure, deterministic encoders (buildSwap / permit2ApproveData / supports),
//  never the live Quoter. The encoders' byte layout was independently validated on-chain.
//
import Foundation

enum WalletConfig {
    static let searxlyTokenAddress    = "0x0fdc79b868bc4a6295cd94397f61890f68c38ba3"
    static let wethAddress            = "0x4200000000000000000000000000000000000006"
    static let universalRouterV4      = "0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7"
    static let v4QuoterAddress        = "0x0d5e0f971ed27fbff6c2837bf31316121532048d"
    static let permit2Address         = "0x000000000022d473030f116ddee9f6b43ac78ba3"
    static let searxlyPoolFee         = 0x800000
    static let searxlyPoolTickSpacing = 200
    static let searxlyPoolHooks       = "0xbdf938149ac6a781f94faa0ed45e6a0e984c6544"
    static let baseChainID            = 8453
    static let v4SlippageBps          = 200
}

struct WalletToken {
    let id: String
    let symbol: String
    let contractAddress: String?
    let decimals: Int
    var chainId: Int = 8453
    var isNative: Bool { contractAddress == nil }
}

enum WalletNetwork {
    static func rawCall(method: String, params: [Any], rpc: String) async -> (result: Any?, error: String?) {
        (nil, "stub")   // unused by the golden-byte tests
    }
}
