//
//  IntelligenceAvailability.swift
//  Searxly
//
//  NEW FILE (Phase 0).
//  Runtime detection for Apple Intelligence / FoundationModels availability.
//  Designed to be called from LocalIntelligenceManager and Settings.
//  Graceful on any macOS / hardware. No side effects.
//

import Foundation

// Note: FoundationModels is only present on sufficiently new SDKs + runtime.
// We use #if canImport + runtime checks so the project continues to compile
// even if the developer is on an older Xcode targeting older deployment.

enum IntelligenceAvailabilityChecker {

    /// Performs a best-effort synchronous or cheap async probe.
    /// Callers (manager) should cache the result and re-probe on demand or after OS notifications.
    static func currentAvailability() -> IntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // The real check lives in the manager so we can observe .modelNotReady etc.
            // Here we just confirm the framework thinks the device class is eligible.
            // Detailed .availability is retrieved via SystemLanguageModel in the manager.
            return .available   // Will be refined by the live SystemLanguageModel check
        } else {
            return .deviceNotSupported
        }
        #else
        return .deviceNotSupported
        #endif
    }

    /// Human-readable guidance string for the user when unavailable.
    static func guidance(for availability: IntelligenceAvailability) -> String {
        switch availability {
        case .available:
            return "On-device Apple Intelligence is ready."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled on this Mac. Go to System Settings → Apple Intelligence & Siri to enable it, then restart Searxly."
        case .deviceNotSupported:
            return "On-device AI requires Apple Silicon and macOS 26 or later with Apple Intelligence support. On older macOS you can still use a cloud or Ollama backend in Settings."
        case .modelNotReady:
            return "Apple Intelligence models are still being prepared by macOS. This usually finishes in a few minutes on first use."
        case .unavailable(let reason):
            return "On-device AI is currently unavailable: \(reason)"
        }
    }
}