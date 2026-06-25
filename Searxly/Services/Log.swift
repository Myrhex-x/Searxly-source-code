//
//  Log.swift
//  Searxly
//

import Foundation
import os

// Categorized logging via os.Logger. Interpolated values are redacted by default in release; mark
// non-sensitive values `.public` explicitly when they need to be readable.
// `nonisolated`: the module defaults to MainActor isolation, but `Logger` is `Sendable` and these
// loggers are referenced from nonisolated contexts (keychain, ad-block, networking). Opting the type
// out keeps every logger callable from anywhere without an actor hop.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.myrhex.Searxly"

    static let security = Logger(subsystem: subsystem, category: "security")
    static let privacy = Logger(subsystem: subsystem, category: "privacy")
    static let wallet = Logger(subsystem: subsystem, category: "wallet")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let web = Logger(subsystem: subsystem, category: "web")
    static let adblock = Logger(subsystem: subsystem, category: "adblock")
    static let searxng = Logger(subsystem: subsystem, category: "searxng")
    static let tor = Logger(subsystem: subsystem, category: "tor")
    static let app = Logger(subsystem: subsystem, category: "general")
}
