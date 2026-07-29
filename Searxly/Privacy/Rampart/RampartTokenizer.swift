//
//  RampartTokenizer.swift
//  Searxly
//
//  BERT WordPiece tokenizer for the Rampart MiniLM token-classifier, plus the
//  fold→locate offset recovery the upstream `classifier.ts` uses to map model
//  tokens back to exact raw character spans.
//
//  The model's `tokenizer_config.json` is a standard BertTokenizer with
//  `do_lower_case: true`, `do_basic_tokenize: true`, `tokenize_chinese_chars: true`.
//  Specials: [PAD]=0, [UNK]=1, [CLS]=2, [SEP]=3, [MASK]=4.
//
//  Offsets are UTF-16 code-unit indices into the raw input, matching the upstream
//  (JS string) coordinate system.
//

import Foundation

nonisolated struct RampartTokenizer {

    nonisolated struct Encoding {
        /// `[CLS]` + content ids + `[SEP]`.
        let inputIds: [Int32]
        /// 1 for every real token (no padding added here; the model layer pads).
        let attentionMask: [Int32]
        /// Content WordPiece tokens (no specials), in folded space, e.g. ["john", "##son"].
        let pieces: [String]
        /// Folded projection of the raw input (for offset recovery).
        let folded: FoldedProjection
    }

    /// A folded copy of the input plus a per-folded-character map back to raw UTF-16 offsets.
    nonisolated struct FoldedProjection {
        let text: String
        let rawStart: [Int]
        let rawEnd: [Int]
    }

    private let vocab: [String: Int32]
    let clsId: Int32
    let sepId: Int32
    let unkId: Int32
    private let unkToken = "[UNK]"
    private let maxInputCharsPerWord = 100

    init(vocab: [String: Int32]) {
        self.vocab = vocab
        self.clsId = vocab["[CLS]"] ?? 2
        self.sepId = vocab["[SEP]"] ?? 3
        self.unkId = vocab["[UNK]"] ?? 1
    }

    /// Load a `vocab.txt` (one token per line; line number = id) from a URL.
    init?(vocabFile url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var vocab: [String: Int32] = [:]
        var id: Int32 = 0
        contents.enumerateLines { line, _ in
            vocab[line] = id
            id += 1
        }
        guard !vocab.isEmpty else { return nil }
        self.init(vocab: vocab)
    }

    // MARK: - Encode

    func encode(_ raw: String) -> Encoding {
        let folded = Self.fold(raw)
        let basicTokens = Self.basicTokenize(folded.text)
        var pieces: [String] = []
        for token in basicTokens {
            pieces.append(contentsOf: wordpiece(token))
        }
        var ids: [Int32] = [clsId]
        ids.append(contentsOf: pieces.map { vocab[$0] ?? unkId })
        ids.append(sepId)
        return Encoding(inputIds: ids,
                        attentionMask: Array(repeating: 1, count: ids.count),
                        pieces: pieces,
                        folded: folded)
    }

    /// Per-token `[start, end)` raw UTF-16 offsets, aligned to the pipeline token index
    /// space (`[CLS]` = 0, content tokens, `[SEP]` last). `[0, 0]` marks an unlocatable
    /// token (e.g. specials or an [UNK]) — a faithful port of `buildTokenIndexOffsets`.
    func tokenIndexOffsets(_ encoding: Encoding) -> [(start: Int, end: Int)] {
        let folded = encoding.folded
        let foldedNS = folded.text as NSString
        var offsets: [(Int, Int)] = [(0, 0)]   // [CLS]
        var cursor = 0
        for token in encoding.pieces {
            let isContinuation = token.hasPrefix("##")
            let piece = isContinuation ? String(token.dropFirst(2)) : token
            let pieceNS = piece as NSString
            guard pieceNS.length > 0 else { offsets.append((0, 0)); continue }
            let searchRange = NSRange(location: cursor, length: foldedNS.length - cursor)
            let at = isContinuation ? cursor
                                    : foldedNS.range(of: piece, options: [], range: searchRange).location
            // Guard NSNotFound (== Int.max) BEFORE any arithmetic on `at`, or `at + length` overflows
            // and traps (SIGTRAP). Conditions short-circuit left-to-right, so the length arithmetic and
            // array bounds are only checked for a real index. A mislocated token becomes unlocatable
            // ((0,0)) — which the pipeline already tolerates — instead of crashing mid-redaction.
            guard at != NSNotFound, at >= 0,
                  at + pieceNS.length <= foldedNS.length,
                  at < folded.rawStart.count,
                  at + pieceNS.length - 1 < folded.rawEnd.count else {
                offsets.append((0, 0))
                continue
            }
            offsets.append((folded.rawStart[at], folded.rawEnd[at + pieceNS.length - 1]))
            cursor = at + pieceNS.length
        }
        offsets.append((0, 0))   // [SEP]
        return offsets
    }

    // MARK: - WordPiece

    /// Greedy longest-match-first WordPiece for one whitespace/punctuation token.
    private func wordpiece(_ token: String) -> [String] {
        let chars = Array(token)
        if chars.count > maxInputCharsPerWord { return [unkToken] }
        var output: [String] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var current: String?
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if vocab[sub] != nil { current = sub; break }
                end -= 1
            }
            guard let piece = current else { return [unkToken] }   // any unmatched span → whole token UNK
            output.append(piece)
            start = end
        }
        return output
    }

    // MARK: - Fold + basic tokenize

    /// Lowercase + NFKD + combining-mark strip (the same fold BERT's BasicTokenizer applies
    /// when do_lower_case=true), recording per folded character the raw UTF-16 range of its
    /// source code point. Port of `foldForModel`.
    static func fold(_ raw: String) -> FoldedProjection {
        var scalars = String.UnicodeScalarView()
        var rawStart: [Int] = []
        var rawEnd: [Int] = []
        var i = 0
        for source in raw.unicodeScalars {
            let sourceLen = source.value > 0xFFFF ? 2 : 1   // source UTF-16 length
            let folded = String(source).lowercased().decomposedStringWithCompatibilityMapping
                .unicodeScalars.filter { !$0.properties.isDiacritic && !isCombiningMark($0) }
            // Most folded letters/digits/punct are BMP (one UTF-16 unit), but a folded scalar can be
            // non-BMP (an emoji or astral CJK that survives folding = two UTF-16 units). `rawStart`/
            // `rawEnd` are indexed later by a UTF-16 offset into the folded NSString, so we add ONE
            // entry per folded UTF-16 code unit — not per scalar — or the arrays fall short of
            // `foldedNS.length` and offset lookups index out of range (crash on emoji-bearing input).
            for scalar in folded {
                scalars.append(scalar)
                let foldedLen = scalar.value > 0xFFFF ? 2 : 1
                for _ in 0..<foldedLen {
                    rawStart.append(i)
                    rawEnd.append(i + sourceLen)
                }
            }
            i += sourceLen
        }
        return FoldedProjection(text: String(scalars), rawStart: rawStart, rawEnd: rawEnd)
    }

    private static func isCombiningMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Whitespace + punctuation split with CJK isolation, over already-folded text. Returns
    /// tokens that are exact substrings of the folded text (punctuation/CJK as their own
    /// tokens) so WordPiece pieces remain locatable for offset recovery.
    static func basicTokenize(_ folded: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        for scalar in folded.unicodeScalars {
            if scalar == " " || CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0 || scalar.value == 0xFFFD {
                flush()
            } else if isPunctuation(scalar) || isCJK(scalar) {
                flush()
                tokens.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return tokens
    }

    /// BERT's punctuation set: all ASCII non-alphanumeric printable + Unicode P* categories.
    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default: return false
        }
    }

    /// CJK ranges that BERT isolates into single-character tokens.
    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
