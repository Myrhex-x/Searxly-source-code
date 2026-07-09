//
//  PageIntelligence.swift
//  SearxlyiOS
//
//  On-device AI via Apple Intelligence (FoundationModels, iOS 26) — the iOS expression of the
//  macOS on-device lane. Strictly local: the page text never leaves the device, nothing is
//  metered, and the whole feature simply doesn't surface on ineligible hardware.
//
//  First feature: Summarize Page (page menu ▸ Summarize Page → streaming summary sheet).
//

import Foundation
import WebKit
import Observation

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum PageIntelligence {

    enum Availability: Equatable {
        case available
        case notEnabled       // eligible device, the Apple Intelligence switch is OFF
        case downloading      // enabled, but the on-device model assets aren't ready yet
        case unsupported      // hardware or OS can't run it

        var label: String {
            switch self {
            case .available: "Available"
            case .notEnabled: "Apple Intelligence is turned off"
            case .downloading: "Downloading the on-device model…"
            case .unsupported: "Not supported on this device"
            }
        }
    }

    static var availability: Availability {
        #if DEBUG
        // Simulators have no model — SEARXLY_FAKE_AI=1 unlocks the AI UI with canned streams;
        // SEARXLY_FAKE_AI_DOWNLOADING=1 renders the model-downloading state for UI checks.
        if ProcessInfo.processInfo.environment["SEARXLY_FAKE_AI_DOWNLOADING"] == "1" { return .downloading }
        if SearchIntelligence.debugMocked { return .available }
        #endif
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            // Defensive string match — the exact UnavailableReason case names have drifted across
            // SDK seeds, and a hard `case .unavailable(.modelNotReady)` that no longer matches would
            // silently fall through to "unsupported" and hide the feature on a perfectly good device.
            // (This mirrors the macOS AppleIntelligenceProvider probe, which is the proven-working one.)
            let r = String(describing: reason).lowercased()
            if r.contains("notenabled") || r.contains("notturnedon") { return .notEnabled }
            if r.contains("notready") || r.contains("downloading") || r.contains("preparing") { return .downloading }
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    /// Nudges the on-device model app-wide: registers demand so iOS downloads/loads the assets, and
    /// warms the first inference. Called at launch (and when the SERP AI slot appears) so the model
    /// becomes ready wherever the user is — not only if they happen to open Settings ▸ Intelligence,
    /// which was the ONLY thing requesting it before (so a still-downloading model stayed hidden
    /// everywhere, forever). No-op when the model is off or the device is ineligible.
    static func prewarm() {
        #if canImport(FoundationModels)
        // Key off the REAL system availability (not the DEBUG mock), so this never pokes
        // FoundationModels in the simulator where there is no model.
        switch SystemLanguageModel.default.availability {
        case .available:
            LanguageModelSession().prewarm()
        case .unavailable(let reason):
            let r = String(describing: reason).lowercased()
            if r.contains("notready") || r.contains("downloading") || r.contains("preparing") {
                LanguageModelSession().prewarm()   // register demand → nudge the asset download
            }
        }
        #endif
    }

    /// A short, honest message for a generation error — Apple's on-device model refuses sensitive
    /// content (guardrails) and caps context, and a browser summarizing the real web hits both. Better
    /// to say what happened than to show a blank card.
    static func friendlyError(_ error: Error) -> String {
        let d = String(describing: error).lowercased()
        if d.contains("guardrail") || d.contains("safety") || d.contains("unsafe") {
            return L("The on-device model declined this content (Apple Intelligence safety filter).")
        }
        if d.contains("exceededcontext") || d.contains("context") || d.contains("token") || d.contains("too large") {
            return L("This page is too long for the on-device model.")
        }
        if d.contains("cancel") { return L("Cancelled.") }
        return error.localizedDescription
    }

    /// The exact reason string from FoundationModels — surfaced in the Intelligence pane so
    /// "why isn't it working" is never a guessing game.
    static var availabilityDetail: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return String(describing: reason)
        }
        #else
        return "FoundationModels framework unavailable"
        #endif
    }

    /// Best-effort nudge while the model is downloading: prewarming registers demand for the
    /// assets, which can move the system download along. Safe to call repeatedly; no-ops when
    /// the model is ready or the device is ineligible. (Apple exposes NO progress API for the
    /// system model download — the UI shows an indeterminate bar and polls availability.)
    static func requestModelIfNeeded() {
        #if canImport(FoundationModels)
        guard availability == .downloading else { return }
        LanguageModelSession().prewarm()
        #endif
    }

    static var isAvailable: Bool { availability == .available }

    /// The SERP shows its AI Overview slot when the model is ready OR still downloading — so a
    /// not-yet-ready model surfaces a "preparing" state (and gets prewarmed) instead of nothing.
    /// Hidden when Apple Intelligence is off or the device is ineligible.
    static var showsOverviewSlot: Bool {
        availability == .available || availability == .downloading
    }

    /// Page text budget: the on-device model has a small context window (~4k tokens), so the
    /// page's visible text is clamped — enough for articles, honest about very long pages.
    private static let maxChars = 9_000

    static func pageText(from webView: WKWebView) async -> String? {
        let js = "document.body ? document.body.innerText : ''"
        guard let raw = try? await webView.evaluateJavaScript(js) as? String else { return nil }
        let text = raw.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 200 else { return nil }  // not enough content to summarize honestly
        return String(text.prefix(maxChars))
    }

    /// Streams a summary of the given page text. Yields cumulative snapshots of the response.
    static func summarize(title: String, text: String) -> AsyncThrowingStream<String, Error> {
        #if DEBUG
        if SearchIntelligence.debugMocked {
            return SearchIntelligence.mockStream(
                "Mock on-device summary of “\(title)”. • First key point from the page. • Second key point. • Third, streamed word by word so the sheet UI can be verified in the simulator."
            )
        }
        #endif
        let prompt = "Page title: \(title)\n\nPage text:\n\(text)"
        return AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            // Matches the proven macOS provider's streaming shape (a normal Task; under default MainActor
            // isolation the model call suspends off the main thread anyway). No mid-inference cancellation
            // — cancelling FoundationModels mid-flight is the documented crash risk; the sheet ignores
            // late output via its own task instead.
            Task {
                do {
                    let session = LanguageModelSession(instructions: """
                    You summarize web pages. Reply with a tight summary of the page's substance: \
                    2–4 short paragraphs or up to 6 bullet points, no preamble, no meta-commentary. \
                    Match the language of the page text.
                    """)
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            #else
            continuation.finish(throwing: NSError(
                domain: "Searxly.Intelligence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not supported on this device."]
            ))
            #endif
        }
    }
}
