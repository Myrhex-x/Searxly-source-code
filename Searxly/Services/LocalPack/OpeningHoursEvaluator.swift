//
//  OpeningHoursEvaluator.swift
//  Searxly
//
//  A small, defensive evaluator for the common OSM `opening_hours` patterns (e.g.
//  "Mo-Fr 08:30-12:30,14:30-19:30; Sa 09:00-12:30"). It is deliberately conservative: anything it can't
//  confidently parse returns `.unknown` so the local pack never shows a wrong open/closed state. Full
//  opening_hours grammar (holidays, month ranges, "sunrise", etc.) is out of scope — those fall through
//  to `.unknown`.
//

import Foundation

enum OpenState: Equatable {
    case open(closesAt: String?)
    case closed(opensAt: String?)
    case unknown
}

enum OpeningHoursEvaluator {

    /// Mo…Su → Calendar weekday (Sun = 1 … Sat = 7).
    private static let dayIndex: [String: Int] = [
        "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7, "su": 1
    ]
    private static let dayOrder = ["su", "mo", "tu", "we", "th", "fr", "sa"]  // index by weekday-1

    static func evaluate(_ spec: String, now: Date = Date()) -> OpenState {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return .unknown }
        if s.contains("24/7") { return .open(closesAt: nil) }

        var intervals: [Int: [(open: Int, close: Int)]] = [:]   // weekday → time ranges (minutes)
        var parsedAnything = false

        for rawRule in s.split(separator: ";") {
            let rule = rawRule.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty else { continue }
            guard let (days, timePart) = splitDaysAndTimes(rule) else { continue }

            if timePart == "off" || timePart == "closed" {
                parsedAnything = true          // an explicit closed day is still a successful parse
                continue
            }
            guard let ranges = parseTimeRanges(timePart), !ranges.isEmpty else { continue }
            for day in days {
                intervals[day, default: []].append(contentsOf: ranges)
                parsedAnything = true
            }
        }

        guard parsedAnything else { return .unknown }

        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else {
            return .unknown
        }
        let nowMinutes = hour * 60 + minute
        let today = intervals[weekday] ?? []

        for range in today where nowMinutes >= range.open && nowMinutes < range.close {
            return .open(closesAt: format(range.close))
        }
        // Closed now — surface the next opening time later today, if any.
        if let next = today.filter({ $0.open > nowMinutes }).map({ $0.open }).min() {
            return .closed(opensAt: format(next))
        }
        return .closed(opensAt: nil)
    }

    // MARK: - Parsing

    /// Splits a rule into its day set and its time part. A rule with no leading day spec applies to every
    /// day ("09:00-18:00"). Returns nil when the day spec can't be understood.
    private static func splitDaysAndTimes(_ rule: String) -> (days: [Int], time: String)? {
        // A time part starts at the first digit; everything before it is the day spec.
        guard let firstDigit = rule.firstIndex(where: { $0.isNumber }) else {
            // No digits: only "<days> off/closed" is meaningful.
            if rule.hasSuffix("off") || rule.hasSuffix("closed") {
                let daySpec = rule.replacingOccurrences(of: "off", with: "").replacingOccurrences(of: "closed", with: "")
                guard let days = parseDays(daySpec.trimmingCharacters(in: .whitespaces)) else { return nil }
                return (days, "off")
            }
            return nil
        }
        let daySpec = String(rule[rule.startIndex..<firstDigit]).trimmingCharacters(in: .whitespaces)
        let timePart = String(rule[firstDigit...]).trimmingCharacters(in: .whitespaces)
        let days = daySpec.isEmpty ? Array(1...7) : parseDays(daySpec)
        guard let days else { return nil }
        return (days, timePart)
    }

    /// Parses "Mo-Fr", "Mo,We,Fr", "Sa" → weekday indices. Returns nil on any unrecognized token.
    private static func parseDays(_ spec: String) -> [Int]? {
        let cleaned = spec.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        var result: Set<Int> = []
        for part in cleaned.split(separator: ",") {
            if part.contains("-") {
                let bounds = part.split(separator: "-")
                guard bounds.count == 2,
                      let start = dayIndex[String(bounds[0])],
                      let end = dayIndex[String(bounds[1])] else { return nil }
                // Walk start→end in Mo…Su order (with wrap), so "Fr-Mo" also works.
                var i = start
                while true {
                    result.insert(i)
                    if i == end { break }
                    i = i % 7 + 1
                }
            } else {
                guard let d = dayIndex[String(part)] else { return nil }
                result.insert(d)
            }
        }
        return Array(result)
    }

    /// Parses "08:30-12:30,14:30-19:30" → minute ranges. Returns nil on any malformed range.
    private static func parseTimeRanges(_ spec: String) -> [(open: Int, close: Int)]? {
        var out: [(Int, Int)] = []
        for part in spec.replacingOccurrences(of: " ", with: "").split(separator: ",") {
            let bounds = part.split(separator: "-")
            guard bounds.count == 2,
                  let open = minutes(String(bounds[0])),
                  let close = minutes(String(bounds[1])),
                  close > open else { return nil }
            out.append((open, close))
        }
        return out
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func format(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
