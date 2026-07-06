//
//  DeterministicDetectors.swift
//  Searxly
//
//  Rampart's heuristic layer — the cheap, synchronous, zero-model first pass.
//  Faithful port of `heuristics.ts` + `validators.ts`.
//
//  Digit-bearing PII (card, SSN) is found over digit *runs* so every separator
//  variant collapses to one rule: `888-88-8888`, `888 88 8888`, `888.88.8888` and
//  `888888888` all match. Text-shaped PII (email, URL, IPv4/IPv6, MAC) is matched on
//  the raw string where the structure lives in the punctuation. These run before the
//  model and, being validator-/pattern-backed, win overlap resolution on score 1.
//

import Foundation

nonisolated enum DeterministicDetectors {

    /// Run every heuristic detector over `raw`. Spans may overlap; `RampartPolicy.mergeSpans`
    /// resolves conflicts before redaction.
    static func detect(in raw: String) -> [RampartDetection] {
        guard !raw.isEmpty else { return [] }
        return detectDigitEntities(in: raw) + detectTextEntities(in: raw)
    }

    // MARK: - Validators

    /// Luhn (mod-10) checksum — gates CREDIT_CARD so arbitrary digit runs don't match.
    static func luhnValid(_ digits: String) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        var double = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue, (0...9).contains(d) else { return false }
            if double {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// US SSN structural rules: area (first 3) ≠ 000/666/900-999; group (middle 2) ≠ 00;
    /// serial (last 4) ≠ 0000. Rejects phone numbers padded to nine digits.
    static func isValidSsn(_ digits: String) -> Bool {
        guard digits.count == 9 else { return false }
        let area = String(digits.prefix(3))
        let group = String(digits.dropFirst(3).prefix(2))
        let serial = String(digits.suffix(4))
        if area == "000" || area == "666" { return false }
        if (Int(area) ?? 0) >= 900 { return false }
        if group == "00" { return false }
        if serial == "0000" { return false }
        return true
    }

    // MARK: - Digit entities

    nonisolated private struct DigitRule {
        let label: String
        let lengths: Set<Int>
        let validate: (String) -> Bool
    }

    // Order matters: longer/stricter entities first so a 16-digit card is never carved
    // into a 9-digit SSN.
    nonisolated private static let digitRules: [DigitRule] = [
        DigitRule(label: RampartEntity.creditCard.rawValue, lengths: [16, 15, 14], validate: luhnValid),
        DigitRule(label: RampartEntity.ssn.rawValue, lengths: [9], validate: isValidSsn),
    ]

    /// A contiguous digit run joined only by single inline separators (space, dot, dash).
    nonisolated private static let digitRun = try! NSRegularExpression(pattern: #"\d(?:[ .-]?\d)*"#)

    private static func detectDigitEntities(in raw: String) -> [RampartDetection] {
        let ns = raw as NSString
        var spans: [RampartDetection] = []
        for match in digitRun.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            // Collect the run's digit characters with their absolute UTF-16 offsets.
            var digits = ""
            var rawIndex: [Int] = []
            let r = match.range
            for i in 0..<r.length {
                let cu = ns.character(at: r.location + i)
                if cu >= 0x30 && cu <= 0x39 {           // ASCII '0'..'9'
                    digits.append(Character(UnicodeScalar(cu)!))
                    rawIndex.append(r.location + i)
                }
            }
            guard let first = rawIndex.first, let last = rawIndex.last else { continue }
            for rule in digitRules where rule.lengths.contains(digits.count) {
                guard rule.validate(digits) else { continue }
                let start = first, end = last + 1
                spans.append(RampartDetection(start: start, end: end, label: rule.label,
                                              score: 1, source: .heuristic,
                                              text: ns.substring(with: NSRange(location: start, length: end - start))))
                break   // first matching rule (strict→loose) wins the run
            }
        }
        return spans
    }

    // MARK: - Text entities

    nonisolated private struct TextRule { let label: String; let regex: NSRegularExpression }

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    // Mirrors `TEXT_RULES` in heuristics.ts (order preserved; merge resolves overlaps).
    nonisolated private static let textRules: [TextRule] = [
        TextRule(label: RampartEntity.email.rawValue,
                 regex: re(#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#)),
        TextRule(label: RampartEntity.url.rawValue,
                 regex: re(#"\bhttps?://[^\s<>"'\])}]+"#)),
        TextRule(label: RampartEntity.url.rawValue,
                 regex: re(#"\bwww\.[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s<>"'\])}]*)?"#)),
        TextRule(label: RampartEntity.ipAddress.rawValue,
                 regex: re(#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)),
        TextRule(label: RampartEntity.ipAddress.rawValue,
                 regex: re(#"(?<![:.\w])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(?::[0-9A-Fa-f]{1,4}){1,6}|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4})(?![:.\w])"#)),
        TextRule(label: RampartEntity.ipAddress.rawValue,
                 regex: re(#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#)),
    ]

    private static func detectTextEntities(in raw: String) -> [RampartDetection] {
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [RampartDetection] = []
        for rule in textRules {
            for match in rule.regex.matches(in: raw, range: full) {
                let r = match.range
                guard r.length > 0 else { continue }
                spans.append(RampartDetection(start: r.location, end: r.location + r.length,
                                              label: rule.label, score: 1, source: .heuristic,
                                              text: ns.substring(with: r)))
            }
        }
        return spans
    }
}
