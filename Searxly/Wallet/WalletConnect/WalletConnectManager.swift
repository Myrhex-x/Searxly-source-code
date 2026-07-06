//
//  WalletConnectManager.swift
//  Searxly
//
//  A native (no-SDK) WalletConnect v2 client: relay WebSocket (URLSessionWebSocketTask), the
//  ed25519 `did:key` relay-auth JWT, the symmetric envelope (see WalletConnectCrypto), pairing,
//  session settle, and request routing into the wallet's existing approval + signing flow.
//
//  PRIVACY (disclosed to the user before enabling): WalletConnect routes messages through a public
//  relay server. The relay sees connection metadata and your IP, though message contents are
//  end-to-end encrypted and your keys never leave the device. It's opt-in and off by default.
//
//  VERIFICATION: the crypto + envelope are correct by construction, but the end-to-end relay
//  handshake (auth JWT, message tags, namespace settle) can only be validated against a live dApp
//  with a WalletConnect Cloud project id. Treat as a v1 that may need a round of live debugging.
//

import Foundation
import CryptoKit
import Observation

struct WCSession: Identifiable, Equatable {
    let topic: String
    let name: String
    let url: String
    let accountIndex: Int
    var id: String { topic }
}

@MainActor
@Observable
final class WalletConnectManager {
    static let shared = WalletConnectManager()

    // MARK: - Settings

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "Wallet.wc.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "Wallet.wc.enabled"); if !newValue { disconnectAll() } }
    }
    /// Free WalletConnect Cloud project id (required by the relay). Stored in the Keychain.
    var projectId: String {
        get { WalletKeychain.loadString(forKey: "wallet-wc-project-id") ?? "" }
        set { WalletKeychain.saveString(newValue, forKey: "wallet-wc-project-id") }
    }

    private(set) var sessions: [WCSession] = []
    private(set) var status: String = ""

    private let relayHost = "relay.walletconnect.org"

    // MARK: - State

    private var ws: URLSessionWebSocketTask?
    private var pairingKeys: [String: SymmetricKey] = [:]   // pairing topic → symKey
    private var sessionKeys: [String: SymmetricKey] = [:]   // session topic → symKey
    private var proposalKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:] // pairing topic → our X25519 priv
    private var rpcId: Int = Int(Date().timeIntervalSince1970 * 1000)

    private init() {}

    // MARK: - Public entry

    /// Pairs with a `wc:…@2?relay-protocol=irn&symKey=…` URI copied from a dApp.
    func pair(uri: String) async {
        guard enabled else { status = "Turn on WalletConnect in Settings first."; return }
        guard !projectId.isEmpty else { status = "Add your WalletConnect project id in Settings first."; return }
        guard let parsed = Self.parse(uri: uri),
              let symKey = WalletConnectCrypto.symKey(fromHex: parsed.symKey) else {
            status = "That doesn't look like a valid WalletConnect link."
            return
        }
        pairingKeys[parsed.topic] = symKey
        status = "Connecting…"
        guard await ensureConnected() else { status = "Couldn't reach the WalletConnect relay."; return }
        await subscribe(topic: parsed.topic)
        // The dApp now publishes wc_sessionPropose to this topic; handled in the receive loop.
    }

    func disconnect(topic: String) {
        if let key = sessionKeys[topic] {
            let payload: [String: Any] = ["id": nextId(), "jsonrpc": "2.0", "method": "wc_sessionDelete",
                                          "params": ["code": 6000, "message": "User disconnected"]]
            Task { await publish(topic: topic, payload: payload, key: key, tag: 1112) }
        }
        sessionKeys[topic] = nil
        sessions.removeAll { $0.topic == topic }
    }

    func disconnectAll() {
        sessions.map { $0.topic }.forEach(disconnect)
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
    }

    // MARK: - Relay connection

    private func ensureConnected() async -> Bool {
        if ws?.state == .running { return true }
        // Fail closed in Maximum Privacy when protection is down: the relay WebSocket would expose the
        // real IP (URLSession isn't routed through Tor). Same native-egress kill switch as search/RPC.
        guard PrivacyGate.egressAllowedFast else { return false }
        guard let token = relayAuthJWT(),
              let url = URL(string: "wss://\(relayHost)/?projectId=\(projectId)&auth=\(token)") else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop()
        // Give the socket a moment to open.
        try? await Task.sleep(nanoseconds: 600_000_000)
        return ws?.state == .running
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    self.status = "WalletConnect relay disconnected."
                case .success(let message):
                    if case .string(let text) = message { self.handleRelayMessage(text) }
                    self.receiveLoop()
                }
            }
        }
    }

    private func subscribe(topic: String) async {
        let payload: [String: Any] = ["id": nextId(), "jsonrpc": "2.0", "method": "irn_subscribe",
                                      "params": ["topic": topic]]
        await sendRaw(payload)
    }

    private func publish(topic: String, payload: [String: Any], key: SymmetricKey, tag: Int) async {
        guard let inner = try? JSONSerialization.data(withJSONObject: payload),
              let envelope = WalletConnectCrypto.encrypt(inner, key: key) else { return }
        let relay: [String: Any] = ["id": nextId(), "jsonrpc": "2.0", "method": "irn_publish",
                                    "params": ["topic": topic, "message": envelope, "ttl": 300, "tag": tag, "prompt": tag == 1108]]
        await sendRaw(relay)
    }

    private func sendRaw(_ object: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await ws?.send(.string(text))
    }

    // MARK: - Incoming relay messages

    private func handleRelayMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // ACK relay subscription pushes and route their payloads.
        if (json["method"] as? String) == "irn_subscription",
           let params = json["params"] as? [String: Any],
           let inner = params["data"] as? [String: Any],
           let topic = inner["topic"] as? String,
           let message = inner["message"] as? String {
            if let ackId = json["id"] as? Int { Task { await sendRaw(["id": ackId, "jsonrpc": "2.0", "result": true]) } }
            routeEnvelope(topic: topic, message: message)
        }
    }

    private func routeEnvelope(topic: String, message: String) {
        // Pick the key for this topic (pairing or session). Type-1 envelopes carry the sender key.
        var key = pairingKeys[topic] ?? sessionKeys[topic]
        if key == nil, let senderHex = WalletConnectCrypto.senderPublicKeyHex(fromEnvelope: message),
           let ourPriv = proposalKeys[topic] {
            key = WalletConnectCrypto.deriveSymKey(privateKey: ourPriv, peerPublicKeyHex: senderHex)
        }
        guard let key, let plaintext = WalletConnectCrypto.decrypt(message, key: key),
              let rpc = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else { return }

        let method = rpc["method"] as? String
        let id = rpc["id"] as? Int ?? 0
        let params = rpc["params"] as? [String: Any] ?? [:]

        switch method {
        case "wc_sessionPropose": Task { await onProposal(pairingTopic: topic, id: id, params: params) }
        case "wc_sessionRequest": Task { await onRequest(sessionTopic: topic, id: id, params: params) }
        case "wc_sessionDelete":  sessions.removeAll { $0.topic == topic }; sessionKeys[topic] = nil
        case "wc_sessionPing":    Task { await respond(topic: topic, id: id, key: key, result: true, tag: 1115) }
        default: break
        }
    }

    // MARK: - Session proposal → settle

    private func onProposal(pairingTopic: String, id: Int, params: [String: Any]) async {
        guard let proposer = params["proposer"] as? [String: Any],
              let proposerPubHex = proposer["publicKey"] as? String,
              let pairingKey = pairingKeys[pairingTopic] else { return }
        let metadata = proposer["metadata"] as? [String: Any]
        let name = (metadata?["name"] as? String) ?? "A website"
        let urlStr = (metadata?["url"] as? String) ?? ""
        let origin = originHost(urlStr)

        // Reuse the standard connect approval sheet.
        let approved = await WalletProviderBridge.shared.requestApproval(.connect, origin: origin.isEmpty ? name : origin) != nil
        guard approved else { return }

        let accountIndex = WalletManager.shared.activeAccountIndex
        guard let address = WalletManager.shared.address(forAccount: accountIndex) else { return }

        // Our session keypair + derived session key + topic.
        let kp = WalletConnectCrypto.generateKeyPair()
        guard let sessionKey = WalletConnectCrypto.deriveSymKey(privateKey: kp.privateKey, peerPublicKeyHex: proposerPubHex) else { return }
        let sessionTopic = WalletConnectCrypto.topic(forSymKey: sessionKey)
        sessionKeys[sessionTopic] = sessionKey

        // 1. Respond to the proposal on the PAIRING topic with our public key.
        let proposeResponse: [String: Any] = ["id": id, "jsonrpc": "2.0",
            "result": ["relay": ["protocol": "irn"], "responderPublicKey": kp.publicKeyHex]]
        await publish(topic: pairingTopic, payload: proposeResponse, key: pairingKey, tag: 1101)

        // 2. Subscribe + settle on the SESSION topic.
        await subscribe(topic: sessionTopic)
        let account = "eip155:\(WalletConfig.baseChainID):\(address)"
        let namespaces: [String: Any] = ["eip155": [
            "accounts": [account],
            "methods": ["eth_sendTransaction", "personal_sign", "eth_signTypedData", "eth_signTypedData_v4", "eth_accounts", "eth_chainId"],
            "events": ["accountsChanged", "chainChanged"],
            "chains": ["eip155:\(WalletConfig.baseChainID)"]]]
        let settle: [String: Any] = ["id": nextId(), "jsonrpc": "2.0", "method": "wc_sessionSettle",
            "params": ["relay": ["protocol": "irn"],
                       "controller": ["publicKey": kp.publicKeyHex, "metadata": ["name": "Searxly Wallet", "description": "Private browser wallet", "url": "https://searxly.app", "icons": []]],
                       "namespaces": namespaces,
                       "expiry": Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)]]
        await publish(topic: sessionTopic, payload: settle, key: sessionKey, tag: 1102)

        sessions.append(WCSession(topic: sessionTopic, name: name, url: urlStr, accountIndex: accountIndex))
        status = "Connected to \(name)."
    }

    // MARK: - Session requests

    private func onRequest(sessionTopic: String, id: Int, params: [String: Any]) async {
        guard let key = sessionKeys[sessionTopic],
              let request = params["request"] as? [String: Any],
              let method = request["method"] as? String else { return }
        let reqParams = request["params"] as? [Any] ?? []
        let origin = sessions.first { $0.topic == sessionTopic }.map { originHost($0.url) } ?? "WalletConnect"
        let accountIndex = sessions.first { $0.topic == sessionTopic }?.accountIndex ?? WalletManager.shared.activeAccountIndex
        let bridge = WalletProviderBridge.shared

        switch method {
        case "eth_chainId":
            await respond(topic: sessionTopic, id: id, key: key, result: WalletConfig.baseChainIDHex, tag: 1109)
        case "eth_accounts":
            let addr = WalletManager.shared.address(forAccount: accountIndex).map { [$0] } ?? []
            await respond(topic: sessionTopic, id: id, key: key, result: addr, tag: 1109)

        case "personal_sign":
            let message = (reqParams.compactMap { $0 as? String }.first { !isAddress($0) }) ?? (reqParams.first as? String) ?? ""
            guard let pin = await bridge.requestApproval(.signMessage(text: humanReadable(message)), origin: origin) else {
                return await respondError(topic: sessionTopic, id: id, key: key, message: "User rejected")
            }
            if let sig = WalletManager.shared.dappPersonalSign(message: message, pin: pin, accountIndex: accountIndex) {
                await respond(topic: sessionTopic, id: id, key: key, result: sig, tag: 1109)
            } else { await respondError(topic: sessionTopic, id: id, key: key, message: "Signing failed") }

        case "eth_signTypedData", "eth_signTypedData_v4":
            let json = typedDataJSON(reqParams) ?? ""
            let typedPreview = TypedDataPreview(json: json,
                                                ownAddress: WalletManager.shared.address(forAccount: accountIndex),
                                                activeChain: WalletManager.shared.activeChain)
            guard let pin = await bridge.requestApproval(.signTypedData(typedPreview), origin: origin) else {
                return await respondError(topic: sessionTopic, id: id, key: key, message: "User rejected")
            }
            if let sig = WalletManager.shared.dappSignTypedData(json: json, pin: pin, accountIndex: accountIndex) {
                await respond(topic: sessionTopic, id: id, key: key, result: sig, tag: 1109)
            } else { await respondError(topic: sessionTopic, id: id, key: key, message: "Signing failed") }

        case "eth_sendTransaction":
            guard let tx = reqParams.first as? [String: Any], let to = tx["to"] as? String else {
                return await respondError(topic: sessionTopic, id: id, key: key, message: "Invalid transaction")
            }
            let valueHex = tx["value"] as? String
            let dataHex = (tx["data"] as? String) ?? (tx["input"] as? String)
            let gasHex = (tx["gas"] as? String) ?? (tx["gasLimit"] as? String)
            guard let pin = await bridge.requestApproval(.transaction(TxPreview(to: to, valueHex: valueHex, dataHex: dataHex)), origin: origin) else {
                return await respondError(topic: sessionTopic, id: id, key: key, message: "User rejected")
            }
            let r = await WalletManager.shared.dappSendTransaction(toHex: to, valueHex: valueHex, dataHex: dataHex, gasHex: gasHex, pin: pin, accountIndex: accountIndex)
            if let hash = r.hash { await respond(topic: sessionTopic, id: id, key: key, result: hash, tag: 1109) }
            else { await respondError(topic: sessionTopic, id: id, key: key, message: r.error ?? "Transaction failed") }

        default:
            await respondError(topic: sessionTopic, id: id, key: key, message: "Method not supported")
        }
    }

    private func respond(topic: String, id: Int, key: SymmetricKey, result: Any, tag: Int) async {
        await publish(topic: topic, payload: ["id": id, "jsonrpc": "2.0", "result": result], key: key, tag: tag)
    }
    private func respondError(topic: String, id: Int, key: SymmetricKey, message: String) async {
        await publish(topic: topic, payload: ["id": id, "jsonrpc": "2.0", "error": ["code": 5000, "message": message]], key: key, tag: 1109)
    }

    // MARK: - Relay auth JWT (ed25519 did:key)

    private func relayAuthJWT() -> String? {
        let priv = clientKey()
        let pub = priv.publicKey.rawRepresentation
        let didKey = "did:key:z" + Base58.encode([0xed, 0x01] + [UInt8](pub))
        let header = ["alg": "EdDSA", "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = ["iss": didKey, "sub": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                                      "aud": "wss://\(relayHost)", "iat": now, "exp": now + 3600]
        guard let h = try? JSONSerialization.data(withJSONObject: header),
              let p = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let signingInput = b64url(h) + "." + b64url(p)
        guard let sig = try? priv.signature(for: Data(signingInput.utf8)) else { return nil }
        return signingInput + "." + b64url(sig)
    }

    /// A persistent ed25519 client key for relay auth.
    private func clientKey() -> Curve25519.Signing.PrivateKey {
        if let raw = WalletKeychain.loadString(forKey: "wallet-wc-client-key"),
           let d = WalletConnectCrypto.data(fromHex: raw),
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        WalletKeychain.saveString(WalletConnectCrypto.hex(k.rawRepresentation), forKey: "wallet-wc-client-key")
        return k
    }

    // MARK: - Helpers

    private func nextId() -> Int { rpcId += 1; return rpcId }
    private func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func isAddress(_ s: String) -> Bool { s.hasPrefix("0x") && s.count == 42 && s.dropFirst(2).allSatisfy { $0.isHexDigit } }
    private func humanReadable(_ m: String) -> String {
        guard m.hasPrefix("0x") else { return m }
        return String(data: RLP.dataFromHex(m), encoding: .utf8) ?? m
    }
    private func typedDataJSON(_ params: [Any]) -> String? {
        for p in params { if let s = p as? String, !isAddress(s) { return s }
            if let o = p as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: o) { return String(data: d, encoding: .utf8) } }
        return nil
    }
    private func originHost(_ url: String) -> String {
        guard let u = URL(string: url), let h = u.host else { return url }
        return h
    }

    static func parse(uri: String) -> (topic: String, symKey: String, relay: String)? {
        guard uri.hasPrefix("wc:"), let q = uri.firstIndex(of: "?") else { return nil }
        let head = uri[uri.index(uri.startIndex, offsetBy: 3)..<q]              // topic@2
        let topic = String(head.split(separator: "@").first ?? "")
        let query = String(uri[uri.index(after: q)...])
        var sym = "", relay = "irn"
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "symKey" { sym = String(kv[1]) }
            if kv[0] == "relay-protocol" { relay = String(kv[1]) }
        }
        guard !topic.isEmpty, !sym.isEmpty else { return nil }
        return (topic, sym, relay)
    }
}

// MARK: - Base58 (Bitcoin alphabet) for the did:key

enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    static func encode(_ bytes: [UInt8]) -> String {
        var zeros = 0
        for b in bytes { if b == 0 { zeros += 1 } else { break } }
        var input = bytes
        var result: [Character] = []
        var start = zeros
        while start < input.count {
            var remainder = 0
            for i in start..<input.count {
                let acc = remainder * 256 + Int(input[i])
                input[i] = UInt8(acc / 58)
                remainder = acc % 58
            }
            result.append(alphabet[remainder])
            if input[start] == 0 { start += 1 }
        }
        return String(repeating: "1", count: zeros) + String(result.reversed())
    }
}
