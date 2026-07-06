//
//  RampartEngine.swift
//  Searxly
//
//  Orchestrates detection: the always-on heuristic layer plus the optional MiniLM NER
//  layer. An actor because the Core ML session must be driven sequentially (one
//  inference at a time) and the model is loaded lazily on first use.
//

import Foundation
import os

actor RampartEngine {

    private var loaded: RampartModelLoader.Loaded?
    private var didAttemptLoad = false

    /// All detections (heuristic + NER) over `raw`, unmerged — the session's policy layer
    /// merges, applies the keep-set, and sorts before scrubbing.
    func detect(in raw: String) -> [RampartDetection] {
        let heuristics = DeterministicDetectors.detect(in: raw)
        guard let loaded = ensureLoaded() else { return heuristics }
        let ner = RampartNER.detect(in: raw,
                                    model: loaded.model,
                                    tokenizer: loaded.tokenizer,
                                    labels: loaded.labels)
        return heuristics + ner
    }

    /// Whether the optional ML model layer is present (vs. heuristic-only).
    func modelAvailable() -> Bool { ensureLoaded() != nil }

    @discardableResult
    private func ensureLoaded() -> RampartModelLoader.Loaded? {
        if !didAttemptLoad {
            didAttemptLoad = true
            loaded = RampartModelLoader.loadBundled()
            if loaded == nil {
                Log.privacy.notice("Rampart: ML model not bundled — running heuristic-only redaction.")
            } else {
                Log.privacy.notice("Rampart: ML NER model loaded.")
            }
        }
        return loaded
    }
}
