//
//  RampartRedactionTests.swift
//  SearxlyTests
//
//  Pins the native Rampart port: heuristic detectors (digit-run + text rules with the
//  Luhn / SSN validators), the merge/keep-set policy, the scrub/rehydrate session table,
//  the streaming reveal (placeholders split across SSE chunks), and the WordPiece
//  tokenizer + fold→locate offset recovery. The ML NER layer is exercised separately
//  once the model asset is bundled; everything here runs model-free.
//

import XCTest
@testable import Searxly

final class RampartRedactionTests: XCTestCase {

    // MARK: - Helpers

    /// A detection for the first occurrence of `sub` in `raw` (UTF-16 offsets).
    private func det(_ raw: String, _ sub: String, _ label: String,
                     _ source: RampartSource = .ner, _ score: Float = 0.9) -> RampartDetection {
        let ns = raw as NSString
        let r = ns.range(of: sub)
        return RampartDetection(start: r.location, end: r.location + r.length,
                                label: label, score: score, source: source, text: sub)
    }

    private func labels(_ ds: [RampartDetection]) -> [String] { ds.map(\.label) }

    // MARK: - Heuristic detectors

    func testEmailDetected() {
        let hits = DeterministicDetectors.detect(in: "ping jane.doe+x@example.co.uk please")
        XCTAssertEqual(hits.filter { $0.label == "EMAIL" }.first?.text, "jane.doe+x@example.co.uk")
    }

    func testURLDetectedNotTrimmed() {
        // Upstream intentionally leaves trailing sentence punctuation in the URL span.
        let hits = DeterministicDetectors.detect(in: "see https://example.com/path.")
        XCTAssertEqual(hits.first { $0.label == "URL" }?.text, "https://example.com/path.")
        XCTAssertEqual(DeterministicDetectors.detect(in: "go to www.example.com/x now").first { $0.label == "URL" }?.text,
                       "www.example.com/x")
    }

    func testIPv4ValidatedOctets() {
        XCTAssertEqual(DeterministicDetectors.detect(in: "host 192.168.1.254").first?.text, "192.168.1.254")
        XCTAssertTrue(DeterministicDetectors.detect(in: "build 999.1.1.1 here").filter { $0.label == "IP_ADDRESS" }.isEmpty)
    }

    func testIPv6AndMAC() {
        XCTAssertEqual(DeterministicDetectors.detect(in: "addr 2001:db8::1 ok").first { $0.label == "IP_ADDRESS" }?.text, "2001:db8::1")
        XCTAssertEqual(DeterministicDetectors.detect(in: "mac 00:1A:2B:3C:4D:5E end").first { $0.label == "IP_ADDRESS" }?.text, "00:1A:2B:3C:4D:5E")
    }

    func testSSNStructuralValidation() {
        // Dashed, spaced, and bare 9-digit all detect when structurally valid.
        XCTAssertEqual(DeterministicDetectors.detect(in: "ssn 523-45-6789 x").first?.label, "SSN")
        XCTAssertEqual(DeterministicDetectors.detect(in: "ssn 523456789 x").first?.label, "SSN")
        // Invalid area (666 / >=900) is rejected — no SSN span.
        XCTAssertTrue(DeterministicDetectors.detect(in: "ssn 666-45-6789 x").filter { $0.label == "SSN" }.isEmpty)
        XCTAssertTrue(DeterministicDetectors.detect(in: "ssn 900-45-6789 x").filter { $0.label == "SSN" }.isEmpty)
    }

    func testCreditCardLuhnAndLengths() {
        XCTAssertEqual(DeterministicDetectors.detect(in: "card 4111 1111 1111 1111 ok").first?.label, "CREDIT_CARD")  // 16
        XCTAssertEqual(DeterministicDetectors.detect(in: "amex 3782 822463 10005 ok").first?.label, "CREDIT_CARD")    // 15
        // Broken Luhn → not a card.
        XCTAssertTrue(DeterministicDetectors.detect(in: "card 4111 1111 1111 1112 ok").filter { $0.label == "CREDIT_CARD" }.isEmpty)
        // 13 digits is outside the {16,15,14} length set even though Luhn-valid.
        XCTAssertTrue(DeterministicDetectors.detect(in: "n 4222222222222 z").filter { $0.label == "CREDIT_CARD" }.isEmpty)
    }

    func testValidatorUnits() {
        XCTAssertTrue(DeterministicDetectors.luhnValid("4111111111111111"))
        XCTAssertFalse(DeterministicDetectors.luhnValid("4111111111111112"))
        XCTAssertTrue(DeterministicDetectors.isValidSsn("523456789"))
        XCTAssertFalse(DeterministicDetectors.isValidSsn("666456789"))
        XCTAssertFalse(DeterministicDetectors.isValidSsn("12345"))
    }

    // MARK: - Policy

    func testMergeSpansUnionsPartialOverlap() {
        // Two partially overlapping spans of the same label → byte-union.
        let raw = "abcdefgh"
        let a = RampartDetection(start: 0, end: 4, label: "URL", score: 1, source: .heuristic, text: "abcd")
        let b = RampartDetection(start: 2, end: 6, label: "URL", score: 1, source: .heuristic, text: "cdef")
        let merged = RampartPolicy.mergeSpans([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 6)
        _ = raw
    }

    func testApplyPolicyDropsKeepSet() {
        let raw = "Mary in Denver"
        let spans = [det(raw, "Mary", "GIVEN_NAME"), det(raw, "Denver", "CITY")]
        let kept = RampartPolicy.applyPolicy(spans, keepLabels: RampartEntity.defaultKeep)
        XCTAssertEqual(labels(kept), ["GIVEN_NAME"])   // CITY is kept (not redacted)
    }

    // MARK: - Session scrub / rehydrate

    func testScrubHidesAndRehydrate() {
        let raw = "Email jane@example.com or SSN 523-45-6789"
        let session = RampartSession()
        let (scrubbed, placeholders) = session.scrub(raw, spans: DeterministicDetectors.detect(in: raw))
        XCTAssertEqual(placeholders.count, 2)
        XCTAssertFalse(scrubbed.contains("jane@example.com"))
        XCTAssertFalse(scrubbed.contains("523-45-6789"))
        XCTAssertTrue(scrubbed.contains("[EMAIL_1]"))
        XCTAssertTrue(scrubbed.contains("[SSN_1]"))
        XCTAssertEqual(session.rehydrate(scrubbed), raw)
    }

    func testDedupeByNormalizedValue() {
        // "John" and "john " normalize equal → one placeholder reused.
        let raw = "John met john."
        let session = RampartSession()
        let (scrubbed, _) = session.scrub(raw, spans: [
            det(raw, "John", "GIVEN_NAME"),
            RampartDetection(start: (raw as NSString).range(of: "john").location,
                             end: (raw as NSString).range(of: "john").location + 4,
                             label: "GIVEN_NAME", score: 0.9, source: .ner, text: "john"),
        ])
        XCTAssertEqual(scrubbed, "[GIVEN_NAME_1] met [GIVEN_NAME_1].")
    }

    func testNumberingFollowsScrubOrder() {
        // Faithful to upstream: applyPolicy sorts right-to-left, so the rightmost span
        // mints _1. (Cosmetic; round-trip is what matters.)
        let raw = "John and Mary"
        let session = RampartSession()
        let (scrubbed, _) = session.scrub(raw, spans: [
            det(raw, "John", "GIVEN_NAME"), det(raw, "Mary", "GIVEN_NAME"),
        ])
        XCTAssertEqual(scrubbed, "[GIVEN_NAME_2] and [GIVEN_NAME_1]")
        XCTAssertEqual(session.rehydrate(scrubbed), raw)
    }

    func testCityKeptInScrub() {
        let raw = "I live in Denver"
        let session = RampartSession()
        let (scrubbed, placeholders) = session.scrub(raw, spans: [det(raw, "Denver", "CITY")])
        XCTAssertEqual(scrubbed, raw)
        XCTAssertTrue(placeholders.isEmpty)
    }

    // MARK: - Streaming reveal

    private func streamingSession() -> RampartSession {
        let raw = "I'm Jane Doe"
        let session = RampartSession()
        _ = session.scrub(raw, spans: [det(raw, "Jane", "GIVEN_NAME"), det(raw, "Doe", "SURNAME")])
        return session
    }

    func testRevealAcrossChunkBoundaries() {
        let session = streamingSession()
        // GIVEN_NAME_1 / SURNAME_1 minted right-to-left → Doe=_1(SURNAME), Jane=_1(GIVEN_NAME).
        let transform = session.makeRevealTransform()
        let chunks = ["Hi [GIVEN", "_NAME_1] ", "[SURNAME_1]", "!"]
        var out = ""
        for c in chunks { out += transform.push(c) }
        out += transform.finish()
        XCTAssertEqual(out, "Hi Jane Doe!")
    }

    func testRevealMatchesWholeReveal() {
        let session = streamingSession()
        let reply = "Sure [GIVEN_NAME_1], and [SURNAME_1] too, [GIVEN_NAME_1]."
        let transform = session.makeRevealTransform()
        var streamed = ""
        for ch in reply { streamed += transform.push(String(ch)) }
        streamed += transform.finish()
        XCTAssertEqual(streamed, session.rehydrate(reply))
        XCTAssertFalse(streamed.contains("GIVEN_NAME"))
    }

    func testRevealPassesMarkdownLinks() {
        let session = RampartSession()   // empty map → reveal is identity
        let transform = session.makeRevealTransform()
        var out = ""
        out += transform.push("see [the docs](http")
        out += transform.push("s://x.com) now")
        out += transform.finish()
        XCTAssertEqual(out, "see [the docs](https://x.com) now")
    }

    // MARK: - Guard (end-to-end, heuristic-only)

    func testGuardProtectRevealRoundTrip() async {
        let guardSession = RampartRedactor.shared.newSession()
        let (protectedText, count, _) = await guardSession.protect("Reach me at a.b@c.com today")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(protectedText.contains("[EMAIL_1]"))
        XCTAssertFalse(protectedText.contains("a.b@c.com"))
        XCTAssertEqual(guardSession.reveal(protectedText), "Reach me at a.b@c.com today")
    }

    // MARK: - Tokenizer (synthetic vocab)

    private func miniTokenizer() -> RampartTokenizer {
        var vocab: [String: Int32] = [:]
        let tokens = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]",
                      "john", "##son", "lives", "in", "paris", "jose", ".", "@"]
        for (i, t) in tokens.enumerated() { vocab[t] = Int32(i) }
        return RampartTokenizer(vocab: vocab)
    }

    func testTokenizerWordPieceAndIds() {
        let tok = miniTokenizer()
        let enc = tok.encode("Johnson lives in Paris.")
        XCTAssertEqual(enc.pieces, ["john", "##son", "lives", "in", "paris", "."])
        // [CLS] john ##son lives in paris . [SEP]
        XCTAssertEqual(enc.inputIds, [2, 5, 6, 7, 8, 9, 11, 3])
    }

    func testTokenizerOffsetRecovery() {
        let tok = miniTokenizer()
        let raw = "Johnson lives in Paris."
        let enc = tok.encode(raw)
        let offsets = tok.tokenIndexOffsets(enc)   // index 0 = [CLS]
        let ns = raw as NSString
        // token 1 = "john" → "John"; token 2 = "##son" → "son".
        XCTAssertEqual(ns.substring(with: NSRange(location: offsets[1].start, length: offsets[1].end - offsets[1].start)), "John")
        XCTAssertEqual(ns.substring(with: NSRange(location: offsets[2].start, length: offsets[2].end - offsets[2].start)), "son")
        // "paris" → "Paris" (token index 5).
        XCTAssertEqual(ns.substring(with: NSRange(location: offsets[5].start, length: offsets[5].end - offsets[5].start)), "Paris")
    }

    func testTokenizerAccentFolding() {
        let tok = miniTokenizer()
        let raw = "José"   // folds to "jose"; offset must still cover the accented original
        let enc = tok.encode(raw)
        XCTAssertEqual(enc.pieces, ["jose"])
        let offsets = tok.tokenIndexOffsets(enc)
        let ns = raw as NSString
        XCTAssertEqual(offsets[1].start, 0)
        XCTAssertEqual(offsets[1].end, ns.length)   // covers "José"
    }

    // MARK: - Native ML NER (requires the bundled ONNX model)

    func testNativeModelDetectsPersonName() throws {
        guard let loaded = RampartModelLoader.loadBundled() else {
            throw XCTSkip("Rampart ONNX model not bundled — heuristic-only build")
        }
        let raw = "My name is John Smith and my email is john@example.com."
        let spans = RampartNER.detect(in: raw, model: loaded.model, tokenizer: loaded.tokenizer, labels: loaded.labels)
        let names = spans.filter { $0.label == "GIVEN_NAME" || $0.label == "SURNAME" }
        XCTAssertFalse(names.isEmpty,
                       "model should tag the person name; got: \(spans.map { "\($0.label):\($0.text)" })")
        let joined = names.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("John") || joined.contains("Smith"), "name spans were: \(joined)")
    }

    func testGuardRedactsNameWhenModelBundled() async throws {
        guard await RampartRedactor.shared.modelAvailable() else {
            throw XCTSkip("Rampart ONNX model not bundled — heuristic-only build")
        }
        let session = RampartRedactor.shared.newSession()
        let original = "My name is John Smith, email john@example.com"
        let (scrubbed, count, summary) = await session.protect(original)
        XCTAssertTrue(summary.contains("GIVEN_NAME") || summary.contains("SURNAME"), "summary: \(summary)")
        XCTAssertFalse(scrubbed.contains("John Smith"), "name should be redacted; got: \(scrubbed)")
        XCTAssertFalse(scrubbed.contains("john@example.com"), "email should be redacted; got: \(scrubbed)")
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertEqual(session.reveal(scrubbed), original)   // round-trips back to the real text
    }

    /// A one/two-character "name" (the "In" in "Sign In") is an NER false positive and must never be
    /// redacted — regardless of the model's confidence — via the short-name guard.
    func testShortWordNeverRedactedAsName() {
        XCTAssertTrue(RampartNER.isLowValueNameSpan(base: "GIVEN_NAME", text: "In"))
        XCTAssertTrue(RampartNER.isLowValueNameSpan(base: "SURNAME", text: "It"))
        XCTAssertFalse(RampartNER.isLowValueNameSpan(base: "GIVEN_NAME", text: "John"))
        XCTAssertFalse(RampartNER.isLowValueNameSpan(base: "EMAIL", text: "hi"))   // guard is names-only
    }

    /// The over-redaction fix: the Agentic Tools threshold (0.75) + short-name guard stop mangling
    /// public/company names and common words in search results, while still redacting a real full name
    /// and always redacting deterministic identifiers (email).
    func testAgenticThresholdReducesOverRedaction() async throws {
        guard await RampartRedactor.shared.modelAvailable() else {
            throw XCTSkip("Rampart ONNX model not bundled — heuristic-only build")
        }
        let keep: Set<String> = [RampartEntity.url.rawValue, RampartEntity.city.rawValue,
                                 RampartEntity.state.rawValue, RampartEntity.zipCode.rawValue]
        let text = "Anthropic Claude AI. Please Sign In to your account. Contact John Smith at john@example.com."

        let loose = await RampartRedactor.shared.newSession(keepLabels: keep).protect(text)                // 0.4 default
        let strict = await RampartRedactor.shared.newSession(keepLabels: keep, minScore: 0.75).protect(text)
        print("[Rampart] loose(0.4):   \(loose.text)")
        print("[Rampart] strict(0.75): \(strict.text)")

        // "In" must survive (short-name guard) at the stricter threshold.
        XCTAssertTrue(strict.text.contains("Sign In"), "the word 'In' must not be redacted: \(strict.text)")
        // Deterministic email is redacted no matter the threshold.
        XCTAssertFalse(strict.text.contains("john@example.com"), "email must still be redacted")
        XCTAssertTrue(strict.text.contains("[EMAIL_1]"))
        // A real full name is still caught at the higher threshold (we did not over-correct).
        XCTAssertFalse(strict.text.contains("John Smith"), "a real full name is still redacted: \(strict.text)")
        // The stricter pass never redacts MORE than the loose one.
        XCTAssertLessThanOrEqual(strict.count, loose.count)
    }

    /// Regression: non-BMP characters (emoji, astral CJK) are two UTF-16 units each, which used to
    /// misalign the folded-offset arrays and trap ("Index out of range") mid-redaction — crashing the
    /// whole app on ordinary web content. The tokenizer must map offsets without trapping.
    func testTokenizerHandlesNonBMPWithoutCrash() throws {
        guard let loaded = RampartModelLoader.loadBundled() else {
            throw XCTSkip("Rampart ONNX model not bundled — heuristic-only build")
        }
        let raw = "Hi 👋 world 🌍 John Smith 😀 lives near 𠀀 test 🇺🇸 end."
        let encoding = loaded.tokenizer.encode(raw)
        let offsets = loaded.tokenizer.tokenIndexOffsets(encoding)   // must not trap
        XCTAssertEqual(offsets.count, encoding.pieces.count + 2)     // [CLS] + pieces + [SEP]
        let n = (raw as NSString).length
        for (s, e) in offsets {
            XCTAssertTrue(s >= 0 && s <= e && e <= n, "offset (\(s),\(e)) outside [0,\(n)]")
        }
    }

    /// Regression at the full-redaction level: emoji-bearing content that would previously crash the
    /// app now scrubs cleanly (name + email redacted, no trap).
    func testRedactionSurvivesEmojiContent() async throws {
        guard await RampartRedactor.shared.modelAvailable() else {
            throw XCTSkip("Rampart ONNX model not bundled — heuristic-only build")
        }
        let text = "Update from John Smith 😀🌍 — email john@example.com 👋 thanks"
        let (scrubbed, count, _) = await RampartRedactor.shared.newSession().protect(text)   // must not crash
        XCTAssertFalse(scrubbed.contains("john@example.com"), "email redacted; got: \(scrubbed)")
        XCTAssertGreaterThanOrEqual(count, 1)
    }
}
