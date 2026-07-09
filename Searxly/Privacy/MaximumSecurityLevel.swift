//
//  MaximumSecurityLevel.swift
//  Searxly
//
//  A Tor-Browser-style security slider for Searxly Maximum. The browser's biggest residual risk isn't
//  fingerprinting — it's a JavaScript engine EXPLOIT (historically the exact tool used to deanonymise Tor
//  users), and nearly all of those need the JIT. WKWebView exposes no public "disable JIT" knob, so the
//  strongest lever we DO have is turning content JavaScript OFF — which removes the JIT and the entire JS
//  attack surface with it. This enum drives that, plus dropping the GPU/WASM surface a notch earlier.
//
//  Only meaningful in Searxly Maximum; the base app never reads it (stays `.standard`).
//

import Foundation

enum MaximumSecurityLevel: String, CaseIterable, Codable, Sendable {
    /// Everything on. Sites work normally; farbling still applies.
    case standard
    /// Turns on WebKit's Lockdown Mode (engine-level JIT-off — the #1 exploit mitigation) and drops the
    /// high-risk GPU + WebAssembly surface (WebGL / WebGPU / WASM) in the engine, while KEEPING JavaScript
    /// so most sites still work.
    case safer
    /// JavaScript OFF on the web (the local SearXNG search UI still runs). Kills the JIT and the whole JS
    /// exploit surface — the strongest posture, at the cost of many sites needing JS re-enabled per visit.
    case safest

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .safer:    return "Safer"
        case .safest:   return "Safest"
        }
    }

    var summary: String {
        switch self {
        case .standard: return "Everything works. Fingerprint scrambling still on."
        case .safer:    return "JIT off (Lockdown Mode) + WebGL/WebGPU/WASM off — big exploit-surface cut, JavaScript still works."
        case .safest:   return "JavaScript off on the web (search still works). Strongest, but many sites break."
        }
    }

    /// Whether the heavy GPU/WASM APIs should be neutered (Safer and above).
    var dropsHighRiskAPIs: Bool { self != .standard }
    /// Whether content JavaScript should be denied on remote sites (Safest only).
    var deniesRemoteJavaScript: Bool { self == .safest }
}

@MainActor
@Observable
final class MaximumSecurity {
    static let shared = MaximumSecurity()

    static let levelChangedNotification = Notification.Name("Searxly.MaximumSecurityLevelChanged")
    private static let key = "Searxly.Maximum.SecurityLevel"

    private(set) var level: MaximumSecurityLevel

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        level = MaximumSecurityLevel(rawValue: raw) ?? .standard
    }

    func setLevel(_ newLevel: MaximumSecurityLevel) {
        guard newLevel != level else { return }
        level = newLevel
        UserDefaults.standard.set(newLevel.rawValue, forKey: Self.key)
        // Webviews read the level when they're built + in the navigation delegate; post so open tabs can
        // rebuild and pick up the new posture.
        NotificationCenter.default.post(name: Self.levelChangedNotification, object: nil)
    }

    /// The effective level for this edition. The base app never applies the slider (always `.standard`).
    static var effective: MaximumSecurityLevel { Edition.isMaximum ? shared.level : .standard }
}
