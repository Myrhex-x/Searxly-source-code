//
//  RampartGuard.swift
//  Searxly
//
//  Public protect/reveal surface — Searxly's equivalent of Rampart's `ChatGuard`.
//  One guard belongs to one chat turn: `protect` scrubs the outbound text and remembers
//  the mapping; `reveal` / `makeRevealTransform` restore real values in the reply.
//
//  `RampartRedactor.shared` is the app-wide entry point: it owns the (lazily loaded)
//  engine, exposes the user setting, and mints a fresh guard per turn.
//

import Foundation

nonisolated final class RampartGuard {
    private let engine: RampartEngine
    let session: RampartSession

    init(engine: RampartEngine, keepLabels: Set<String>) {
        self.engine = engine
        self.session = RampartSession(keepLabels: keepLabels)
    }

    /// Detect PII and replace it with placeholders. Returns the safe text, the number of spans
    /// hidden, and a PII-safe label summary (e.g. "GIVEN_NAME×2, SSN×1") for logging/UI.
    func protect(_ text: String) async -> (text: String, count: Int, summary: String) {
        let spans = await engine.detect(in: text)
        let result = session.scrub(text, spans: spans)
        return (result.text, result.placeholders.count, RampartSession.labelSummary(of: result.placeholders))
    }

    /// Restore real values in a complete reply.
    func reveal(_ text: String) -> String { session.rehydrate(text) }

    /// A streaming reveal for the SSE reply (placeholders may straddle chunk boundaries).
    func makeRevealTransform() -> RampartRevealTransform { session.makeRevealTransform() }
}

/// App-wide redaction entry point. Holds the shared engine (model loaded once) and the
/// user-facing on/off setting; hands out a fresh `RampartGuard` per turn.
nonisolated final class RampartRedactor: Sendable {
    static let shared = RampartRedactor()

    /// UserDefaults key for the "redact PII before cloud AI" toggle. Default ON.
    static let enabledDefaultsKey = "redactPIIBeforeCloudAI"

    private let engine = RampartEngine()
    private let keepLabels: Set<String>

    private init(keepLabels: Set<String> = RampartEntity.defaultKeep) {
        self.keepLabels = keepLabels
    }

    /// Whether redaction is enabled (default true when the user hasn't chosen).
    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// A new per-turn guard sharing the app's engine/model.
    func newSession() -> RampartGuard {
        RampartGuard(engine: engine, keepLabels: keepLabels)
    }

    /// Whether the optional ML NER layer is bundled (vs. heuristic-only).
    func modelAvailable() async -> Bool { await engine.modelAvailable() }
}
