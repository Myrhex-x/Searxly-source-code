#!/usr/bin/env python3
"""
Convert the Rampart Q4 ONNX token classifier to a Core ML .mlpackage for Searxly.

The shipped model is INT4-quantized ONNX (no float/torch checkpoint is published), so
direct conversion goes ONNX -> torch (onnx2torch) -> Core ML (coremltools). If that path
fails on the quantized ops, prefer shipping the .onnx as-is behind an `ORTRampartModel`
(onnxruntime-swift) instead — the Swift NER pipeline is identical either way.

    pip install coremltools onnx onnx2torch torch numpy
    ./convert_to_coreml.py --onnx _assets/model/onnx/model_q4.onnx --out Rampart.mlpackage

The export targets the contract `CoreMLRampartModel` expects:
    inputs : input_ids, attention_mask   int32  [1, sequence]   (enumerated 1..512)
    output : logits                       float32 [1, sequence, 35]
"""
import argparse
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", required=True, help="path to model_q4.onnx")
    ap.add_argument("--out", default="Rampart.mlpackage", help="output .mlpackage path")
    ap.add_argument("--max-seq", type=int, default=512)
    args = ap.parse_args()

    try:
        import numpy as np
        import torch
        import coremltools as ct
        from onnx2torch import convert as onnx_to_torch
    except ImportError as e:
        print(f"Missing dependency: {e}\n"
              "Run: pip install coremltools onnx onnx2torch torch numpy", file=sys.stderr)
        return 2

    print(f"Loading ONNX → torch: {args.onnx}")
    try:
        torch_model = onnx_to_torch(args.onnx).eval()
    except Exception as e:  # quantized-op conversions can fail here
        print(f"\nONNX→torch conversion failed ({e}).\n"
              "This model is INT4-quantized; fall back to the ONNX Runtime path:\n"
              "  • keep model_q4.onnx as a bundled resource, and\n"
              "  • add `ORTRampartModel: RampartModel` (onnxruntime-swift) in Searxly.\n",
              file=sys.stderr)
        return 1

    # Enumerated sequence lengths keep the model fast for short chat turns while still
    # admitting longer windows up to the model max.
    seq_lengths = [16, 32, 64, 128, 256, args.max_seq]
    ids_shape = ct.EnumeratedShapes(shapes=[[1, n] for n in seq_lengths], default=[1, 64])

    example = (torch.ones(1, 64, dtype=torch.int32), torch.ones(1, 64, dtype=torch.int32))
    traced = torch.jit.trace(torch_model, example)

    print("Converting torch → Core ML…")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=ids_shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=ids_shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = "Rampart PII token classifier (MiniLM, 35 BIO labels)"
    mlmodel.save(args.out)
    print(f"Saved {args.out}")
    print("Add it to the Searxly target, plus vocab.txt → rampart_vocab.txt and "
          "config.json → rampart_config.json. See README.md.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
