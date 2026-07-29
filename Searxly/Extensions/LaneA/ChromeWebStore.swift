//
//  ChromeWebStore.swift
//  Searxly
//
//  Direct Chrome Web Store installs — the v1 distribution model for Lane A (decided 2026-07-18, replacing
//  the curated signed catalog). The user pastes a store link (or taps a Popular card); Searxly downloads
//  the `.crx` straight from Google's public packaging endpoint on-device (nothing is redistributed by us),
//  verifies the CRX3 container the same way Chrome does, and hands the embedded ZIP to `WKWebExtension`.
//
//  Verification model (Chrome's "developer proof"): a CRX3 header carries signatures over the package.
//  The extension's ID *is* the first 16 bytes of SHA-256 of the developer's public key. We require a
//  signature that (a) validates over the payload and (b) comes from the key whose hash matches the ID —
//  so a tampered or substituted package can't claim another extension's identity. No trust in the
//  transport beyond that (HTTPS is belt-and-braces, not the authenticity mechanism).
//
//  The parser eats untrusted bytes: every read is bounds-checked, sizes are capped, unknown fields are
//  skipped structurally. Pure Foundation + CryptoKit + Security — no app types — so it can be exercised
//  standalone.
//

import Foundation
import CryptoKit
import Security

// MARK: - Store client

enum ChromeWebStore {
    /// Chrome version presented to the packaging endpoint — it refuses extensions whose
    /// `minimum_chrome_version` is above this. Keep it a plausibly-current stable.
    static let prodVersion = "140.0.0.0"

    /// Hard cap on an accepted package (the biggest mainstream extensions are ~30 MB).
    static let maxPackageBytes = 200 * 1024 * 1024

    static let storeHomeURL = URL(string: "https://chromewebstore.google.com")!

    /// Extracts a Chrome extension ID from user input: a bare 32-character ID or any store URL
    /// (current `chromewebstore.google.com/detail/<slug>/<id>` or legacy
    /// `chrome.google.com/webstore/detail/<slug>/<id>`). IDs use only the letters a–p (they're
    /// hex-of-SHA-256 mapped onto 'a'…'p'), which makes the token unambiguous — we take the last
    /// match so a same-alphabet slug can't shadow the trailing ID component.
    static func extensionID(from input: String) -> String? {
        let lowered = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty, lowered.count < 2048 else { return nil }
        var last: String?
        var search = lowered.startIndex..<lowered.endIndex
        while let r = lowered.range(of: "[a-p]{32}", options: .regularExpression, range: search) {
            // Reject if embedded in a longer a-p run (then it isn't a 32-char token).
            let beforeOK = r.lowerBound == lowered.startIndex || !("a"..."p").contains(lowered[lowered.index(before: r.lowerBound)])
            let afterOK = r.upperBound == lowered.endIndex || !("a"..."p").contains(lowered[r.upperBound])
            if beforeOK && afterOK { last = String(lowered[r]) }
            search = r.upperBound..<lowered.endIndex
        }
        return last
    }

    /// The two hosts Google has ever served the store from. Everything that changes browser behavior
    /// around the store (the toolbar chip, the UA override, the page bridge) keys off this exact set.
    static func isStoreHostName(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "chromewebstore.google.com" || host == "chrome.google.com"
    }

    static func isStoreURL(_ url: URL?) -> Bool { isStoreHostName(url?.host) }

    /// The extension ID when `url` is a Chrome Web Store extension *detail* page — the page where
    /// Chrome shows "Add to Chrome". Host-restricted (current + legacy store hosts only) so the
    /// in-browser install button can never be conjured up by an arbitrary site.
    static func detailPageExtensionID(of url: URL?) -> String? {
        guard let url, isStoreHostName(url.host), url.path.contains("/detail/") else { return nil }
        return extensionID(from: url.path)
    }

    /// Chrome's desktop-macOS UA (the OS token is frozen at 10_15_7 by Chrome itself), presented ONLY
    /// on the store hosts: Google's server-side browser sniff otherwise pushes "switch to Chrome"
    /// banners and serves the install button in a disabled state. Version matches `prodVersion`.
    static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/\(prodVersion) Safari/537.36"

    /// Isolated content world for the store page bridge — page JS can't see the world, so it can't
    /// reach the bridge's native message handler.
    static let storeBridgeWorldName = "SearxlyStoreBridge"
    static let storeBridgeHandlerName = "searxlyStoreInstall"

    /// Injected on standard tabs (main frame only), early-returns off the store hosts. Runs in the
    /// isolated `SearxlyStoreBridge` world. Three jobs:
    /// 1. Show an in-page popup card on extension detail pages — Searxly-branded, with the actual
    ///    "Add to Searxly" button. Clicking it posts to the native handler (→ download + verify +
    ///    native permission prompt). This is the primary, most discoverable install affordance.
    /// 2. Reflect install progress: the native side calls `window.__searxlyStorePopup.setState(...)`
    ///    (via `popupStateJS`) as the flow advances (installing → installed / error).
    /// 3. Also intercept clicks on the store's own "Add to Chrome" button (active because of the UA
    ///    override) and relabel it to Searxly — a bonus path for users who click the page's button.
    /// The message body carries nothing actionable: the native side re-derives the extension ID from
    /// the tab URL, so a forged message could at most surface the (native, cancelable) permission prompt.
    static let storeBridgeScript = """
    (function () {
      'use strict';
      var host = location.hostname;
      if (host !== 'chromewebstore.google.com' && host !== 'chrome.google.com') { return; }

      var CARD_ID = '__searxly_store_popup';
      var state = 'idle';       // idle | installing | installed | error
      var errorDetail = '';
      var currentId = null;
      var dismissed = {};

      function currentExtId() {
        var m = location.pathname.match(/[a-p]{32}/g);
        return m ? m[m.length - 1] : null;
      }
      function onDetailPage() {
        return location.pathname.indexOf('/detail/') !== -1 && !!currentExtId();
      }
      function removeCard() {
        var el = document.getElementById(CARD_ID);
        if (el) { el.remove(); }
      }

      function render() {
        var el = document.getElementById(CARD_ID);
        if (!el) { return; }
        var title, sub, cta, disabled = false, ctaBg = '#ffffff', ctaColor = '#111111';
        if (state === 'installing') {
          title = 'Adding to Searxly'; sub = 'Downloading and verifying the extension...';
          cta = 'Installing...'; disabled = true; ctaBg = '#3a3b3e'; ctaColor = '#ffffff';
        } else if (state === 'installed') {
          title = 'Added to Searxly'; sub = 'It is ready. Open a new tab to start using it.';
          cta = 'Added'; disabled = true; ctaBg = '#1f7a3d'; ctaColor = '#ffffff';
        } else if (state === 'error') {
          title = 'Could not add it'; sub = errorDetail || 'Something went wrong. Please try again.';
          cta = 'Try again';
        } else {
          title = 'Install with Searxly'; sub = 'Add this extension to your Searxly browser.';
          cta = 'Add to Searxly';
        }
        el.innerHTML =
          '<div style="display:flex;align-items:center;gap:13px;background:#17181A;color:#fff;'
          + 'padding:13px 15px;border-radius:16px;box-shadow:0 14px 44px rgba(0,0,0,.5);'
          + 'border:1px solid rgba(255,255,255,.09);min-width:330px;max-width:min(520px,calc(100vw - 32px))">'
          + '<div style="font-weight:800;font-size:12.5px;letter-spacing:.3px;padding:6px 9px;'
          + 'background:#fff;color:#111;border-radius:8px;flex:none">Searxly</div>'
          + '<div style="flex:1 1 auto;min-width:0">'
          + '<div style="font-weight:700;font-size:14px;line-height:1.25">' + title + '</div>'
          + '<div style="font-size:12px;color:#A9ACB2;margin-top:2px;line-height:1.3">' + sub + '</div>'
          + '</div>'
          + '<button data-role="cta"' + (disabled ? ' disabled' : '')
          + ' style="flex:none;border:0;cursor:' + (disabled ? 'default' : 'pointer')
          + ';font-weight:700;font-size:13px;padding:9px 15px;border-radius:10px;background:'
          + ctaBg + ';color:' + ctaColor + '">' + cta + '</button>'
          + '<button data-role="close" aria-label="Dismiss" style="flex:none;border:0;'
          + 'background:transparent;color:#8A8D93;cursor:pointer;font-size:18px;line-height:1;'
          + 'padding:4px 4px">&times;</button>';

        var ctaBtn = el.querySelector('[data-role=cta]');
        if (ctaBtn && !disabled) {
          ctaBtn.addEventListener('click', function (e) {
            e.preventDefault();
            state = 'installing'; render();
            try { window.webkit.messageHandlers.searxlyStoreInstall.postMessage({}); } catch (err) {}
          });
        }
        var closeBtn = el.querySelector('[data-role=close]');
        if (closeBtn) {
          closeBtn.addEventListener('click', function () {
            if (currentId) { dismissed[currentId] = true; }
            removeCard();
          });
        }
      }

      function createCard() {
        if (document.getElementById(CARD_ID)) { return; }
        if (!(document.body || document.documentElement)) { return; }
        var el = document.createElement('div');
        el.id = CARD_ID;
        el.setAttribute('dir', 'ltr');
        el.style.cssText = 'position:fixed;left:50%;bottom:24px;'
          + 'transform:translateX(-50%) translateY(14px);z-index:2147483647;opacity:0;'
          + 'transition:opacity .24s ease, transform .24s ease;'
          + 'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif';
        (document.body || document.documentElement).appendChild(el);
        render();
        requestAnimationFrame(function () {
          el.style.opacity = '1';
          el.style.transform = 'translateX(-50%) translateY(0)';
        });
      }

      // Native → page channel (called via evaluateJavaScript in this same world).
      window.__searxlyStorePopup = {
        setState: function (s, detail) {
          state = s;
          errorDetail = detail || '';
          if (onDetailPage() && !dismissed[currentId] && !document.getElementById(CARD_ID)) {
            createCard();
          }
          render();
          if (s === 'installed') { setTimeout(removeCard, 4500); }
        }
      };

      function tick() {
        if (!onDetailPage()) { removeCard(); currentId = null; return; }
        var id = currentExtId();
        if (id !== currentId) { currentId = id; state = 'idle'; errorDetail = ''; }
        if (dismissed[id]) { removeCard(); return; }
        if (!document.getElementById(CARD_ID)) { createCard(); }
      }
      setInterval(tick, 700);
      tick();

      // Bonus: also route clicks on the store's own install button and relabel Chrome -> Searxly.
      function isAddButton(text) {
        var t = (text || '').trim().toLowerCase();
        return t.length > 0 && t.length < 60
          && /(chrome|searxly)/.test(t)
          && /(add|ajouter|hinzuf|adir|agregar|instal)/.test(t);
      }
      document.addEventListener('click', function (e) {
        if (location.pathname.indexOf('/detail/') === -1) { return; }
        var el = e.target instanceof Element ? e.target.closest('button') : null;
        if (!el || el.closest('#' + CARD_ID) || !isAddButton(el.textContent)) { return; }
        e.preventDefault();
        e.stopImmediatePropagation();
        state = 'installing'; render();
        try { window.webkit.messageHandlers.searxlyStoreInstall.postMessage({}); } catch (err) {}
      }, true);

      var scheduled = false;
      function relabel() {
        scheduled = false;
        var buttons = document.querySelectorAll('button');
        for (var i = 0; i < buttons.length; i++) {
          if (buttons[i].closest('#' + CARD_ID) || !isAddButton(buttons[i].textContent)) { continue; }
          var walker = document.createTreeWalker(buttons[i], NodeFilter.SHOW_TEXT);
          var node;
          while ((node = walker.nextNode())) {
            if (/chrome/i.test(node.nodeValue)) {
              node.nodeValue = node.nodeValue.replace(/chrome/ig, 'Searxly');
            }
          }
        }
      }
      function arm() {
        try {
          new MutationObserver(function () {
            if (scheduled) { return; }
            scheduled = true;
            requestAnimationFrame(relabel);
          }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
        } catch (err) {}
        relabel();
      }
      if (document.documentElement) { arm(); }
      else { document.addEventListener('DOMContentLoaded', arm, { once: true }); }
    })();
    """

    /// JS to push an install-flow state into the in-page popup (evaluated in the bridge's content
    /// world). `state` is one of idle / installing / installed / error; `detail` is an optional error
    /// message. Both are hard-coded or app-derived — never page-derived — so this is injection-safe.
    static func popupStateJS(_ state: String, detail: String = "") -> String {
        let safe = detail
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return "window.__searxlyStorePopup && window.__searxlyStorePopup.setState('\(state)', '\(safe)')"
    }

    /// Google's public CRX packaging endpoint — the same one every Chromium-based browser hits for
    /// installs and updates. The ID is validated `[a-p]{32}`, so interpolation is injection-safe.
    static func downloadURL(for id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect"
            + "&prodversion=\(prodVersion)&acceptformat=crx3&x=id%3D\(id)%26uc")!
    }

    /// Downloads the `.crx` for an extension ID. Ephemeral session: no cookies, no cache.
    static func download(id: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: downloadURL(for: id))
        guard let http = response as? HTTPURLResponse else { throw ChromeWebStoreError.downloadFailed }
        // The endpoint answers 204 (empty) for unknown / unpublished / platform-restricted extensions.
        guard http.statusCode != 204, !data.isEmpty else { throw ChromeWebStoreError.notAvailable }
        guard http.statusCode == 200 else { throw ChromeWebStoreError.serverError(http.statusCode) }
        guard data.count <= maxPackageBytes else { throw ChromeWebStoreError.tooLarge }
        return data
    }
}

extension Notification.Name {
    /// Posted (by the store page bridge's native handler) when the user clicks the store's own install
    /// button; the toolbar chip on the active tab picks it up and runs the normal install flow.
    static let chromeWebStoreInstallClicked = Notification.Name("Searxly.ChromeWebStoreInstallClicked")
}

enum ChromeWebStoreError: LocalizedError {
    case invalidInput
    case notAvailable
    case serverError(Int)
    case tooLarge
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "That doesn't look like a Chrome Web Store link or extension ID."
        case .notAvailable: return "The Chrome Web Store has no downloadable package for this extension (it may be unpublished or restricted)."
        case .serverError(let code): return "The Chrome Web Store returned an error (\(code))."
        case .tooLarge: return "The extension package is too large."
        case .downloadFailed: return "Couldn't download the extension."
        }
    }
}

// MARK: - Staged install (the "Add to Searxly" flow)

/// A downloaded, signature-verified store package staged on disk, plus the metadata the permission
/// prompt shows. Produced by `ExtensionManager.fetchFromChromeWebStore`; the user's answer decides
/// between `confirmStoreInstall` and `cancelStoreInstall`. 15.0-safe (no WebKit types) so toolbar UI
/// can hold one without availability gymnastics.
struct PendingStoreInstall {
    let id: String
    let displayName: String
    let requestedPermissions: [String]
    let requestedHosts: [String]
    let stagedPackage: URL
}

// MARK: - CRX3 container

/// A parsed, signature-verified CRX3 package.
struct CRX3Package {
    /// The extension ID derived from the verified signing key (32 chars, a–p).
    let extensionID: String
    /// The embedded WebExtension ZIP — a valid `WKWebExtension` resourceBaseURL payload.
    let zipData: Data
}

enum CRX3 {
    /// Parses and verifies a CRX3 file. Throws unless at least one signature both validates over the
    /// payload and comes from the key whose SHA-256 prefix equals the package's declared ID. When
    /// `expectedID` is given (the ID the user asked to install), it must match the verified ID too.
    static func parse(_ data: Data, expectedID: String? = nil) throws -> CRX3Package {
        // Fixed header: "Cr24" | version(LE32) | headerLen(LE32)
        guard data.count > 12 else { throw CRX3Error.notCRX }
        let fixed = [UInt8](data.prefix(12))
        guard fixed[0...3] == [0x43, 0x72, 0x32, 0x34] else { throw CRX3Error.notCRX }   // "Cr24"
        let version = le32(fixed, 4)
        guard version == 3 else { throw CRX3Error.unsupportedVersion(version) }
        let headerLen = Int(le32(fixed, 8))
        guard headerLen > 0, headerLen <= 1_000_000, data.count > 12 + headerLen else {
            throw CRX3Error.malformedHeader
        }
        let header = [UInt8](data.subdata(in: 12..<(12 + headerLen)))
        let payload = data.subdata(in: (12 + headerLen)..<data.count)
        guard payload.count >= 2, payload[payload.startIndex] == 0x50, payload[payload.startIndex + 1] == 0x4B else {
            throw CRX3Error.notZip   // "PK"
        }

        // CrxFileHeader proto: 2 = sha256_with_rsa proof, 3 = sha256_with_ecdsa proof, 10000 = signed_header_data
        var proofs: [(publicKey: [UInt8], signature: [UInt8], isECDSA: Bool)] = []
        var signedHeaderData: [UInt8]?
        var reader = ProtoReader(header)
        while !reader.atEnd {
            let key = try reader.varint()
            let (field, wire) = (key >> 3, key & 7)
            switch (field, wire) {
            case (2, 2), (3, 2):
                var proof = ProtoReader(try reader.bytesField())
                var publicKey: [UInt8] = []
                var signature: [UInt8] = []
                while !proof.atEnd {
                    let k = try proof.varint()
                    switch (k >> 3, k & 7) {
                    case (1, 2): publicKey = try proof.bytesField()
                    case (2, 2): signature = try proof.bytesField()
                    default: try proof.skip(wireType: k & 7)
                    }
                }
                if !publicKey.isEmpty && !signature.isEmpty {
                    proofs.append((publicKey, signature, field == 3))
                }
            case (10000, 2):
                signedHeaderData = try reader.bytesField()
            default:
                try reader.skip(wireType: wire)
            }
        }

        // SignedData proto: 1 = crx_id (16 bytes)
        guard let shd = signedHeaderData else { throw CRX3Error.missingSignedHeader }
        var signedData = ProtoReader(shd)
        var crxID: [UInt8]?
        while !signedData.atEnd {
            let k = try signedData.varint()
            if k >> 3 == 1 && k & 7 == 2 { crxID = try signedData.bytesField() }
            else { try signedData.skip(wireType: k & 7) }
        }
        guard let crxID, crxID.count == 16 else { throw CRX3Error.missingSignedHeader }

        // Signed message: "CRX3 SignedData\0" | len(signed_header_data) LE32 | signed_header_data | zip
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var lenLE = UInt32(shd.count).littleEndian
        withUnsafeBytes(of: &lenLE) { message.append(contentsOf: $0) }
        message.append(contentsOf: shd)
        message.append(payload)

        // Require the DEVELOPER proof: key-hash prefix == crx_id, and its signature validates.
        let verified = proofs.contains { proof in
            let keyHash = [UInt8](SHA256.hash(data: Data(proof.publicKey)))
            guard Array(keyHash.prefix(16)) == crxID else { return false }
            return verifySignature(proof.signature, publicKeySPKI: proof.publicKey,
                                   isECDSA: proof.isECDSA, message: message)
        }
        guard verified else { throw CRX3Error.signatureInvalid }

        let actualID = idString(from: crxID)
        if let expectedID, expectedID != actualID {
            throw CRX3Error.idMismatch(expected: expectedID, actual: actualID)
        }
        return CRX3Package(extensionID: actualID, zipData: payload)
    }

    /// Chrome's ID alphabet: each nibble of the 16-byte key hash → 'a' + nibble.
    static func idString(from crxID: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        for byte in crxID {
            out.append(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4)))
            out.append(UnicodeScalar(UInt8(ascii: "a") + (byte & 0x0F)))
        }
        return String(out)
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    // MARK: Signature verification

    private static func verifySignature(_ signature: [UInt8], publicKeySPKI: [UInt8],
                                        isECDSA: Bool, message: Data) -> Bool {
        guard let inner = try? spkiInnerKey(publicKeySPKI) else { return false }
        if isECDSA {
            // P-256 point (04 || X || Y) + DER-encoded ECDSA signature, over SHA-256 of the message.
            guard !inner.isRSA,
                  let key = try? P256.Signing.PublicKey(x963Representation: Data(inner.key)),
                  let sig = try? P256.Signing.ECDSASignature(derRepresentation: Data(signature))
            else { return false }
            return key.isValidSignature(sig, for: SHA256.hash(data: message))
        } else {
            // RSA PKCS#1 v1.5 with SHA-256. SecKey wants the PKCS#1 body, not the SPKI wrapper.
            guard inner.isRSA else { return false }
            let attrs: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
            ]
            guard let key = SecKeyCreateWithData(Data(inner.key) as CFData, attrs as CFDictionary, nil) else {
                return false
            }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                         message as CFData, Data(signature) as CFData, nil)
        }
    }

    /// Minimal DER walk of a SubjectPublicKeyInfo: SEQUENCE { SEQUENCE { OID, … }, BIT STRING { key } }.
    /// Returns the BIT STRING body (PKCS#1 for RSA, X9.63 point for EC) plus which family the OID names.
    private static func spkiInnerKey(_ spki: [UInt8]) throws -> (isRSA: Bool, key: [UInt8]) {
        let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]   // 1.2.840.113549.1.1.1
        let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]                // 1.2.840.10045.2.1

        var outer = DERReader(spki)
        let spkiSeq = try outer.readTLV()
        guard spkiSeq.tag == 0x30 else { throw CRX3Error.malformedHeader }

        var seq = DERReader(spkiSeq.content)
        let algorithm = try seq.readTLV()
        guard algorithm.tag == 0x30 else { throw CRX3Error.malformedHeader }
        var alg = DERReader(algorithm.content)
        let oid = try alg.readTLV()
        guard oid.tag == 0x06 else { throw CRX3Error.malformedHeader }
        let isRSA: Bool
        switch oid.content {
        case rsaOID: isRSA = true
        case ecOID: isRSA = false
        default: throw CRX3Error.malformedHeader
        }

        let bitString = try seq.readTLV()
        guard bitString.tag == 0x03, bitString.content.first == 0x00 else { throw CRX3Error.malformedHeader }
        return (isRSA, Array(bitString.content.dropFirst()))
    }
}

enum CRX3Error: LocalizedError {
    case notCRX
    case unsupportedVersion(UInt32)
    case malformedHeader
    case missingSignedHeader
    case notZip
    case signatureInvalid
    case idMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .notCRX: return "The download isn't a Chrome extension package."
        case .unsupportedVersion(let v): return "Unsupported extension package version (\(v))."
        case .malformedHeader, .missingSignedHeader: return "The extension package is malformed."
        case .notZip: return "The extension package has no readable contents."
        case .signatureInvalid: return "The extension's signature couldn't be verified."
        case .idMismatch(let expected, let actual):
            return "The downloaded extension (\(actual)) doesn't match the one requested (\(expected))."
        }
    }
}

// MARK: - Untrusted-bytes readers

/// Bounds-checked protobuf wire-format reader (varints + length-delimited fields only, which is all a
/// CRX3 header uses; other wire types are skipped structurally).
private struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index >= bytes.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw CRX3Error.malformedHeader }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func bytesField() throws -> [UInt8] {
        let length = try varint()
        guard length <= UInt64(bytes.count - index) else { throw CRX3Error.malformedHeader }
        defer { index += Int(length) }
        return Array(bytes[index..<(index + Int(length))])
    }

    mutating func skip(wireType: UInt64) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1: try advance(8)
        case 2: _ = try bytesField()
        case 5: try advance(4)
        default: throw CRX3Error.malformedHeader
        }
    }

    private mutating func advance(_ n: Int) throws {
        guard bytes.count - index >= n else { throw CRX3Error.malformedHeader }
        index += n
    }
}

/// Bounds-checked DER TLV reader (short + long-form lengths).
private struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readTLV() throws -> (tag: UInt8, content: [UInt8]) {
        guard index + 2 <= bytes.count else { throw CRX3Error.malformedHeader }
        let tag = bytes[index]
        index += 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, index + count <= bytes.count else { throw CRX3Error.malformedHeader }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length >= 0, bytes.count - index >= length else { throw CRX3Error.malformedHeader }
        defer { index += length }
        return (tag, Array(bytes[index..<(index + length)]))
    }
}
