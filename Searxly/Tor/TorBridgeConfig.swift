//
//  TorBridgeConfig.swift
//  Searxly
//
//  Tor bridges + pluggable transports, so Tor keeps working on networks that block it (censored
//  countries, hostile Wi-Fi, some corporate networks). A "bridge" is an unlisted Tor entry relay; a
//  "pluggable transport" disguises the traffic so a censor can't fingerprint it as Tor:
//    • obfs4  — makes the stream look like random bytes (needs bridge lines from the user).
//    • Snowflake — hops through short-lived volunteer WebRTC proxies (works out of the box).
//
//  The transport binaries (lyrebird for obfs4, snowflake-client) ship inside the same Tor Project
//  expert bundle as `tor` itself — see scripts/fetch-tor-runtime.sh. The helper writes the matching
//  `UseBridges` / `ClientTransportPlugin` / `Bridge` lines into the torrc at launch. Applies to every
//  edition (onion tabs and Maximum + Tor alike); changing it restarts Tor.
//

import Foundation
import Observation

enum TorBridgeTransport: String, CaseIterable, Sendable {
    case none
    case obfs4
    case snowflake

    var displayName: String {
        switch self {
        case .none:      return "No bridges (direct)"
        case .obfs4:     return "obfs4 bridge"
        case .snowflake: return "Snowflake"
        }
    }

    var blurb: String {
        switch self {
        case .none:      return "Connect straight to the Tor network. Fastest, but blockable."
        case .obfs4:     return "Disguises Tor as random traffic. Paste bridge lines from the Tor Project."
        case .snowflake: return "Routes through volunteer WebRTC proxies. No setup — good when you can't get bridges."
        }
    }
}

@MainActor
@Observable
final class TorBridgeSettings {
    static let shared = TorBridgeSettings()

    private let transportKey = "Tor.Bridges.Transport"
    private let linesKey = "Tor.Bridges.Obfs4Lines"
    private let autoFallbackKey = "Tor.Bridges.AutoFallbackSnowflake"

    /// The active transport. Persisted; changing it should restart Tor (callers handle that).
    var transport: TorBridgeTransport {
        didSet {
            UserDefaults.standard.set(transport.rawValue, forKey: transportKey)
            // An explicit user choice always wins over an auto-fallback override from earlier this session.
            autoFallbackTransport = nil
        }
    }

    /// User-pasted obfs4 bridge lines, one per line (the part after "Bridge ", though a leading
    /// "Bridge " is tolerated and stripped).
    var obfs4Lines: String {
        didSet { UserDefaults.standard.set(obfs4Lines, forKey: linesKey) }
    }

    /// When a DIRECT Tor connection stalls (the signature of a censored network), automatically retry
    /// once through Snowflake without asking. On by default; ignored if the user has chosen their own
    /// bridge (we never override an explicit choice) or if the Snowflake binary isn't bundled.
    var autoFallbackToSnowflake: Bool {
        didSet { UserDefaults.standard.set(autoFallbackToSnowflake, forKey: autoFallbackKey) }
    }

    /// A session-only transport override set by auto-fallback (e.g. Snowflake after a direct stall). NOT
    /// persisted — next launch tries the user's real setting again, and re-falls-back if still blocked,
    /// so one bad network doesn't quietly downgrade Tor to Snowflake forever.
    var autoFallbackTransport: TorBridgeTransport?

    private init() {
        transport = TorBridgeTransport(rawValue: UserDefaults.standard.string(forKey: transportKey) ?? "") ?? .none
        obfs4Lines = UserDefaults.standard.string(forKey: linesKey) ?? ""
        autoFallbackToSnowflake = (UserDefaults.standard.object(forKey: autoFallbackKey) as? Bool) ?? true
    }

    /// The user's configured transport (drives Settings UI).
    var isEnabled: Bool { transport != .none }

    /// The transport actually in effect right now — a session auto-fallback override wins over the saved
    /// choice. This is what the torrc the helper writes is built from.
    var effectiveTransport: TorBridgeTransport { autoFallbackTransport ?? transport }
    var effectiveIsEnabled: Bool { effectiveTransport != .none }

    /// True when Snowflake can run (so auto-fallback can engage it). In the current Tor expert bundle
    /// Snowflake is served by `lyrebird` — there is no separate snowflake-client binary anymore.
    var snowflakeAvailable: Bool { TorManager.shared.bundledPluggableTransportPath(named: "lyrebird") != nil }

    /// The argument to `ClientTransportPlugin` for the chosen transport, or "" if none / the binary
    /// isn't bundled. Includes the absolute path to the bundled transport executable.
    func transportPluginLine() -> String {
        switch effectiveTransport {
        case .none:
            return ""
        case .obfs4:
            guard let path = TorManager.shared.bundledPluggableTransportPath(named: "lyrebird") else { return "" }
            return "obfs4 exec \(path)"
        case .snowflake:
            // Snowflake is provided by lyrebird now (pt_config.json: "snowflake … exec …/lyrebird"),
            // not a separate snowflake-client binary.
            guard let path = TorManager.shared.bundledPluggableTransportPath(named: "lyrebird") else { return "" }
            return "snowflake exec \(path)"
        }
    }

    /// Bridge lines (each the part after "Bridge ") for the transport in effect, ready for the torrc.
    func bridgeLines() -> [String] {
        switch effectiveTransport {
        case .none:
            return []
        case .obfs4:
            return obfs4Lines
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { line in
                    // Tolerate a pasted full "Bridge obfs4 …" line by stripping the leading keyword.
                    line.lowercased().hasPrefix("bridge ") ? String(line.dropFirst(7)) : line
                }
        case .snowflake:
            return Self.snowflakeBridges
        }
    }

    /// The newline-joined bridge lines passed over XPC to the helper (which prefixes each with "Bridge ").
    func bridgeLinesJoined() -> String { bridgeLines().joined(separator: "\n") }

    /// Whether the chosen transport's binary is actually present in the bundle. The UI warns when it
    /// isn't (the runtime needs re-fetching with `scripts/fetch-tor-runtime.sh`).
    var transportBinaryAvailable: Bool {
        switch transport {
        case .none:      return true
        case .obfs4:     return TorManager.shared.bundledPluggableTransportPath(named: "lyrebird") != nil
        case .snowflake: return TorManager.shared.bundledPluggableTransportPath(named: "lyrebird") != nil
        }
    }

    /// True when the config is usable as-is (has what the chosen transport needs).
    var isReady: Bool {
        switch transport {
        case .none:      return true
        case .obfs4:     return transportBinaryAvailable && !bridgeLines().isEmpty
        case .snowflake: return transportBinaryAvailable
        }
    }

    /// Tor's built-in Snowflake bridges (verbatim from the expert bundle's pt_config.json, 15.0.16).
    /// Best-effort — broker fronts rotate over time, so obfs4 with fresh user-supplied lines is the more
    /// reliable option in a hard block. Keep in lockstep when bumping the Tor runtime.
    static let snowflakeBridges = [
        "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://1098762253.rsc.cdn77.org/ fronts=app.datapacket.com,www.datapacket.com ice=stun:stun.epygi.com:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.mixvoip.com:3478,stun:stun.telnyx.com:3478,stun:stun.hot-chilli.net:3478,stun:stun.fitauto.ru:3478,stun:stun.m-online.net:3478 utls-imitate=hellorandomizedalpn",
        "snowflake 192.0.2.4:80 8838024498816A039FCBBAB14E6F40A0843051FA fingerprint=8838024498816A039FCBBAB14E6F40A0843051FA url=https://1098762253.rsc.cdn77.org/ fronts=app.datapacket.com,www.datapacket.com ice=stun:stun.epygi.com:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.mixvoip.com:3478,stun:stun.telnyx.com:3478,stun:stun.hot-chilli.net:3478,stun:stun.fitauto.ru:3478,stun:stun.m-online.net:3478 utls-imitate=hellorandomizedalpn",
    ]
}
