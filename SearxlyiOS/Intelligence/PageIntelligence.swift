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
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
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
        return AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: """
                    You summarize web pages. Reply with a tight summary of the page's substance: \
                    2–4 short paragraphs or up to 6 bullet points, no preamble, no meta-commentary. \
                    Match the language of the page text.
                    """)
                    let prompt = "Page title: \(title)\n\nPage text:\n\(text)"
                    let stream = session.streamResponse(to: prompt)
                    for try await partial in stream {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: NSError(
                domain: "Searxly.Intelligence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not supported on this device."]
            ))
            #endif
        }
    }
}
