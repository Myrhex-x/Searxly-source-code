//
//  HelperClient.swift
//  Searxly
//
//  Manages the NSXPCConnection to the SearxlyHelper XPC service.
//  LocalSearxngManager calls through this instead of spawning the SearXNG process directly.
//

import Foundation
import os

/// Thin wrapper around NSXPCConnection to SearxlyHelper.
/// Lazy-connects on first use and auto-reconnects after invalidation or interruption.
///
/// Must be used from the @MainActor (same isolation as LocalSearxngManager).
@MainActor
final class HelperClient {
    static let shared = HelperClient()
    private init() {}

    private var connection: NSXPCConnection?

    /// Returns a ready-to-use proxy, creating (or recreating) the connection as needed.
    ///
    /// The proxy is vended with a per-message error handler: if the XPC service can't be
    /// reached (failed to launch, crashed mid-call), the handler drops the stale connection
    /// so the *next* call rebuilds a fresh one instead of reusing a dead proxy.
    func proxy() -> SearxlyHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(serviceName: "com.myrhex.SearxlyHelper")
            c.remoteObjectInterface = NSXPCInterface(with: SearxlyHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor [weak self] in self?.connection = nil }
            }
            c.interruptionHandler = { [weak self] in
                Task { @MainActor [weak self] in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        let errorHandler: (Error) -> Void = { [weak self] error in
            Log.searxng.error("HelperClient: XPC message failed — \(error.localizedDescription)")
            Task { @MainActor [weak self] in self?.connection = nil }
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? SearxlyHelperProtocol
    }

    /// Tears down the connection immediately (call on app termination or if the XPC service crashes unrecoverably).
    func invalidate() {
        connection?.invalidate()
        connection = nil
    }
}
