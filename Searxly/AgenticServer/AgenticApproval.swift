//
//  AgenticApproval.swift
//  Searxly — Agentic Tools
//
//  Human-in-the-loop gate for irreversible actions. The browser-control tools let a local AI fill and
//  submit forms; filling is reversible, but *submitting* posts data, creates accounts, or sends messages.
//  When "Confirm before acting" is on (default), the AI can fill fields freely, but a submit pauses here
//  for a single tap of approval in the app. The tool call suspends until the user decides.
//
//  Fail-safe: if no UI resolves the request within the timeout, it auto-denies — a tool call never hangs.
//

import Foundation
import Observation

@MainActor
@Observable
final class AgenticApproval {
    static let shared = AgenticApproval()

    struct PendingApproval: Identifiable, Equatable {
        let id = UUID()
        let title: String     // short prompt, e.g. "Submit a form?"
        let detail: String    // what and where, e.g. "The AI wants to submit a form on example.com."
    }

    /// The request awaiting a decision, or nil. ContentView observes this and presents an alert.
    private(set) var pending: PendingApproval?
    private var continuation: CheckedContinuation<Bool, Never>?

    private init() {}

    /// Ask the user to approve an irreversible action; returns true to proceed.
    /// Returns true immediately when the confirm setting is off (no gate). Denies if a request is already
    /// pending, or if nothing resolves this one before `timeout` (so the tool never blocks forever).
    func confirm(title: String, detail: String, timeout: TimeInterval = 90) async -> Bool {
        guard AgenticServerManager.shared.confirmActionsEnabled else { return true }
        guard pending == nil else { return false }   // don't clobber an in-flight request

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            continuation = cont
            let request = PendingApproval(title: title, detail: detail)
            pending = request
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.pending?.id == request.id else { return }
                self.resolve(false)   // fail safe: no answer in time → deny
            }
        }
    }

    /// Resolve the pending request. Called by the app UI (Approve/Deny) and by the fail-safe timeout.
    func resolve(_ approved: Bool) {
        guard let cont = continuation else { pending = nil; return }
        continuation = nil
        pending = nil
        cont.resume(returning: approved)
    }

    var isAwaitingDecision: Bool { pending != nil }
}
