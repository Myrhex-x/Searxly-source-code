//
//  SearchIntelligence.swift
//  SearxlyiOS
//
//  On-device AI Overview for the SERP: a grounded answer synthesized STRICTLY from the top
//  result snippets (never from the model's own memory of the web), with [n] citations and
//  suggested follow-up searches. Runs entirely on-device — so unlike the knowledge cards it
//  is allowed in private tabs (zero egress).
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct AIOverview: Equatable {
    var text: String
    var followUps: [String]
    /// Indexes into the results the overview was grounded on (1-based, as cited).
    var sourceCount: Int
}

@MainActor
enum SearchIntelligence {

    /// Per-session cache so scope flips / re-searches don't regenerate.
    private static var cache: [String: AIOverview] = [:]

    static func cached(for query: String) -> AIOverview? {
        cache[query.lowercased()]
    }

    /// Queries that read like questions get an automatic overview; anything else shows
    /// a "Generate" affordance instead of burning the model on navigational searches.
    static func isQuestionLike(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 12 else { return false }
        if q.contains("?") { return true }
        let interrogatives = ["how ", "what ", "why ", "when ", "who ", "which ", "where ",
                              "can ", "does ", "do ", "is ", "are ", "should ", "could ",
                              "comment ", "pourquoi ", "quand ", "quel", "que ", "qui ",
                              "cómo ", "qué ", "por qué ", "wie ", "was ", "warum ", "wann "]
        if interrogatives.contains(where: { q.hasPrefix($0) }) { return true }
        if q.contains(" vs ") || q.contains("difference between") || q.contains("différence") { return true }
        return q.split(separator: " ").count >= 5
    }

    /// Streams the overview ANSWER as plain text (cumulative snapshots). Deliberately NOT guided
    /// generation: on the ~3B on-device model a nested @Generable with an array-count constraint
    /// often yields empty output (the "completely blank" bug). Plain text streaming is reliable.
    /// Follow-ups come separately from SearXNG's own related searches (see AIOverviewCard).
    static func overview(query: String, results: [SearXNGResult]) -> AsyncThrowingStream<String, Error> {
        // Build the whole prompt HERE (main actor, pure string work) so the off-main model task
        // captures only Sendable strings — never the results array.
        let sources = results.prefix(5)
        var grounding = ""
        for (i, r) in sources.enumerated() {
            let snippet = (r.content ?? r.title).prefix(200)
            grounding += "[\(i + 1)] \(r.title): \(snippet)\n"
        }
        let prompt = """
        Answer this search using ONLY the snippets below. Query: "\(query)"

        Snippets:
        \(grounding)
        """

        #if DEBUG
        if debugMocked {
            return mockStream("Based on the results, this is a concise on-device answer to “\(query)”, grounded in the snippets above and citing them like [1] and [3]. It never uses outside knowledge [2].")
        }
        #endif

        return AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            // Use the SINGLE proven call from the working macOS provider: `respond(to:)` (non-streaming),
            // not `streamResponse`. macOS `AppleIntelligenceProvider.generate()` does exactly this and is
            // the reliable on-device path; the SERP overview is short (≤90 words) so one-shot latency is
            // fine. Wrapped in a one-yield stream so the card's consumer is unchanged. No mid-inference
            // task cancellation (documented crash risk); a short generation just runs to completion.
            Task {
                do {
                    let session = LanguageModelSession(instructions: Self.overviewInstructions)
                    let response = try await session.respond(to: prompt)
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            #else
            continuation.finish(throwing: NSError(
                domain: "Searxly.Intelligence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available."]
            ))
            #endif
        }
    }

    private static let overviewInstructions = """
    You write brief search overviews grounded ONLY in the provided snippets — never outside \
    knowledge. Answer in at most 90 words of plain prose (no headings, no lists), citing snippets \
    inline like [1] or [2][4]. If the snippets don't answer the query, say so in one sentence. \
    Match the query's language.
    """

    /// Related searches for the follow-up chips, from the instance's `/autocompleter` (the same
    /// endpoint the address bar uses — reliable, unlike the `suggestions` engine which many
    /// instances leave off). The search query already reached the instance to produce the
    /// visible results, so this adds no new egress; still, callers skip it for private tabs.
    static func relatedSearches(for query: String) async -> [String] {
        var comps = URLComponents(string: "\(SearchSettings.shared.base)/autocompleter")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any],
              parsed.count >= 2, let terms = parsed[1] as? [String] else { return [] }
        return terms.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
    }

    /// Caches the final overview for the session.
    static func store(answer: String, followUps: [String], query: String, sourceCount: Int) -> AIOverview {
        let overview = AIOverview(
            text: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            followUps: Array(followUps.filter { !$0.isEmpty && $0.count < 60 }.prefix(4)),
            sourceCount: sourceCount
        )
        cache[query.lowercased()] = overview
        return overview
    }

    // MARK: - DEBUG mock (simulator has no model; lets the UI be verified headless)

    #if DEBUG
    static var debugMocked: Bool {
        ProcessInfo.processInfo.environment["SEARXLY_FAKE_AI"] == "1"
    }

    static func mockStream(_ full: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var shown = ""
                for word in full.split(separator: " ", omittingEmptySubsequences: false) {
                    shown += (shown.isEmpty ? "" : " ") + word
                    continuation.yield(shown)
                    try? await Task.sleep(for: .milliseconds(18))
                }
                continuation.finish()
            }
        }
    }
    #endif
}
