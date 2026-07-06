//
//  WalletProviderBridge.swift
//  Searxly
//
//  Routes EIP-1193 JSON-RPC requests coming from web pages (via the injected provider)
//  to the wallet. Read-only methods pass through to the Base RPC with no prompt; every
//  state-changing method (connect / sign / send) requires explicit, origin-bound user
//  approval and biometric-or-PIN authorization. The private key is never exposed to JS.
//

import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class WalletProviderBridge {
    static let shared = WalletProviderBridge()

    /// Serial queue of pending approval requests. Concurrent dApp requests (e.g. two tabs,
    /// or one dApp firing several) are handled one at a time instead of clobbering each other.
    private(set) var approvalQueue: [DAppApproval] = []

    /// The request currently shown in the approval sheet (front of the queue).
    var pendingApproval: DAppApproval? { approvalQueue.first }

    private let perm = DAppPermissionStore.shared
    private let webViews = NSHashTable<WKWebView>.weakObjects()

    /// The address a given origin sees — its assigned account (per-site isolation), falling back to
    /// the active account for a not-yet-mapped origin. nil for an uninitialized wallet.
    private func address(for origin: String) -> String? {
        let idx = perm.accountIndex(for: origin) ?? WalletManager.shared.activeAccountIndex
        let a = WalletManager.shared.address(forAccount: idx)
        return (a == nil || a == "0x0000000000000000000000000000000000000000") ? nil : a?.lowercased()
    }

    /// The origin's address only when the wallet is actually unlocked. Used for the SILENT
    /// `eth_accounts` query so a locked wallet never confirms the address to a page on demand
    /// (standard extension-wallet behavior). Interactive connect uses `address(for:)` directly.
    private func unlockedAddress(for origin: String) -> String? {
        WalletManager.shared.unlockState == .unlocked ? address(for: origin) : nil
    }

    private init() {}

    // MARK: - Web view registration (for pushing events back to pages)

    func register(_ webView: WKWebView) { webViews.add(webView) }

    private func emit(_ event: String, _ payload: Any) {
        // `.fragmentsAllowed` is required: `chainChanged` sends a BARE STRING ("0x2105") as the
        // payload, and without the option JSONSerialization raises an ObjC NSInvalidArgumentException
        // ("Invalid top-level type in JSON write") that Swift's `try?` cannot catch — it crashed the
        // app (or froze it under the debugger) on every chain switch.
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        // Pass the JSON payload as a base64 blob decoded by atob() instead of hand-escaping it into a
        // JS string literal. base64 is [A-Za-z0-9+/=] only, so there is nothing to break out of the
        // single-quoted argument — no JS-injection risk even if a payload ever carried quotes,
        // backslashes, or line/paragraph separators. (`event` is always an app-controlled constant,
        // and the emitted payloads are ASCII, so atob's byte-for-byte decode round-trips the JSON.)
        let b64 = Data(json.utf8).base64EncodedString()
        let js = "window.__searxlyWalletEmit && window.__searxlyWalletEmit('\(event)', atob('\(b64)'))"
        for wv in webViews.allObjects { wv.evaluateJavaScript(js, completionHandler: nil) }
    }

    /// Broadcasts an accounts list to all pages. Only ever called with an EMPTY list (on
    /// lock / disconnect) — we never broadcast the address, since that would leak it to other
    /// open tabs. A connecting dApp receives the address from its own request's return value.
    func emitAccountsChanged(_ accounts: [String]) { emit("accountsChanged", accounts) }

    /// Broadcasts the active chain id (hex) to all pages — EIP-1193 `chainChanged`.
    func emitChainChanged(_ chainIdHex: String) { emit("chainChanged", chainIdHex) }

    /// Called when the wallet locks — pages see an empty account set until re-auth.
    func walletDidLock() { emitAccountsChanged([]) }

    // MARK: - Request entry point

    /// Returns a JS-serializable reply: `["result": …]` or `["error": ["code":, "message":]]`.
    func handle(method: String, params: [Any], origin: String) async -> [String: Any] {
        guard WalletManager.shared.unlockState != .notSetup else {
            return err(4100, "No Searxly wallet has been set up")
        }

        switch method {
        case "eth_chainId":  return ok(WalletManager.shared.activeChain.chainIdHex)
        case "net_version":  return ok(String(WalletManager.shared.activeChain.id))

        case "eth_accounts":
            // Silent query: only answer for a connected origin AND only while unlocked. A locked
            // wallet returns [] so a page can't read the address without the user unlocking.
            return ok((perm.isConnected(origin) && unlockedAddress(for: origin) != nil) ? [unlockedAddress(for: origin)!] : [])

        case "eth_requestAccounts", "wallet_requestPermissions":
            return await connect(origin)

        case "wallet_getPermissions":
            return ok(perm.isConnected(origin) ? [["parentCapability": "eth_accounts"]] : [])

        case "wallet_revokePermissions":
            perm.disconnect(origin); emitAccountsChanged([]); return ok(NSNull())

        case "personal_sign":
            return await signPersonal(params: params, origin: origin)

        case "eth_signTypedData_v4", "eth_signTypedData_v3", "eth_signTypedData":
            return await signTyped(params: params, origin: origin)

        case "eth_sign":
            // Blind raw signing is a classic phishing vector — refuse it.
            return err(4200, "eth_sign is not supported by Searxly Wallet")

        case "eth_sendTransaction":
            return await sendTransaction(params: params, origin: origin)

        case "wallet_switchEthereumChain", "wallet_addEthereumChain":
            return await switchChainRequest(params, origin: origin)

        default:
            // Allowlisted read-only passthrough. Anything not explicitly safe is rejected so a
            // page can't make us call arbitrary/unknown methods through the wallet's RPC.
            guard Self.readOnlyMethods.contains(method) else {
                return err(4200, "Method \(method) is not supported by Searxly Wallet")
            }
            let r = await WalletNetwork.rawCall(method: method, params: params,
                                                rpc: WalletManager.shared.activeRPCURL)
            if let e = r.error { return err(-32603, e) }
            return ok(r.result ?? NSNull())
        }
    }

    /// Read-only JSON-RPC methods a page may call without connecting. Deliberately excludes
    /// anything that signs, broadcasts, or could be abused (e.g. eth_sendRawTransaction).
    private static let readOnlyMethods: Set<String> = [
        "eth_blockNumber", "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_feeHistory",
        "eth_maxPriorityFeePerGas", "eth_getBalance", "eth_getCode", "eth_getStorageAt",
        "eth_getTransactionByHash", "eth_getTransactionReceipt", "eth_getTransactionCount",
        "eth_getBlockByNumber", "eth_getBlockByHash", "eth_getLogs",
        "eth_getBlockTransactionCountByNumber", "eth_getBlockTransactionCountByHash",
        "eth_getProof", "eth_chainId", "web3_clientVersion",
    ]

    // MARK: - Connect

    private func connect(_ origin: String) async -> [String: Any] {
        // Already connected → return its assigned account (per-site isolation), no prompt.
        if perm.isConnected(origin), let addr = address(for: origin) {
            return ok([addr])
        }
        let approved = await present(.connect, origin: origin) != nil
        guard approved else { return err(4001, "User rejected the request") }
        // Unlinkability: when per-dApp rotation is on, give this new origin its OWN dedicated address
        // from the pre-derived pool so it can't be cross-linked to other sites. Otherwise bind it to
        // the currently-active account (and switching the active account later won't change what this
        // site sees — per-site isolation either way).
        let accountIndex: Int
        if WalletFeatures.rotatePerDApp, let rotation = WalletManager.shared.claimRotationAccount(for: origin) {
            accountIndex = rotation
        } else {
            accountIndex = WalletManager.shared.activeAccountIndex
        }
        perm.connect(origin, accountIndex: accountIndex)
        guard let addr = address(for: origin) else { return err(4001, "No wallet account available") }
        return ok([addr])
    }

    // MARK: - Sign message (personal_sign)

    private func signPersonal(params: [Any], origin: String) async -> [String: Any] {
        guard perm.isConnected(origin) else { return err(4100, "Connect the wallet first") }
        let message = messageParam(params, ownAddress: address(for: origin))
        let text = humanReadable(message)
        guard let pin = await present(.signMessage(text: text), origin: origin) else {
            return err(4001, "User rejected the request")
        }
        guard let sig = WalletManager.shared.dappPersonalSign(message: message, pin: pin,
                                                              accountIndex: perm.accountIndex(for: origin)) else {
            return err(-32603, "Signing failed")
        }
        return ok(sig)
    }

    // MARK: - Sign typed data (EIP-712)

    private func signTyped(params: [Any], origin: String) async -> [String: Any] {
        guard perm.isConnected(origin) else { return err(4100, "Connect the wallet first") }
        guard let json = typedDataParam(params) else { return err(-32602, "Invalid typed data") }
        // Decode the structured data so the user sees the ACTUAL fields (spender / amount / deadline)
        // they're signing — not just a type name. This is the core defense against Permit-style
        // signature drains, where the dangerous detail is hidden inside the message.
        let preview = TypedDataPreview(json: json, ownAddress: address(for: origin),
                                       activeChain: WalletManager.shared.activeChain)
        guard let pin = await present(.signTypedData(preview), origin: origin) else {
            return err(4001, "User rejected the request")
        }
        guard let sig = WalletManager.shared.dappSignTypedData(json: json, pin: pin,
                                                               accountIndex: perm.accountIndex(for: origin)) else {
            return err(-32603, "Signing failed")
        }
        return ok(sig)
    }

    // MARK: - Send transaction

    private func sendTransaction(params: [Any], origin: String) async -> [String: Any] {
        guard perm.isConnected(origin) else { return err(4100, "Connect the wallet first") }
        guard let txObj = params.first as? [String: Any], let to = txObj["to"] as? String else {
            return err(-32602, "Invalid transaction")
        }
        let valueHex = txObj["value"] as? String
        let dataHex  = (txObj["data"] as? String) ?? (txObj["input"] as? String)
        let gasHex   = (txObj["gas"] as? String) ?? (txObj["gasLimit"] as? String)

        let preview = TxPreview(to: to, valueHex: valueHex, dataHex: dataHex)
        guard let pin = await present(.transaction(preview), origin: origin) else {
            return err(4001, "User rejected the request")
        }
        let result = await WalletManager.shared.dappSendTransaction(
            toHex: to, valueHex: valueHex, dataHex: dataHex, gasHex: gasHex, pin: pin,
            accountIndex: perm.accountIndex(for: origin))
        if let hash = result.hash { return ok(hash) }
        return err(-32603, result.error ?? "Transaction failed")
    }

    // MARK: - Chain methods (Base, Ethereum, Optimism, Arbitrum, Polygon)

    /// Handles both `wallet_switchEthereumChain` and `wallet_addEthereumChain`. A page is NEVER
    /// allowed to silently change the active network — switching to a different chain requires the
    /// user's explicit approval (so a site can't flip you to another chain right before a sign).
    private func switchChainRequest(_ params: [Any], origin: String) async -> [String: Any] {
        guard let requested = (params.first as? [String: Any])?["chainId"] as? String,
              let chain = WalletChain.by(hexId: requested) else {
            return err(4902, "Searxly Wallet doesn’t support that chain yet.")
        }
        if chain.id == WalletManager.shared.activeChain.id { return ok(NSNull()) }   // already on it
        guard await present(.switchChain(chainName: chain.name), origin: origin) != nil else {
            return err(4001, "User rejected the request")
        }
        WalletManager.shared.switchChain(to: chain)   // updates active chain + emits chainChanged
        return ok(NSNull())
    }

    // MARK: - Approval plumbing

    /// Public entry so non-injected-provider flows (WalletConnect) can reuse the same approval UI.
    func requestApproval(_ kind: DAppApproval.Kind, origin: String) async -> String? {
        await present(kind, origin: origin)
    }

    private func present(_ kind: DAppApproval.Kind, origin: String) async -> String? {
        let approval = DAppApproval(kind: kind, origin: origin)
        // Flag known-scam / lookalike origins so the approval sheet can warn loudly.
        if case .flagged(let reason) = WalletPhishingGuard.check(origin: origin) {
            approval.phishingWarning = reason
        }
        return await withCheckedContinuation { cont in
            approval.continuation = cont
            approvalQueue.append(approval)   // shown when it reaches the front
        }
    }

    /// Called by an approval when the user decides. Dequeues it and resumes its waiter exactly once.
    func resolveApproval(_ approval: DAppApproval, pin: String?) {
        approvalQueue.removeAll { $0 === approval }
        approval.continuation?.resume(returning: pin)
        approval.continuation = nil
    }

    // MARK: - Reply builders

    private func ok(_ value: Any) -> [String: Any] { ["result": value] }
    private func err(_ code: Int, _ message: String) -> [String: Any] {
        ["error": ["code": code, "message": message]]
    }

    // MARK: - Param parsing & previews

    private func messageParam(_ params: [Any], ownAddress: String?) -> String {
        // personal_sign params are (message, address), but some dApps send them reversed. Pick the
        // element that is NOT a 20-byte address so we never accidentally sign the account address.
        let strings = params.compactMap { $0 as? String }
        if let nonAddr = strings.first(where: { !isAddress($0) }) { return nonAddr }
        // Both look like addresses (e.g. the message itself is 20 bytes of hex): prefer the one
        // that is NOT our own wallet address, which is the address argument.
        if let mine = ownAddress, let notMine = strings.first(where: { $0.lowercased() != mine }) {
            return notMine
        }
        return strings.first ?? ""
    }

    private func typedDataParam(_ params: [Any]) -> String? {
        for p in params {
            if let s = p as? String, !isAddress(s) { return s }                 // already JSON string
            if let obj = p as? [String: Any],
               let d = try? JSONSerialization.data(withJSONObject: obj),
               let s = String(data: d, encoding: .utf8) { return s }            // object → JSON
        }
        return nil
    }

    private func isAddress(_ s: String) -> Bool {
        s.hasPrefix("0x") && s.count == 42 && s.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    private func humanReadable(_ message: String) -> String {
        // personal_sign messages are usually hex-encoded UTF-8. Decode for display; if the bytes
        // aren't valid UTF-8, show the raw hex so we never misrepresent what's being signed.
        guard message.hasPrefix("0x") else { return message }
        let data = RLP.dataFromHex(message)
        return String(data: data, encoding: .utf8) ?? message
    }

}

// MARK: - Approval model

@MainActor
final class DAppApproval: Identifiable {
    enum Kind {
        case connect
        case signMessage(text: String)
        case signTypedData(TypedDataPreview)
        case transaction(TxPreview)
        case switchChain(chainName: String)
    }

    let id = UUID()
    let kind: Kind
    let origin: String
    var continuation: CheckedContinuation<String?, Never>?
    /// Non-nil when the origin is flagged as a likely scam/phishing site.
    var phishingWarning: String?
    private var done = false

    init(kind: Kind, origin: String) {
        self.kind = kind
        self.origin = origin
    }

    /// Approve → PIN string (verified by the sheet; "" allowed for connect). Reject/dismiss → nil.
    /// Idempotent: safe to call from both the buttons and sheet-dismissal.
    func decide(_ pin: String?) {
        guard !done else { return }
        done = true
        WalletProviderBridge.shared.resolveApproval(self, pin: pin)
    }
}
