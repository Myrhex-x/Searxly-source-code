//
//  main.swift
//  SearxlyHelper
//
//  Created by Myrhex-x on 6/15/26.
//

import Foundation
import os
import Security

class ServiceDelegate: NSObject, NSXPCListenerDelegate {

    private static let log = Logger(subsystem: "com.myrhex.SearxlyHelper", category: "security")

    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        // Defense in depth: this XPC service is UNSANDBOXED — it spawns the bundled SearXNG/Tor
        // processes and touches the filesystem. So we only accept connections from code signed by the
        // SAME Apple Developer team as this helper, derived at runtime (no hardcoded Team ID — keeps the
        // public source clean and works on any signing identity). On an unsigned / ad-hoc dev build
        // (no Team ID) we skip the check so local development still works; shipped builds are team-signed.
        if let requirement = Self.sameTeamCodeRequirement() {
            newConnection.setCodeSigningRequirement(requirement)
        } else {
            Self.log.notice("No Team ID on this helper build (unsigned/ad-hoc) — skipping XPC peer code-signing check.")
        }

        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: SearxlyHelperProtocol.self)

        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = HelperService()
        newConnection.exportedObject = exportedObject

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()

        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }

    /// A code-signing requirement the connecting peer must satisfy: an Apple-issued signing chain plus
    /// the same Team ID as this helper. Returns nil when this helper itself has no Team ID (unsigned /
    /// ad-hoc dev build), in which case the caller skips enforcement.
    private static func sameTeamCodeRequirement() -> String? {
        guard let team = currentTeamIdentifier(), !team.isEmpty else { return nil }
        // `anchor apple generic` holds for both Apple Development and Developer ID chains;
        // `certificate leaf[subject.OU] = <team>` pins the peer's leaf certificate to our team.
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The Team ID this helper was signed with, or nil if it isn't team-signed.
    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
