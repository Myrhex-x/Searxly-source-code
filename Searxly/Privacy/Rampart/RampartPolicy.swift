//
//  RampartPolicy.swift
//  Searxly
//
//  Span reconciliation + default-deny keep-set — a faithful port of Rampart's
//  `policy.ts`. Detectors (heuristic + NER) emit overlapping, possibly conflicting
//  spans; `mergeSpans` resolves them into a disjoint set and `applyPolicy` drops
//  anything in the keep-set, leaving only the spans that must be redacted (sorted
//  right-to-left so callers can splice from the end without invalidating offsets).
//

import Foundation

nonisolated enum RampartPolicy {

    /// True when a label must be redacted under the default-deny policy.
    static func shouldRedact(_ label: String, keepLabels: Set<String>) -> Bool {
        !keepLabels.contains(label)
    }

    /// Reduce overlapping spans to a disjoint set. Higher confidence wins; ties break
    /// toward the longer span, then toward heuristics (validator-backed). Biased to
    /// *keep* a redaction — on partial overlap the byte-union is taken under the
    /// preferred label so the loser's exclusive bytes are never silently exposed.
    static func mergeSpans(_ spans: [RampartDetection]) -> [RampartDetection] {
        guard spans.count > 1 else { return spans }
        let sorted = spans.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.end > b.end
        }

        var merged: [RampartDetection] = []
        for span in sorted {
            guard let prev = merged.last else { merged.append(span); continue }
            if span.start >= prev.end { merged.append(span); continue }

            let winner = preferred(prev, span)
            let prevContains = prev.start <= span.start && prev.end >= span.end
            let spanContains = span.start <= prev.start && span.end >= prev.end
            if prevContains || spanContains {
                merged[merged.count - 1] = winner
            } else {
                // Partial overlap: union the byte range under the winning label.
                merged[merged.count - 1] = RampartDetection(
                    start: Swift.min(prev.start, span.start),
                    end: Swift.max(prev.end, span.end),
                    label: winner.label,
                    score: winner.score,
                    source: winner.source,
                    text: winner.text
                )
            }
        }
        return merged
    }

    private static func preferred(_ a: RampartDetection, _ b: RampartDetection) -> RampartDetection {
        if a.score != b.score { return a.score > b.score ? a : b }
        if a.length != b.length { return a.length > b.length ? a : b }
        return a.source == .heuristic ? a : b
    }

    /// Apply the keep-set. Returns only spans that must be redacted, sorted right-to-left
    /// (descending start) so callers splice from the end and keep earlier offsets valid.
    static func applyPolicy(_ spans: [RampartDetection], keepLabels: Set<String>) -> [RampartDetection] {
        mergeSpans(spans)
            .filter { shouldRedact($0.label, keepLabels: keepLabels) }
            .sorted { $0.start > $1.start }
    }
}
