//
//  TorUpdateChecker.swift
//  Searxly
//
//  Tor-routed software updates for when Maximum Privacy has native egress closed. Sparkle's own
//  appcast fetch + download ride a plain URLSession from the real IP (see SoftwareUpdater), so in
//  Maximum + Tor they are suspended — which would otherwise leave Searxly Maximum permanently
//  un-updatable, the worst failure mode for a hardened browser. This checker closes that hole:
//
//    • It fetches the SAME signed appcast (`SUFeedURL`) but over the fail-closed `TorLane`, so the
//      request resolves + exits through Tor (SOCKS5h, no DNS leak) — the update server sees a Tor
//      exit, never the user's real IP. If Tor isn't up, it fails closed (never falls back to clearnet).
//    • It downloads the update over that same Tor lane and verifies the download INDEPENDENTLY with
//      CryptoKit against the bundled `SUPublicEDKey`. Sparkle's `edSignature` is a standard Ed25519
//      detached signature over the raw file bytes, so we don't need Sparkle's internal verifier — a
//      tampered or MITM'd download is rejected exactly as Sparkle would reject it.
//    • The verified installer is staged inside the app container and revealed/opened for the user to
//      install. We never claim to have auto-installed; the user completes the drag, same as any DMG.
//
//  This is wired from `SoftwareUpdater.checkForUpdates()` whenever native egress is closed by Maximum
//  Privacy and Tor is the active protection (so it also covers the base app in Maximum + Tor, not just
//  the Maximum edition).
//

import AppKit
import CryptoKit
import Foundation
import Network
import os

@MainActor
@Observable
final class TorUpdateChecker {
    static let shared = TorUpdateChecker()

    /// One discovered, not-yet-downloaded update parsed from the appcast.
    struct FoundUpdate: Equatable, Sendable {
        let shortVersion: String     // e.g. "0.9.6"
        let build: String?           // CFBundleVersion / sparkle:version, when present
        let url: URL                 // the enclosure download URL
        let edSignature: String      // base64 Ed25519 detached signature over the file bytes
        let length: Int?             // expected byte length, when present
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateFound(FoundUpdate)
        case downloading(percent: Int)
        case verifying
        case readyToInstall(version: String, fileURL: URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let log = Logger(subsystem: "com.myrhex.Searxly", category: "TorUpdate")
    private var lastSilentCheck: Date?
    private var downloadCoordinator: TorDownloadCoordinator?

    private init() {}

    // MARK: - Config (read from the merged Info.plist — same values Sparkle uses)

    /// The appcast URL. Prefer an explicit `.onion` feed (`SUFeedURLOnion`) when present — it removes
    /// the Tor-exit trust and hides even *that* a Tor user fetched the feed — otherwise the standard
    /// `SUFeedURL` fetched over Tor.
    private var feedURL: URL? {
        let info = Bundle.main.infoDictionary
        // Searxly Maximum has its own release channel and must NEVER fall back to the base app's SUFeedURL
        // (installing a base update would replace Maximum with the base app). Its feed lives in the
        // Maximum-specific keys; when they're blank there is simply nothing to check.
        if Edition.isMaximum {
            if let onion = info?["SUFeedURLMaximumOnion"] as? String, !onion.isEmpty, let u = URL(string: onion) { return u }
            if let s = info?["SUFeedURLMaximum"] as? String, !s.isEmpty, let u = URL(string: s) { return u }
            return nil
        }
        if let onion = info?["SUFeedURLOnion"] as? String, !onion.isEmpty, let u = URL(string: onion) {
            return u
        }
        if let s = info?["SUFeedURL"] as? String, let u = URL(string: s) { return u }
        return nil
    }

    /// The bundled Ed25519 public key Sparkle would verify against.
    private var publicEDKey: Data? {
        guard let s = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String else { return nil }
        return Data(base64Encoded: s)
    }

    private var currentShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    private var currentBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    // MARK: - Interactive check (drives the update window)

    /// Run a fresh, user-initiated check. Updates `phase` for the update window to render.
    func check() async {
        phase = .checking
        do {
            let items = try await fetchAppcast()
            guard let newest = pickNewestNewer(items) else {
                phase = .upToDate(current: currentShortVersion)
                SoftwareUpdater.shared.setUpdate(available: false, version: nil)
                return
            }
            phase = .updateFound(newest)
            SoftwareUpdater.shared.setUpdate(available: true, version: newest.shortVersion)
        } catch let e as UpdateError {
            phase = .failed(e.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Quiet background check — lights the sidebar "Update available" badge over Tor without opening
    /// any UI. Throttled so it runs at most every 6 hours, and never while the window is mid-flight.
    func checkSilently() async {
        if case .downloading = phase { return }
        if case .verifying = phase { return }
        if let last = lastSilentCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastSilentCheck = Date()
        do {
            let items = try await fetchAppcast()
            if let newest = pickNewestNewer(items) {
                if case .idle = phase { phase = .updateFound(newest) }
                SoftwareUpdater.shared.setUpdate(available: true, version: newest.shortVersion)
                log.log("Tor update check found \(newest.shortVersion, privacy: .public)")
            }
        } catch {
            // Silent path: swallow (Tor may still be bootstrapping, or the appcast isn't published yet).
            log.log("Silent Tor update check did not complete: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Download + verify + stage

    func download(_ found: FoundUpdate) async {
        // Re-assert the fail-closed authorization right before transferring bytes: TorLane returns a
        // lane only when egress is safe (Tor verified up, or we're outside blocked Maximum). If it's
        // nil we must not download at all.
        guard let lane = await TorLane.current() else {
            phase = .failed("Tor isn’t connected yet — updates download only once Tor is up.")
            return
        }
        guard let key = publicEDKey else {
            phase = .failed("Missing update signing key (SUPublicEDKey).")
            return
        }

        phase = .downloading(percent: 0)
        let coordinator = TorDownloadCoordinator(usesTor: lane.viaTor)
        downloadCoordinator = coordinator

        let stagedFile: URL
        do {
            stagedFile = try await coordinator.download(found.url, expectedLength: found.length) { [weak self] pct in
                guard let self else { return }   // strongify once, so the Task captures an immutable `self`
                Task { @MainActor in
                    if case .downloading = self.phase { self.phase = .downloading(percent: pct) }
                }
            }
        } catch {
            phase = .failed("Download over Tor failed: \(error.localizedDescription)")
            downloadCoordinator = nil
            return
        }
        downloadCoordinator = nil

        // Verify the Ed25519 signature over the raw file bytes, off the main actor.
        phase = .verifying
        let sig = found.edSignature
        let verified: Bool = await Task.detached(priority: .userInitiated) {
            TorUpdateChecker.verifyEd25519(fileAt: stagedFile, signatureBase64: sig, publicKey: key)
        }.value

        guard verified else {
            try? FileManager.default.removeItem(at: stagedFile)
            phase = .failed("The downloaded update failed signature verification and was discarded. Nothing was installed.")
            log.error("Tor update signature verification FAILED for \(found.shortVersion, privacy: .public)")
            return
        }

        // Move the verified installer to a stable, revealable name inside the container.
        let finalURL = stageVerified(stagedFile, version: found.shortVersion)
        phase = .readyToInstall(version: found.shortVersion, fileURL: finalURL)
        log.log("Tor update \(found.shortVersion, privacy: .public) downloaded + verified")
    }

    /// Open the verified installer (mounts the DMG) and reveal it in Finder.
    func revealAndOpen(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Appcast fetch (over Tor)

    private func fetchAppcast() async throws -> [FoundUpdate] {
        guard let feed = feedURL else { throw UpdateError("No update feed is configured.") }
        guard let lane = await TorLane.current() else {
            throw UpdateError("Tor isn’t connected yet — the update check waits until Tor is up so it can’t reveal your real IP.")
        }
        var request = URLRequest(url: feed)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await lane.session.data(for: request)
        } catch {
            throw UpdateError("Couldn’t reach the update server over Tor: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            // Feed not published yet — treat as "no update", not an error.
            return []
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError("The update server returned an unexpected response (\(code)).")
        }
        return AppcastParser.parse(data)
    }

    /// From all parsed appcast items, the newest one that is strictly newer than what's installed.
    private func pickNewestNewer(_ items: [FoundUpdate]) -> FoundUpdate? {
        let newer = items.filter {
            VersionCompare.isNewer(feedShort: $0.shortVersion, feedBuild: $0.build,
                                   thanShort: currentShortVersion, thanBuild: currentBuild)
        }
        return newer.max { a, b in
            VersionCompare.isNewer(feedShort: b.shortVersion, feedBuild: b.build,
                                   thanShort: a.shortVersion, thanBuild: a.build)
        }
    }

    private func stageVerified(_ tmp: URL, version: String) -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))?
            .appendingPathComponent("Updates", isDirectory: true)
        guard let dir else { return tmp }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = tmp.pathExtension.isEmpty ? "dmg" : tmp.pathExtension
        let dest = dir.appendingPathComponent("Searxly-\(version).\(ext)")
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: tmp, to: dest); return dest }
        catch { return tmp }
    }

    // MARK: - Ed25519 verification (matches Sparkle's edSignature)

    /// Verifies a Sparkle-style Ed25519 detached signature over the raw file contents. `signatureBase64`
    /// is the appcast's `sparkle:edSignature`; `publicKey` is the raw 32-byte `SUPublicEDKey`.
    nonisolated static func verifyEd25519(fileAt url: URL, signatureBase64: String, publicKey: Data) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64),
              let fileData = try? Data(contentsOf: url, options: .mappedIfSafe),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(sig, for: fileData)
    }

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }
}

// MARK: - Version comparison (build number first, then dotted short version)

enum VersionCompare {
    static func isNewer(feedShort: String, feedBuild: String?, thanShort: String, thanBuild: String?) -> Bool {
        if let fb = feedBuild, let cb = thanBuild, let f = Int(fb), let c = Int(cb) {
            if f != c { return f > c }
            // Same build → fall through to short-version compare (defensive).
        }
        return compareDotted(feedShort, thanShort) == .orderedDescending
    }

    static func compareDotted(_ a: String, _ b: String) -> ComparisonResult {
        let ap = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let bp = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(ap.count, bp.count) {
            let x = i < ap.count ? ap[i] : 0
            let y = i < bp.count ? bp[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - Appcast XML parser (Sparkle format)

private final class AppcastParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> [TorUpdateChecker.FoundUpdate] {
        let p = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false   // keep "sparkle:" attribute prefixes intact
        parser.delegate = p
        parser.parse()
        return p.items
    }

    private(set) var items: [TorUpdateChecker.FoundUpdate] = []

    private var inItem = false
    private var itemShort: String?
    private var itemBuild: String?
    private var encURL: String?
    private var encSig: String?
    private var encBuild: String?
    private var encShort: String?
    private var encLength: Int?
    private var chars = ""
    private var currentElement = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        currentElement = elementName
        chars = ""
        switch elementName {
        case "item":
            inItem = true
            itemShort = nil; itemBuild = nil
            encURL = nil; encSig = nil; encBuild = nil; encShort = nil; encLength = nil
        case "enclosure":
            encURL = attributeDict["url"]
            encSig = attributeDict["sparkle:edSignature"] ?? attributeDict["edSignature"]
            encBuild = attributeDict["sparkle:version"] ?? attributeDict["version"]
            encShort = attributeDict["sparkle:shortVersionString"] ?? attributeDict["shortVersionString"]
            if let l = attributeDict["length"] { encLength = Int(l) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        chars += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = chars.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:shortVersionString":
            if inItem, !text.isEmpty { itemShort = text }
        case "sparkle:version":
            if inItem, !text.isEmpty { itemBuild = text }
        case "item":
            defer { inItem = false }
            guard let urlStr = encURL, let url = URL(string: urlStr), let sig = encSig, !sig.isEmpty else { return }
            let short = encShort ?? itemShort ?? (encBuild ?? itemBuild) ?? "?"
            items.append(TorUpdateChecker.FoundUpdate(
                shortVersion: short,
                build: encBuild ?? itemBuild,
                url: url,
                edSignature: sig,
                length: encLength
            ))
        default:
            break
        }
        chars = ""
    }
}

// MARK: - Tor-proxied download with progress

/// A one-shot download over the bundled Tor SOCKS proxy that reports progress. Uses its own delegated
/// session (same proxy TorLane uses) because URLSession needs a delegate for byte-level progress; the
/// authorization to transfer is still gated by TorLane.current() at the call site.
private final class TorDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let usesTor: Bool
    private var session: URLSession!
    private var progress: (@Sendable (Int) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var expectedLength: Int?

    init(usesTor: Bool) {
        self.usesTor = usesTor
        super.init()
        let config = URLSessionConfiguration.ephemeral
        if usesTor {
            config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: WebViewFactory.torSocksEndpoint())]
        }
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600   // Tor transfers are slow; allow a long tail
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, expectedLength: Int?, progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        self.progress = progress
        self.expectedLength = expectedLength
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : Int64(expectedLength ?? 0)
        guard total > 0 else { return }
        let pct = Int((Double(totalBytesWritten) / Double(total) * 100).rounded())
        progress?(min(max(pct, 0), 100))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted once this delegate returns — move it synchronously to a stable temp path.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("searxly-update-\(UUID().uuidString).dmg")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is delivered by didFinishDownloadingTo; only surface a genuine transport error here.
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
