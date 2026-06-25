//
//  Searxly wallet crypto — known-answer tests.
//
//  Runs the real Searxly/Wallet crypto against canonical reference vectors (Anvil/MetaMask
//  addresses, EIP-712 spec digest, Trezor BIP-39 seed, EIP-2 low-S, …). Unlike the live
//  "empty wallet → insufficient funds" check, these catch a broken hash or derivation because
//  they assert exact, independently-known outputs.
//
import Foundation
import libsecp256k1

var passed = 0, failed = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got.lowercased() == want.lowercased() { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)\n       got:  \(got)\n       want: \(want)") }
}
func checkBool(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("  ✅ \(name)") } else { failed += 1; print("  ❌ \(name)") }
}
func hx(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

func recoverAddress(digest: Data, sig65 hexSig: String) -> String? {
    var s = hexSig; if s.hasPrefix("0x") { s.removeFirst(2) }
    var bytes = [UInt8](); var i = s.startIndex
    while i < s.endIndex { let n = s.index(i, offsetBy: 2); bytes.append(UInt8(s[i..<n], radix: 16)!); i = n }
    guard bytes.count == 65 else { return nil }
    let recid = Int32(bytes[64] >= 27 ? bytes[64] - 27 : bytes[64])
    guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY)) else { return nil }
    defer { secp256k1_context_destroy(ctx) }
    var rsig = secp256k1_ecdsa_recoverable_signature()
    guard secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &rsig, Array(bytes[0..<64]), recid) == 1 else { return nil }
    var pub = secp256k1_pubkey()
    guard secp256k1_ecdsa_recover(ctx, &pub, &rsig, [UInt8](digest)) == 1 else { return nil }
    var out = [UInt8](repeating: 0, count: 65); var outLen = 65
    secp256k1_ec_pubkey_serialize(ctx, &out, &outLen, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED))
    return "0x" + hx(Data(Keccak256.hash(Data(out[1..<65])).suffix(20)))
}

let testMnemonic = words("test test test test test test test test test test test junk")
let abandon = words("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
let testSeed = BIP39.toSeed(testMnemonic)
let priv0 = EthereumAddress.derivePrivateKey(fromSeed: testSeed, index: 0)!

// 1. Keccak-256
print("\n[1] Keccak-256")
check("keccak(\"\")", hx(Keccak256.hash(Data())), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
check("keccak(\"abc\")", hx(Keccak256.hash(Data("abc".utf8))), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")

// 2. RLP
print("\n[2] RLP")
check("rlp(\"dog\")", hx(RLP.encode(.bytes(Data("dog".utf8)))), "83646f67")
check("rlp([cat,dog])", hx(RLP.encode(.list([.bytes(Data("cat".utf8)), .bytes(Data("dog".utf8))]))), "c88363617483646f67")
check("rlp(int 1024)", hx(RLP.encode(RLP.int(1024))), "820400")
check("rlp(int 0)", hx(RLP.encode(RLP.int(0))), "80")

// 3. WeiConverter
print("\n[3] WeiConverter")
check("1.5 ETH 18dp", WeiConverter.baseUnitDecimalString(amount: Decimal(string: "1.5")!, decimals: 18), "1500000000000000000")
check("0.000001 USDC 6dp", WeiConverter.baseUnitDecimalString(amount: Decimal(string: "0.000001")!, decimals: 6), "1")

// 4. BIP-39 seed + checksum validation
print("\n[4] BIP-39")
check("toSeed(abandon,TREZOR)", hx(BIP39.toSeed(abandon, passphrase: "TREZOR")),
      "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
checkBool("isValid(test…junk)", BIP39.isValid(testMnemonic))
checkBool("12×abandon → invalid checksum", !BIP39.isValid(words("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon")))
checkBool("validate(12×abandon)==.badChecksum", BIP39.validate(words("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon")) == .badChecksum)
checkBool("unknown word detected", BIP39.validate(words("test test test test test test test test test test test zzzz")) == .unknownWord("zzzz"))
checkBool("generateMnemonic passes checksum", BIP39.isValid(BIP39.generateMnemonic()))

// 5. HD derivation (the gold test)
print("\n[5] HD address derivation m/44'/60'/0'/0/i")
check("idx0 Anvil#0", EthereumAddress.derive(fromSeed: testSeed, index: 0) ?? "nil", "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
check("idx1 Anvil#1", EthereumAddress.derive(fromSeed: testSeed, index: 1) ?? "nil", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
check("idx2 Anvil#2", EthereumAddress.derive(fromSeed: testSeed, index: 2) ?? "nil", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")
check("abandon idx0 (MetaMask)", EthereumAddress.derive(fromSeed: BIP39.toSeed(abandon), index: 0) ?? "nil", "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")

// 6. Imported private key → address (Anvil #0 raw key)
print("\n[6] Import private key → address")
let anvil0Key = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
var keyBytes = [UInt8](); var ki = anvil0Key.startIndex
while ki < anvil0Key.endIndex { let n = anvil0Key.index(ki, offsetBy: 2); keyBytes.append(UInt8(anvil0Key[ki..<n], radix: 16)!); ki = n }
check("address(fromPrivateKey: anvil#0)", EthereumAddress.address(fromPrivateKey: Data(keyBytes)) ?? "nil",
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

// 7. personal_sign recover
print("\n[7] personal_sign (EIP-191)")
let psig = EthereumMessageSigner.personalSign(message: "Hello Searxly", privateKey: priv0)!
check("recover==Anvil#0", recoverAddress(digest: EthereumMessageSigner.personalSignDigest(message: "Hello Searxly"), sig65: psig) ?? "nil",
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

// 8. EIP-712 canonical Mail digest + recover
print("\n[8] EIP-712 typed data")
let mailJSON = """
{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Person":[{"name":"name","type":"string"},{"name":"wallet","type":"address"}],"Mail":[{"name":"from","type":"Person"},{"name":"to","type":"Person"},{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Ether Mail","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},"message":{"from":{"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},"to":{"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},"contents":"Hello, Bob!"}}
"""
let mailObj = try! JSONSerialization.jsonObject(with: Data(mailJSON.utf8)) as! [String: Any]
let mailDigest = EthereumMessageSigner.typedDataDigest(mailObj)!
check("Mail digest", hx(mailDigest), "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
check("recover typed==Anvil#0", recoverAddress(digest: mailDigest, sig65: EthereumMessageSigner.signTypedDataV4(json: mailJSON, privateKey: priv0)!) ?? "nil",
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

// 9. EIP-1559 tx — sign, recover, low-S
print("\n[9] EIP-1559 transaction")
let tx = EthereumTransaction(chainId: 8453, nonce: 0, maxPriorityFeePerGas: 1_000_000_000,
    maxFeePerGas: 30_000_000_000, gasLimit: 21000, to: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    valueWei: WeiConverter.baseUnitBytes(amount: Decimal(string: "0.01")!, decimals: 18), data: Data())
let raw = tx.signedRawTransaction(privateKey: priv0)!
checkBool("raw is 0x02-typed", raw.hasPrefix("0x02"))
let unsigned: [RLP.Item] = [RLP.int(8453), RLP.int(0), RLP.int(1_000_000_000), RLP.int(30_000_000_000), RLP.int(21000),
    RLP.hex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
    RLP.bigInt(WeiConverter.baseUnitBytes(amount: Decimal(string: "0.01")!, decimals: 18)), .bytes(Data()), .list([])]
var pre = Data([0x02]); pre.append(RLP.encode(.list(unsigned)))
let sighash = Keccak256.hash(pre)
let sg = EthereumSigner.sign(hash32: sighash, privateKey: priv0)!
check("recover tx==Anvil#0", recoverAddress(digest: sighash, sig65: "0x" + hx(sg.r) + hx(sg.s) + String(format: "%02x", sg.recid + 27)) ?? "nil",
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
let halfN: [UInt8] = [0x7f,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x5d,0x57,0x6e,0x73,0x57,0xa4,0x50,0x1d,0xdf,0xe9,0x2f,0x46,0x68,0x1b,0x20,0xa0]
var lowS = false
for i in 0..<32 { if sg.s[i] != halfN[i] { lowS = sg.s[i] < halfN[i]; break } }
checkBool("low-S (EIP-2)", lowS)

// 10. AddressValidator
print("\n[10] AddressValidator")
func vs(_ r: AddressValidator.Result) -> String { switch r { case .ok: return "ok"; case .info: return "info"; case .warning: return "warning"; case .invalid: return "invalid" } }
func v(_ a: String) -> AddressValidator.Result { AddressValidator.validate(a, selfAddress: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", knownTokenContracts: ["0xab1234567890abcdef1234567890abcdef123456"]) }
check("valid checksummed→ok", vs(v("0x70997970C51812dc3A010C7d01b50e0d17dc79C8")), "ok")
check("EIP-55 typo→invalid", vs(v("0x70997970C51812Dc3A010C7d01b50e0d17dc79C8")), "invalid")
check("burn→invalid", vs(v("0x0000000000000000000000000000000000000000")), "invalid")
check("Bitcoin→invalid", vs(v("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")), "invalid")
check("token-contract→warning", vs(v("0xab1234567890abcdef1234567890abcdef123456")), "warning")

// 11. PhishingGuard
print("\n[11] WalletPhishingGuard")
func ps(_ r: WalletPhishingGuard.Risk) -> String { if case .flagged = r { return "flagged" }; return "ok" }
check("blocklist→flagged", ps(WalletPhishingGuard.check(origin: "https://searxly-airdrop.com")), "flagged")
check("punycode→flagged", ps(WalletPhishingGuard.check(origin: "https://xn--80ak6aa92e.com")), "flagged")
check("legit→ok", ps(WalletPhishingGuard.check(origin: "https://app.uniswap.org")), "ok")

// 12. Address-poisoning detection
print("\n[12] Address-poisoning look-alikes")
let realRecipient = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"   // an address you've actually sent to
func vp(_ a: String) -> AddressValidator.Result {
    AddressValidator.validate(a, selfAddress: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                              knownTokenContracts: [], knownRecipients: [realRecipient])
}
// same first-4 (7099) and last-4 (79c8) as the real one, different middle → poisoning warning
check("look-alike (same ends)→warning", vs(vp("0x7099aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa79c8")), "warning")
// the genuine address you used → ok (not flagged)
check("exact known recipient→ok", vs(vp("0x70997970C51812dc3A010C7d01b50e0d17dc79C8")), "ok")
// an unrelated address sharing neither end → ok
check("unrelated address→ok", vs(vp("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")), "ok")

// 13. Ledger hardware-wallet protocol core
print("\n[13] Ledger protocol (path / APDU / HID framing)")
// BIP-32 path → Ledger encoding (count + 4 BE bytes/level, hardened high bit)
check("path m/44'/60'/0'/0/0", hx(try! LedgerPath.encode("m/44'/60'/0'/0/0")),
      "058000002c8000003c800000000000000000000000")
// GET_ADDRESS APDU: e0 02 00 00 Lc <path>
check("GET_ADDRESS apdu", hx(try! LedgerAPDU.getAddress(path: "m/44'/60'/0'/0/0")),
      "e002000015058000002c8000003c800000000000000000000000")
// parse a crafted GET_ADDRESS response → 0x address
var addrResp = Data([65]); addrResp.append(Data(repeating: 0, count: 65))
addrResp.append(Data([40])); addrResp.append(Data("f39fd6e51aad88f6f4ce6ab8827279cfffb92266".utf8))
check("parseAddress", (try? LedgerAPDU.parseAddress(addrResp)) ?? "nil",
      "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
// parse a crafted signature response (v ‖ r ‖ s) → 65-byte r‖s‖v
var sigResp = Data([0x1c]); sigResp.append(Data(repeating: 0x11, count: 32)); sigResp.append(Data(repeating: 0x22, count: 32))
check("parseSignature", (try? LedgerAPDU.parseSignature(sigResp)) ?? "nil",
      "0x" + String(repeating: "11", count: 32) + String(repeating: "22", count: 32) + "1c")
// HID framing: a 26-byte APDU → one 64-byte packet with the right header (chan 0101, tag 05, seq 0, len 001a)
let apdu = try! LedgerAPDU.getAddress(path: "m/44'/60'/0'/0/0")   // 26 bytes
let frames = LedgerHID.frame(apdu)
checkBool("frame → single 64B packet", frames.count == 1 && frames[0].count == 64)
check("frame header", hx(frames[0].prefix(7)), "0101050000001a")
// round-trip a multi-packet APDU through frame/unframe
let big = Data((0..<100).map { UInt8($0) })
let rt = (try? LedgerHID.unframe(LedgerHID.frame(big))) ?? Data()
checkBool("frame→unframe round-trip (2 packets)", LedgerHID.frame(big).count == 2 && rt == big)
// status word split
let (body, sw) = (try? LedgerHID.splitStatus(Data([0xab, 0xcd, 0x90, 0x00]))) ?? (Data(), 0)
checkBool("splitStatus 0x9000", sw == 0x9000 && [UInt8](body) == [0xab, 0xcd])

// 14. Encrypted backup (export → restore round-trip + wrong-password rejection)
print("\n[14] WalletBackup (encrypted seed export/restore)")
let backupPhrase = words("legal winner thank year wave sausage worth useful legal winner thank yellow")
checkBool("backup phrase is valid BIP-39", BIP39.isValid(backupPhrase))
if let blob = WalletBackup.export(words: backupPhrase, password: "correct horse battery") {
    checkBool("restore with right password == original", WalletBackup.restore(fileData: blob, password: "correct horse battery") == backupPhrase)
    checkBool("restore with WRONG password → nil", WalletBackup.restore(fileData: blob, password: "wrong password") == nil)
    checkBool("restore of tampered blob → nil", WalletBackup.restore(fileData: blob + Data([0x00]), password: "correct horse battery") == nil)
    checkBool("two exports use different salts (ciphertext differs)", WalletBackup.export(words: backupPhrase, password: "correct horse battery") != blob)
} else {
    failed += 1; print("  ❌ backup export returned nil")
}

print("\n────────────────────────────────────────")
print("  RESULT: \(passed) passed, \(failed) failed")
print("────────────────────────────────────────")
exit(failed == 0 ? 0 : 1)
