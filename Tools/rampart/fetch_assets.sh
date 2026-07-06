#!/usr/bin/env bash
#
# Fetch the upstream Rampart model assets (git-LFS objects) into ./_assets.
# See README.md. Requires git-lfs: `brew install git-lfs && git lfs install`.
#
set -euo pipefail
cd "$(dirname "$0")"

REPO="https://github.com/nationaldesignstudio/rampart"
DEST="_assets"

if ! git lfs version >/dev/null 2>&1; then
  echo "ERROR: git-lfs not installed. Run: brew install git-lfs && git lfs install" >&2
  exit 1
fi

rm -rf "$DEST"
git clone --depth 1 "$REPO" "$DEST"
( cd "$DEST" && git lfs pull )

echo ""
echo "Fetched assets:"
ls -la "$DEST/model/onnx/model_q4.onnx" "$DEST/model/vocab.txt" "$DEST/model/config.json"
echo ""
echo "Next: ./convert_to_coreml.py --onnx $DEST/model/onnx/model_q4.onnx --out Rampart.mlpackage"
