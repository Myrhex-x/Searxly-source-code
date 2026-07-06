//
//  RampartNER.swift
//  Searxly
//
//  Contextual PII detection: runs the MiniLM token classifier and turns its per-token
//  BIO logits into entity spans over the raw text. Port of the core of `classifier.ts`
//  (`mergeBioTokens` + offset projection).
//
//  Scope note: this implements the common-case decode — argmax BIO tagging, B/I and
//  WordPiece-continuation grouping, and tokenizer-walk offset recovery. The upstream
//  `repairSpans` niceties (capitalized-particle rescue, connector bridging across
//  initials) and >512-token sliding windows are deliberately deferred; they only refine
//  multi-token name edges and very long inputs, and want the model in the loop to verify.
//

import Foundation

nonisolated enum RampartNER {

    /// Default score floor; spans below it are discarded (recall-biased, per upstream).
    static let defaultMinScore: Float = 0.4
    /// Hard context window of the MiniLM (`max_position_embeddings`), incl. [CLS]/[SEP].
    static let modelMaxTokens = 512

    static func detect(in raw: String,
                       model: RampartModel,
                       tokenizer: RampartTokenizer,
                       labels: RampartLabels,
                       minScore: Float = defaultMinScore) -> [RampartDetection] {
        guard !raw.isEmpty else { return [] }
        var encoding = tokenizer.encode(raw)
        // TODO(windowing): inputs over the model window are truncated rather than scanned
        // as overlapping windows. Chat prompts are almost always well under 512 tokens.
        if encoding.inputIds.count > modelMaxTokens {
            let keep = modelMaxTokens
            let ids = Array(encoding.inputIds.prefix(keep - 1)) + [tokenizer.sepId]
            let mask = Array(repeating: Int32(1), count: ids.count)
            let pieces = Array(encoding.pieces.prefix(keep - 2))
            encoding = RampartTokenizer.Encoding(inputIds: ids, attentionMask: mask,
                                                 pieces: pieces, folded: encoding.folded)
        }

        let logits: [[Float]]
        do { logits = try model.predict(inputIds: encoding.inputIds, attentionMask: encoding.attentionMask) }
        catch { return [] }

        let offsets = tokenizer.tokenIndexOffsets(encoding)
        guard logits.count == encoding.inputIds.count else { return [] }

        let ns = raw as NSString
        var spans: [RampartDetection] = []

        // Grouping state for the current entity.
        var curBase: String?
        var curStart = 0
        var curEnd = 0
        var curScoreSum: Float = 0
        var curCount = 0

        func flush() {
            guard let base = curBase, curCount > 0, curEnd > curStart else { curBase = nil; return }
            let score = curScoreSum / Float(curCount)
            if base != "O", score >= minScore,
               curStart >= 0, curEnd <= ns.length {
                spans.append(RampartDetection(start: curStart, end: curEnd, label: base,
                                              score: score, source: .ner,
                                              text: ns.substring(with: NSRange(location: curStart, length: curEnd - curStart))))
            }
            curBase = nil
        }

        // Content tokens occupy index 1 ..< (count - 1); pieces[i-1] is the token text.
        for i in 1..<(encoding.inputIds.count - 1) {
            let (best, score) = argmaxSoftmax(logits[i])
            let raw = labels.label(best)
            let (prefix, base) = Self.stripBio(raw)
            let (start, end) = offsets[i]
            let isContinuation = encoding.pieces[i - 1].hasPrefix("##")

            if base == "O" || (start == 0 && end == 0) {
                flush()
                continue
            }
            let continues = curBase == base && (prefix != "B" || isContinuation)
            if continues {
                curEnd = end
                curScoreSum += score
                curCount += 1
            } else {
                flush()
                curBase = base
                curStart = start
                curEnd = end
                curScoreSum = score
                curCount = 1
            }
        }
        flush()
        return spans
    }

    /// Strip a BIO prefix: `B-GIVEN_NAME`/`I-GIVEN_NAME` → `GIVEN_NAME`; bare labels pass through.
    static func stripBio(_ label: String) -> (prefix: String?, base: String) {
        if label.hasPrefix("B-") { return ("B", String(label.dropFirst(2))) }
        if label.hasPrefix("I-") { return ("I", String(label.dropFirst(2))) }
        return (nil, label)
    }

    /// Argmax label id and its softmax probability.
    private static func argmaxSoftmax(_ logits: [Float]) -> (index: Int, score: Float) {
        guard let maxLogit = logits.max() else { return (0, 0) }
        var bestIdx = 0
        var bestVal = -Float.greatestFiniteMagnitude
        var sumExp: Float = 0
        for (i, v) in logits.enumerated() {
            let e = expf(v - maxLogit)
            sumExp += e
            if v > bestVal { bestVal = v; bestIdx = i }
        }
        let prob = sumExp > 0 ? expf(bestVal - maxLogit) / sumExp : 0
        return (bestIdx, prob)
    }
}
