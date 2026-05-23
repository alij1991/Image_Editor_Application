#!/usr/bin/env python3
"""Re-bake `model.onnx` from onnx-community/BiRefNet_lite-ONNX with
all external-data tensors inlined.

## Why this exists

The community BiRefNet_lite ONNX export at
https://huggingface.co/onnx-community/BiRefNet_lite-ONNX uses
ONNX's "in-memory external data" optimisation — large constant
tensors are stored in a separate section of the same `.onnx` file
rather than inline in the graph protobuf. **ONNX Runtime 1.23.0
has a regression** that can't parse these constants during shape
inference, surfacing as:

    [ShapeInferenceError] Cannot parse data from external tensors.
    Please load external data into raw data for tensor:
    /decoder/Constant_1066_output_0

Upstream PR microsoft/onnxruntime#26263 (merged Oct 2025) fixes
this in ORT 1.23.2. But the Flutter `onnxruntime_v2 1.23.2+2`
package's iOS podspec pins **`onnxruntime-objc (= 1.23.0)`** —
exact pin, so a `pod update` can't pull the fix forward. Until
the package author bumps the pinned version, this script gives
you a model that loads on the buggy 1.23.0 too.

## What this script does

1. Downloads `model.onnx` from the HuggingFace repo (cached via
   `huggingface_hub`).
2. Runs `onnx.load()` + `onnx.save(..., save_as_external_data=
   False)` — same trick `scripts/onnx_export/convert_harmonizer.
   py` uses in XVI.65 to inline torch.onnx's `.onnx.data`
   sidecar.
3. Writes the inlined model to `birefnet_lite_inlined.onnx` in
   the working directory.

## Once you have the inlined file

Two ways to wire it up:

**Self-hosted (recommended for distribution):**
1. Upload the inlined file to a stable URL (your HF account, an
   S3 bucket, a GitHub release).
2. Update `assets/models/manifest.json` `birefnet_lite_fp32.url`
   to point at the new URL.
3. Compute `shasum -a 256 birefnet_lite_inlined.onnx` and pin
   the result in the manifest.
4. Remove `birefnet_lite_fp32` from `deferredDownloadables` in
   `test/ai/manifest_integrity_test.dart`.

**Local override (for testing only):**
1. Place the file at `<AppDocuments>/models/birefnet_lite_fp32_
   1.0-fp32` on your device (replaces what the in-app download
   produced).
2. Edit ModelCache to skip the sha256 check temporarily, or
   compute + pin the hash as above.

## Setup + run

```bash
cd scripts/onnx_export
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python inline_birefnet_lite.py
```

Output: `birefnet_lite_inlined.onnx` in the current directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

import onnx
from huggingface_hub import hf_hub_download

HF_REPO = "onnx-community/BiRefNet_lite-ONNX"
HF_FILE = "onnx/model.onnx"
OUT_FILENAME = "birefnet_lite_inlined.onnx"


def main() -> int:
    print(f"Downloading {HF_FILE} from {HF_REPO} …")
    try:
        cached = hf_hub_download(repo_id=HF_REPO, filename=HF_FILE)
    except Exception as e:
        print(f"FAIL: download failed: {e}", file=sys.stderr)
        return 1
    src = Path(cached)
    print(f"  cached at {src}  ({src.stat().st_size / 1_000_000:.1f} MB)")

    print("Loading model (this materialises any sidecar data)…")
    model = onnx.load(src.as_posix())

    out_path = Path.cwd() / OUT_FILENAME
    print(f"Saving inlined model → {out_path} …")
    onnx.save(model, out_path.as_posix(), save_as_external_data=False)

    size_mb = out_path.stat().st_size / 1_000_000
    print(f"WROTE  {out_path.name}  ({size_mb:.1f} MB)")
    print()
    print("Next steps:")
    print(f"  1. shasum -a 256 {OUT_FILENAME}")
    print("  2. Host the file somewhere stable.")
    print("  3. Update assets/models/manifest.json:")
    print("       - url: <new stable URL>")
    print("       - sizeBytes:", out_path.stat().st_size)
    print("       - sha256: <the shasum value>")
    print("  4. Remove birefnet_lite_fp32 from deferredDownloadables")
    print("     in test/ai/manifest_integrity_test.dart.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
