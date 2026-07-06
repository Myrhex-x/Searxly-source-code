//
//  RampartSession.swift
//  Searxly
//
//  Session entity table + streaming reveal — faithful port of Rampart's `session.ts`
//  and `streaming.ts`.
//
//  A blanket `[REDACTED]` makes the assistant's replies nonsense. Instead each
//  redacted value gets a stable, typed placeholder (`[GIVEN_NAME_1]`, `[SSN_2]`) that
//  survives across turns: the same raw value always maps to the same token, so the
//  model can reason about "GIVEN_NAME_1" and we rehydrate the real value back into its
//  reply before display. The map lives only on-device; only placeholdered text leaves.
//

import Foundation

/// Token shape minted by the table, and the pattern used to find them on the way back.
/// Kept in one place so scrub and rehydrate can never disagree.
nonisolated private let placeholderPattern = try! NSRegularExpression(pattern: #"\[[A-Z][A-Z_]*_\d+\]"#)

nonisolated final class RampartSession {

    /// placeholder → original value. Read-only for diagnostics / the "N redacted" chip.
    private(set) var reverse: [String: String] = [:]
    private var forward: [String: String] = [:]      // "label:normalizedValue" → placeholder
    private var counters: [String: Int] = [:]        // per-label running index
    private let keepLabels: Set<String>

    init(keepLabels: Set<String> = RampartEntity.defaultKeep) {
        self.keepLabels = keepLabels
    }

    /// True if `token` is a placeholder this table can resolve.
    func knows(_ token: String) -> Bool { reverse[token] != nil }

    // MARK: - Scrub (PII → placeholders)

    /// Replace each redactable span with its placeholder and record the mapping. Spans are
    /// merged + keep-set-filtered + sorted right-to-left by the policy layer, so splicing
    /// from the end never invalidates an earlier offset. Returns the safe text and the
    /// placeholders introduced (in reading order).
    @discardableResult
    func scrub(_ raw: String, spans: [RampartDetection]) -> (text: String, placeholders: [String]) {
        let redactable = RampartPolicy.applyPolicy(spans, keepLabels: keepLabels)
        guard !redactable.isEmpty else { return (raw, []) }

        let mutable = NSMutableString(string: raw)
        var placeholders: [String] = []
        for span in redactable {                      // right-to-left
            let token = placeholder(for: span.label, value: span.text)
            placeholders.append(token)
            mutable.replaceCharacters(in: NSRange(location: span.start, length: span.length), with: token)
        }
        return (mutable as String, placeholders.reversed())
    }

    /// Get or mint the placeholder for a label+value. Idempotent: keyed by label plus the
    /// normalized value (lowercased, whitespace-collapsed, trimmed) so casing/spacing noise
    /// doesn't mint duplicate tokens, and the same person stays `[GIVEN_NAME_1]` every turn.
    private func placeholder(for label: String, value: String) -> String {
        let key = "\(label):\(Self.normalize(value))"
        if let existing = forward[key] { return existing }
        let next = (counters[label] ?? 0) + 1
        counters[label] = next
        let token = "[\(label)_\(next)]"
        forward[key] = token
        reverse[token] = value
        return token
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rehydrate (placeholders → PII)

    /// Restore real values in an assistant reply so the user sees "John", not "[GIVEN_NAME_1]".
    /// Unknown placeholders are left intact.
    func rehydrate(_ text: String) -> String {
        Self.replaceComplete(text, resolve: { reverse[$0] })
    }

    /// Replace every complete placeholder in `text` using `resolve`; non-resolving tokens
    /// are left verbatim.
    fileprivate static func replaceComplete(_ text: String, resolve: (String) -> String?) -> String {
        let ns = text as NSString
        let matches = placeholderPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        // Replace back-to-front so offsets stay valid.
        for match in matches.reversed() {
            let token = ns.substring(with: match.range)
            if let value = resolve(token) {
                result.replaceCharacters(in: match.range, with: value)
            }
        }
        return result as String
    }

    /// A streaming reveal that buffers across deltas so a placeholder split over chunk
    /// boundaries (`"[GIVEN" + "_NAME_1]"`) is never emitted half-revealed.
    func makeRevealTransform() -> RampartRevealTransform {
        RampartRevealTransform { [weak self] token in self?.reverse[token] }
    }

    // MARK: - Diagnostics

    /// A PII-safe summary of a scrub's placeholders, e.g. "GIVEN_NAME×2, SSN×1, EMAIL×1".
    /// Label names and counts only — never the redacted values — so it's safe to log.
    static func labelSummary(of placeholders: [String]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for token in placeholders {
            let label = labelOf(token)
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order.map { "\($0)×\(counts[$0]!)" }.joined(separator: ", ")
    }

    /// Extract the entity label from a `[LABEL_N]` placeholder.
    private static func labelOf(_ placeholder: String) -> String {
        var inner = placeholder
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        if let r = inner.range(of: "_", options: .backwards) {
            return String(inner[..<r.lowerBound])
        }
        return inner
    }
}

// MARK: - Streaming reveal

/// Stateful filter for the SSE reply stream (port of `streaming.ts`). Feed chunks in
/// order with `push`; it returns the text safe to render now, holding back only the
/// smallest suffix that could still become a placeholder. `finish` flushes the tail.
nonisolated final class RampartRevealTransform {

    // A run that might still grow into a placeholder: '[' then [A-Z_], optionally '_'
    // digits, not yet closed by ']'. If a suffix matches, hold it.
    nonisolated private static let partialToken = try! NSRegularExpression(pattern: #"\[[A-Z_]*(?:_\d*)?$"#)

    private var buffer: String = ""
    private let resolve: (String) -> String?

    init(resolve: @escaping (String) -> String?) { self.resolve = resolve }

    /// Reveal complete placeholders in the accumulated buffer, returning everything safe and
    /// holding any partial tail.
    func push(_ chunk: String) -> String {
        buffer += chunk
        let revealed = RampartSession.replaceComplete(buffer, resolve: resolve)
        let ns = revealed as NSString
        let tail = Self.partialToken.firstMatch(in: revealed, range: NSRange(location: 0, length: ns.length))
        guard let tail else {
            buffer = ""
            return revealed
        }
        let cut = tail.range.location
        buffer = ns.substring(from: cut)
        return ns.substring(to: cut)
    }

    /// Emit any buffered tail (e.g. a lone `[` that never became a token).
    func finish() -> String {
        defer { buffer = "" }
        return RampartSession.replaceComplete(buffer, resolve: resolve)
    }
}
