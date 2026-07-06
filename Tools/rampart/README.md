# Rampart on-device PII redaction — model assets

Searxly ships a **native Swift port** of National Design Studio's
[Rampart](https://github.com/nationaldesignstudio/rampart) PII redactor (CC BY 4.0).
It scrubs personal information from prompts before they reach the **Searxly AI cloud**
backend and restores it in the reply on-device. See `Searxly/Privacy/Rampart/`.

Two layers, **both live**:

| Layer | What it catches | How it runs |
|-------|-----------------|-------------|
| **Heuristic** (`DeterministicDetectors`) | SSN, credit card (Luhn), IP/MAC, email, URL | pure Swift, always on |
| **NER model** (`ORTRampartModel`) | names, phone, address lines, tax/bank/gov IDs, passport, license | 14.7 MB Q4 ONNX via **ONNX Runtime**, in-process |

## Why ONNX Runtime, not Core ML

Rampart's weights are published **only** as an INT4-quantized ONNX (`onnx/model_q4.onnx`)
whose `com.microsoft` quantization ops (MatMulNBits) have no Core ML equivalent, and there
is no float checkpoint to convert from. ONNX Runtime — the same engine transformers.js uses
under the hood — runs the file as-is, natively and in-process (no JS, no browser). The
`RampartModel` protocol keeps a Core ML backend possible if a float export ever appears.

## What's already wired

- **SPM dependency**: `microsoft/onnxruntime-swift-package-manager` (product `onnxruntime`,
  module `OnnxRuntimeBindings`), added to `Searxly.xcodeproj`.
- **Bundled assets** in `Searxly/Privacy/Rampart/Resources/` (auto-included by the
  file-system-synchronized group):
  - `Rampart.onnx` — the 14.7 MB Q4 model
  - `rampart_vocab.txt` — 19,730 WordPiece vocab
  - `rampart_config.json` — `id2label` (35 BIO labels)
- `RampartModelLoader.loadBundled()` builds an `ORTRampartModel`; if any asset is missing it
  returns nil and the engine logs `heuristic-only redaction` and degrades gracefully.

## Refreshing the assets (if NDS ships a new model)

```bash
./fetch_assets.sh    # pulls model_q4.onnx + vocab.txt + config.json from Hugging Face
```

`fetch_assets.sh` downloads over plain HTTPS from
`huggingface.co/nationaldesignstudio/rampart` (no git-lfs needed) into `./_assets`, then copy:

| From | To (bundle resource) |
|------|----------------------|
| `_assets/onnx/model_q4.onnx` | `Searxly/Privacy/Rampart/Resources/Rampart.onnx` |
| `_assets/vocab.txt` | `Searxly/Privacy/Rampart/Resources/rampart_vocab.txt` |
| `_assets/config.json` | `Searxly/Privacy/Rampart/Resources/rampart_config.json` |

The model's expected tensor I/O (kept in sync with `ORTRampartModel`): int64 `input_ids`,
`attention_mask`, `token_type_ids` shaped `[1, seq]` → float32 `logits` `[1, seq, 35]`.

> Note: the committed `Rampart.onnx` is a 14.7 MB binary. Consider git-LFS for it if repo
> size matters. `convert_to_coreml.py` is retained only for a hypothetical future float export;
> it is **not** the shipping path.

## Deferred (tracked, not blocking)

- Sliding **token windows** for inputs over 512 tokens (`RampartNER` currently truncates;
  chat turns are almost always well under the window).
- Upstream `repairSpans` niceties (capitalized-particle rescue, connector bridging across
  initials) — only refine multi-token name edges.
- **Premask** of structured spans before the model (we run NER on raw text; heuristic spans
  still win the merge, so correctness holds).
- A parity harness vs the upstream JS reference over a labeled PII corpus.
