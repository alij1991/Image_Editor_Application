#!/usr/bin/env python3
"""Generalised ONNX inliner — works for ANY model that triggers the
ORT 1.23.0 in-memory external-data regression.

## When you need this

OrtRuntime's two-pass loader (XVI.70) catches the "Cannot parse data
from external tensors" error and retries with graph optimisation
disabled, which gets most affected models loading. If that retry
ALSO fails, or if you want to ship the model in the optimised path,
re-bake it with this script.

The trick is the same as `scripts/onnx_export/convert_harmonizer.py`
uses for torch.onnx's `.onnx.data` sidecars (XVI.65):

  ```
  model = onnx.load(src.as_posix())
  onnx.save(model, dst.as_posix(), save_as_external_data=False)
  ```

Result is a single .onnx file with all constants inlined into the
graph protobuf. Loads on any ORT version because there are no
external references to parse.

## Usage

By HuggingFace repo + file:

    python inline_onnx_model.py \
      --repo onnx-community/BiRefNet_lite-ONNX \
      --file onnx/model.onnx \
      --out birefnet_lite_inlined.onnx

By direct URL (GitHub release, S3, anywhere wget can reach):

    python inline_onnx_model.py \
      --url https://github.com/.../model.onnx \
      --out my_inlined.onnx

By already-downloaded local file:

    python inline_onnx_model.py \
      --in /path/to/model.onnx \
      --out /path/to/inlined.onnx

## Output

A single `.onnx` file at the path passed via `--out`. Script then
prints the shasum + size + the manifest snippet to update:

    sha256 = abcd1234...
    sizeBytes = 224005088
    Suggested manifest update:
      "sha256": "abcd1234...",
      "sizeBytes": 224005088,
      "url": "<your new host URL>"

## Setup

```bash
cd scripts/onnx_export
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Only needs `onnx` + `huggingface_hub` (both already pinned in
requirements.txt).
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

import onnx


def fetch_via_hf(repo: str, filename: str) -> Path:
    from huggingface_hub import hf_hub_download
    print(f"Fetching {filename} from HF repo {repo} …")
    cached = hf_hub_download(repo_id=repo, filename=filename)
    return Path(cached)


def fetch_via_url(url: str) -> Path:
    print(f"Downloading {url} …")
    tmp = Path(tempfile.mkstemp(suffix=".onnx")[1])
    with urllib.request.urlopen(url) as resp, open(tmp, "wb") as out:
        shutil.copyfileobj(resp, out)
    print(f"  → {tmp}  ({tmp.stat().st_size / 1_000_000:.1f} MB)")
    return tmp


def inline(src: Path, dst: Path) -> None:
    print(f"Loading {src.name} …")
    model = onnx.load(src.as_posix())
    print(f"Saving inlined model → {dst} …")
    onnx.save(model, dst.as_posix(), save_as_external_data=False)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--repo", help="HuggingFace repo id")
    src.add_argument("--url", help="Direct download URL")
    src.add_argument("--in", dest="local", help="Already-downloaded .onnx")
    p.add_argument("--file", help="Filename inside the HF repo (with --repo)")
    p.add_argument("--out", required=True, help="Output path for inlined .onnx")
    args = p.parse_args()

    out = Path(args.out).resolve()

    if args.repo:
        if not args.file:
            print("FAIL: --repo also needs --file (path inside the repo)",
                  file=sys.stderr)
            return 2
        src_path = fetch_via_hf(args.repo, args.file)
    elif args.url:
        src_path = fetch_via_url(args.url)
    else:
        src_path = Path(args.local).resolve()
        if not src_path.exists():
            print(f"FAIL: {src_path} not found", file=sys.stderr)
            return 1

    try:
        inline(src_path, out)
    except Exception as e:
        print(f"FAIL: onnx.save failed: {e}", file=sys.stderr)
        return 1

    size = out.stat().st_size
    digest = sha256(out)
    print()
    print(f"WROTE  {out}")
    print(f"  sizeBytes = {size}")
    print(f"  sha256    = {digest}")
    print()
    print("Suggested manifest snippet:")
    print(f'  "sha256":    "{digest}",')
    print(f'  "sizeBytes": {size},')
    print('  "url":       "<your new host URL>"')
    print()
    print("Then remove the model id from `deferredDownloadables` in")
    print("test/ai/manifest_integrity_test.dart and re-run that test.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
