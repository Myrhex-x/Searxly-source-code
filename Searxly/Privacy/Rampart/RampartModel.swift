//
//  RampartModel.swift
//  Searxly
//
//  The model-runtime seam. `RampartModel` abstracts "given token ids, return per-token
//  logits" so the NER layer is independent of how the MiniLM actually runs.
//
//  The shipped backend is **ONNX Runtime** (native, in-process, no JS/browser). Rampart's
//  weights are published *only* as a 14.7 MB INT4-quantized ONNX whose `com.microsoft`
//  quantization ops can't be expressed in Core ML, so ORT — the same engine transformers.js
//  uses under the hood — is the correct native path. The protocol keeps a Core ML backend
//  possible later if a float export ever appears.
//
//  Assets live in the app bundle (Rampart.onnx + rampart_vocab.txt + rampart_config.json).
//  `RampartModelLoader` returns nil when they're absent, so the redactor degrades to the
//  heuristic layer.
//

import Foundation
import os
import OnnxRuntimeBindings

/// Produces per-token logits for a tokenized sequence. `inputIds`/`attentionMask` include
/// the [CLS]/[SEP] specials. Returns `[seqLen][numLabels]`.
nonisolated protocol RampartModel {
    var numLabels: Int { get }
    func predict(inputIds: [Int32], attentionMask: [Int32]) throws -> [[Float]]
}

/// The `id2label` map from the model's `config.json` (35 BIO labels for 17 entity types).
nonisolated struct RampartLabels {
    let id2label: [Int: String]
    var count: Int { id2label.count }

    func label(_ id: Int) -> String { id2label[id] ?? "O" }

    /// Parse a HF `config.json` for its `id2label` table.
    init?(configFile url: URL) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["id2label"] as? [String: String] else { return nil }
        var map: [Int: String] = [:]
        for (k, v) in raw { if let id = Int(k) { map[id] = v } }
        guard !map.isEmpty else { return nil }
        self.id2label = map
    }

    init(id2label: [Int: String]) { self.id2label = id2label }
}

nonisolated enum RampartModelError: Error {
    case missingOutput(String)
    case badOutputShape
}

// MARK: - ONNX Runtime backend

/// Runs the bundled `Rampart.onnx` token classifier via ONNX Runtime. The model expects three
/// int64 inputs `input_ids` / `attention_mask` / `token_type_ids` shaped `[1, seq]` and emits
/// `logits` float32 `[1, seq, numLabels]` (verified against the published model's graph).
nonisolated final class ORTRampartModel: RampartModel {
    private let env: ORTEnv
    private let session: ORTSession
    let numLabels: Int
    private let inputIdsName: String
    private let maskName: String
    private let tokenTypeName: String
    private let logitsName: String

    init(modelPath: String,
         numLabels: Int,
         inputIdsName: String = "input_ids",
         maskName: String = "attention_mask",
         tokenTypeName: String = "token_type_ids",
         logitsName: String = "logits") throws {
        self.env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
        self.numLabels = numLabels
        self.inputIdsName = inputIdsName
        self.maskName = maskName
        self.tokenTypeName = tokenTypeName
        self.logitsName = logitsName
    }

    func predict(inputIds: [Int32], attentionMask: [Int32]) throws -> [[Float]] {
        let seq = inputIds.count
        let shape: [NSNumber] = [1, NSNumber(value: seq)]

        func tensor(_ values: [Int64]) throws -> ORTValue {
            let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.stride)
            return try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.int64, shape: shape)
        }

        let inputs: [String: ORTValue] = [
            inputIdsName: try tensor(inputIds.map(Int64.init)),
            maskName: try tensor(attentionMask.map(Int64.init)),
            tokenTypeName: try tensor([Int64](repeating: 0, count: seq)),   // single sequence
        ]

        let outputs = try session.run(withInputs: inputs,
                                      outputNames: Set([logitsName]),
                                      runOptions: nil)
        guard let logits = outputs[logitsName] else { throw RampartModelError.missingOutput(logitsName) }

        let raw = try logits.tensorData() as Data
        let count = seq * numLabels
        guard raw.count >= count * MemoryLayout<Float>.stride else { throw RampartModelError.badOutputShape }
        let flat: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }

        var result = [[Float]](repeating: [Float](repeating: 0, count: numLabels), count: seq)
        for t in 0..<seq {
            let base = t * numLabels
            for l in 0..<numLabels { result[t][l] = flat[base + l] }
        }
        return result
    }
}

// MARK: - Bundle loading

/// Assembles a model + tokenizer + labels from app-bundle resources, or nil if the optional
/// ML assets aren't bundled (heuristic-only mode).
nonisolated enum RampartModelLoader {
    nonisolated struct Loaded {
        let model: RampartModel
        let tokenizer: RampartTokenizer
        let labels: RampartLabels
    }

    static func loadBundled(bundle: Bundle = .main) -> Loaded? {
        guard let modelURL = bundle.url(forResource: "Rampart", withExtension: "onnx"),
              let vocabURL = bundle.url(forResource: "rampart_vocab", withExtension: "txt"),
              let configURL = bundle.url(forResource: "rampart_config", withExtension: "json"),
              let tokenizer = RampartTokenizer(vocabFile: vocabURL),
              let labels = RampartLabels(configFile: configURL) else {
            return nil
        }
        do {
            let model = try ORTRampartModel(modelPath: modelURL.path, numLabels: labels.count)
            return Loaded(model: model, tokenizer: tokenizer, labels: labels)
        } catch {
            Log.privacy.error("Rampart: ONNX session init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
