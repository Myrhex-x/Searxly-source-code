//
//  DAppApprovalPreviews.swift
//  Searxly
//

import Foundation

// Flattens an EIP-712 message into human-readable lines for the approval sheet, flagging max-uint256
// values as "UNLIMITED", the signer's own address, and a domain chainId that differs from the wallet's.
struct TypedDataPreview {
    struct Line: Identifiable {
        let id = UUID()
        let indent: Int
        let label: String
        let value: String
        let flag: String?
    }

    let domainName: String?
    let primaryType: String
    let chainId: Int?
    let chainMismatch: Bool
    let activeChainName: String
    let lines: [Line]
    let hasUnlimited: Bool

    init(json: String, ownAddress: String?, activeChain: WalletChain) {
        let obj = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
        let primary = (obj["primaryType"] as? String) ?? "message"
        primaryType = primary
        let domain = (obj["domain"] as? [String: Any]) ?? [:]
        domainName = domain["name"] as? String
        let cid = Self.intValue(domain["chainId"])
        chainId = cid
        chainMismatch = (cid != nil && cid != activeChain.id)
        activeChainName = activeChain.name

        var types: [String: [(name: String, type: String)]] = [:]
        for (k, v) in (obj["types"] as? [String: Any]) ?? [:] {
            let fields = (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            types[k] = fields.compactMap { f in
                guard let n = f["name"] as? String, let t = f["type"] as? String else { return nil }
                return (n, t)
            }
        }
        let message = (obj["message"] as? [String: Any]) ?? [:]

        var collected: [Line] = []
        var anyUnlimited = false
        func walk(_ typeName: String, _ data: [String: Any], indent: Int) {
            guard indent < 4, let fields = types[typeName] else { return }   // depth-cap against cycles
            for field in fields {
                let raw = data[field.name]
                if types[field.type] != nil, let sub = raw as? [String: Any] {
                    collected.append(Line(indent: indent, label: field.name, value: "", flag: nil))
                    walk(field.type, sub, indent: indent + 1)
                } else {
                    let (val, flag) = Self.format(type: field.type, value: raw, ownAddress: ownAddress)
                    if flag == "UNLIMITED" { anyUnlimited = true }
                    collected.append(Line(indent: indent, label: field.name, value: val, flag: flag))
                }
            }
        }
        walk(primary, message, indent: 0)
        // Show raw keys if the type table doesn't describe the message, so nothing is hidden.
        if collected.isEmpty {
            for (k, v) in message { collected.append(Line(indent: 0, label: k, value: String(describing: v), flag: nil)) }
        }
        lines = collected
        hasUnlimited = anyUnlimited
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }
        return nil
    }

    private static func format(type: String, value: Any?, ownAddress: String?) -> (String, String?) {
        if type.hasSuffix("]") {
            let count = (value as? [Any])?.count ?? 0
            return ("\(count) item\(count == 1 ? "" : "s")", nil)
        }
        switch type {
        case "address":
            let a = (value as? String) ?? ""
            let flag = (ownAddress != nil && !a.isEmpty && a.lowercased() == ownAddress?.lowercased()) ? "your address" : nil
            return (abbreviate(a), flag)
        case "bool":
            let b = (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
            return (b ? "true" : "false", nil)
        case "string":
            return ((value as? String) ?? "", nil)
        default:
            if type.hasPrefix("uint") || type.hasPrefix("int") {
                let bytes = uintBytes(value)
                if bytes.count == 32 && bytes.allSatisfy({ $0 == 0xff }) { return ("Unlimited", "UNLIMITED") }
                if bytes.count <= 8 {
                    var v: UInt64 = 0; for b in bytes { v = (v << 8) | UInt64(b) }
                    return (String(v), nil)
                }
                return ("0x" + bytes.map { String(format: "%02x", $0) }.joined(), nil)
            }
            if let s = value as? String { return (s.count > 20 ? abbreviate(s) : s, nil) }
            return (value.map { String(describing: $0) } ?? "", nil)
        }
    }

    private static func uintBytes(_ value: Any?) -> [UInt8] {
        if let s = value as? String {
            if s.hasPrefix("0x") { return Array(RLP.dataFromHex(s)) }
            return WeiConverter.decimalStringToBytes(s)
        }
        if let n = value as? NSNumber { return WeiConverter.decimalStringToBytes(n.stringValue) }
        return []
    }

    private static func abbreviate(_ s: String) -> String {
        guard s.count > 14 else { return s }
        return "\(s.prefix(8))…\(s.suffix(6))"
    }
}

struct TxPreview {
    let to: String
    let valueHex: String?
    let dataHex: String?

    var valueEth: String {
        let bytes = Array(RLP.dataFromHex(valueHex ?? "0x0"))
        var v = 0.0
        for b in bytes { v = v * 256 + Double(b) }
        let eth = v / 1e18
        if eth == 0 { return "0" }
        if eth < 0.0001 { return String(format: "%.8f", eth) }
        return String(format: "%.6f", eth)
    }

    var decoded: String? {
        guard let dataHex, dataHex.count >= 10 else { return nil }
        let selector = String(dataHex.dropFirst(2).prefix(8)).lowercased()
        switch selector {
        case "a9059cbb": return "Token transfer"
        case "095ea7b3": return isUnlimitedApproval ? "Unlimited token approval" : "Token approval"
        default:         return "Contract interaction"
        }
    }

    var isApproval: Bool {
        guard let dataHex, dataHex.count >= 10 else { return false }
        return String(dataHex.dropFirst(2).prefix(8)).lowercased() == "095ea7b3"
    }

    /// approve(spender, amount): the spender being granted the allowance — who could move the tokens.
    /// nil when the calldata isn't an approval (or is malformed/truncated).
    var approvalSpender: String? {
        guard isApproval, let dataHex, dataHex.count >= 2 + 8 + 64 else { return nil }
        let word = dataHex.dropFirst(10).prefix(64)   // first ABI word after the selector
        return "0x" + String(word.suffix(40)).lowercased()
    }

    var isUnlimitedApproval: Bool {
        guard isApproval, let dataHex else { return false }
        let amount = String(dataHex.suffix(64)).lowercased()   // approve(spender, amount): last word, all-f = unlimited
        return amount == String(repeating: "f", count: 64)
    }
}
