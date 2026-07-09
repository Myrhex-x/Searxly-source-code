//
//  RuntimeIntegrity.swift
//  Searxly
//
//  Supply-chain tamper detection for the bundled native Tor runtime. Searxly ships a `tor` client and
//  (optionally) pluggable-transport binaries (lyrebird / snowflake-client) under Resources/tor-runtime/,
//  and the unsandboxed helper exec's them. Those files live in Resources/ — sealed by the app's code
//  signature at rest, but NOT re-validated by the kernel on every launch the way the main executable is.
//  A local attacker who can write into the .app after first launch could swap `tor` for a build that
//  leaks. For a "trust the binary" edition that's the one substitution that would quietly defeat the
//  whole model, so we verify before ever exec'ing it.
//
//  Rather than pin raw SHA-256 hashes (which would go stale every time the runtime is re-signed at build
//  or notarization time, and could be swapped alongside the binary), we pin AUTHENTICITY: each bundled
//  native binary must carry a valid code signature whose Team ID matches the Team ID that signed Searxly
//  itself. A patched binary fails signature validation; a foreign binary carries a different team. Both
//  are rejected, and TorManager fails closed (won't start Tor). Skipped only for unsigned local dev
//  builds, where there's no team to pin against.
//

import Foundation
import Security

enum RuntimeIntegrity {

    struct Report {
        /// Binaries that verified OK (display names).
        let checked: [String]
        /// "name: reason" for each binary that failed — empty when everything verified.
        let failures: [String]
        /// Non-nil when verification was intentionally skipped (e.g. unsigned dev build) rather than run.
        let skippedReason: String?

        var ok: Bool { failures.isEmpty }
    }

    /// Verify every bundled native Tor-runtime binary is validly signed by the app's own team.
    static func verifyTorRuntime() -> Report {
        guard let res = Bundle.main.resourceURL else {
            return Report(checked: [], failures: [], skippedReason: "no resource bundle")
        }
        let root = res.appendingPathComponent("tor-runtime", isDirectory: true)

        // Pin against the app's OWN Team ID — but only for a Developer ID (release/distribution) build.
        // A dev Run build is signed with an Apple Development cert under the developer's *personal* team,
        // whereas the bundled runtime is signed Developer ID under the org team, so the teams legitimately
        // differ there; enforcing would false-alarm and block Tor. The shipped build (Developer ID,
        // notarized) is the one whose binary actually needs pinning, and there app == runtime == org team.
        let own = signingInfo(atPath: Bundle.main.bundleURL.path)
        guard own.isDeveloperID, let ownTeam = own.team, !ownTeam.isEmpty else {
            return Report(checked: [], failures: [], skippedReason: "not a Developer ID release build (dev/ad-hoc) — runtime pinning applies to shipped builds")
        }

        let fm = FileManager.default
        var candidates: [(name: String, url: URL)] = []

        let tor = root.appendingPathComponent("tor")
        if fm.fileExists(atPath: tor.path) { candidates.append(("tor", tor)) }

        for pt in ["lyrebird", "snowflake-client"] {
            let u = root.appendingPathComponent("pluggable_transports/\(pt)")
            if fm.fileExists(atPath: u.path) { candidates.append((pt, u)) }
        }

        // Any sibling dylibs the tor binary links against are also native code — verify them too.
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for u in entries where u.pathExtension == "dylib" {
                candidates.append(("dylib \(u.lastPathComponent)", u))
            }
        }

        guard !candidates.isEmpty else {
            return Report(checked: [], failures: [], skippedReason: "no bundled Tor runtime present")
        }

        var checked: [String] = []
        var failures: [String] = []
        for (name, url) in candidates {
            let info = signingInfo(atPath: url.path)
            if !info.valid {
                failures.append("\(name): signature invalid or binary modified")
            } else if info.team != ownTeam {
                failures.append("\(name): signed by \(info.team ?? "unknown") (expected \(ownTeam))")
            } else {
                checked.append(name)
            }
        }
        return Report(checked: checked, failures: failures, skippedReason: nil)
    }

    /// `(valid, team, isDeveloperID)` for the code at `path` — works for a .app bundle or a standalone
    /// Mach-O. `valid` runs a full signature check (validates the CMS signature AND that the on-disk bytes
    /// match the sealed code directory), so any modification flips it false. `isDeveloperID` is true when
    /// the leaf certificate is a "Developer ID Application" cert (a distribution build).
    private static func signingInfo(atPath path: String) -> (valid: Bool, team: String?, isDeveloperID: Bool) {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return (false, nil, false)
        }

        let valid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess

        var infoRef: CFDictionary?
        var team: String?
        var isDeveloperID = false
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
           let dict = infoRef as? [String: Any] {
            team = dict[kSecCodeInfoTeamIdentifier as String] as? String
            if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
               let leaf = certs.first {
                var cn: CFString?
                if SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess,
                   let name = cn as String? {
                    isDeveloperID = name.hasPrefix("Developer ID Application")
                }
            }
        }
        return (valid, team, isDeveloperID)
    }
}
