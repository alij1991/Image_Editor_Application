#!/usr/bin/env python3
"""
Phase XVI.65 — convert ZHKKKe/Harmonizer PyTorch weights to ONNX
matching the I/O contract `lib/ai/services/compose_on_bg/
harmonizer_service.dart` expects.

Harmonizer (Ke et al. 2022, ECCV) is a white-box filter regressor:
the network reads a composite + mask, and emits 8 photo-editing
parameters (brightness/contrast/saturation/temperature/tint/
sharpness/highlights/shadows). The Flutter side then either applies
those filters via the existing shader chain, or composes them with
the Reinhard LAB transfer.

The architecture is non-trivial (cascade regressor + dynamic loss),
so this script ASSUMES the user has cloned ZHKKKe/Harmonizer
locally and points us at it via --harmonizer-repo. We import the
upstream `model.HarmonizerEnhancer` directly and `torch.onnx.export`
the regressor head (the enhancer half is filter math we already
implement in Dart).

Source weights:
    https://github.com/ZHKKKe/Harmonizer  (Google Drive link in README)

I/O contract (matches HarmonizerService):
    Input 0: 'composite' [1, 3, 256, 256] float32 ImageNet-normalized
                         (mean=[0.485,0.456,0.406], std=[0.229,0.224,0.225])
    Input 1: 'mask'      [1, 1, 256, 256] float32 in {0, 1}
    Output:  'args'      [1, 8] float32 — filter args.

Usage (from the repo root):
    git clone https://github.com/ZHKKKe/Harmonizer ../Harmonizer
    # Download `harmonizer.pth` per upstream README.
    python scripts/onnx_export/convert_harmonizer.py \\
      --harmonizer-repo ../Harmonizer \\
      --weights ../Harmonizer/pretrained/harmonizer.pth \\
      --output assets/models/bundled/harmonizer_eccv_2022_fp32.onnx
"""
import argparse
import hashlib
import sys
from pathlib import Path

import torch
import torch.nn as nn


def _add_repo_to_path(repo: Path) -> None:
    """Push the upstream ZHKKKe/Harmonizer repo's `src/` directory
    onto PYTHONPATH so `from model import Harmonizer` resolves.

    The upstream layout is:
        Harmonizer/
          src/
            __init__.py
            val_harmonizer.py
            model/
              __init__.py     # re-exports Harmonizer
              harmonizer.py   # class Harmonizer(...)
              enhancer.py
              filter.py
              module.py

    Pushing `<repo>` alone wouldn't work — `model` would resolve to
    `src.model`, not the bare `model` our import expects. Pushing
    `<repo>/src` makes `from model import Harmonizer` succeed via
    the `src/model/__init__.py` re-export.
    """
    if not repo.exists():
        raise SystemExit(
            f"Harmonizer repo not found at {repo}. "
            f"Run `git clone https://github.com/ZHKKKe/Harmonizer "
            f"{repo}` first."
        )
    src_dir = repo / "src"
    if not src_dir.exists():
        raise SystemExit(
            f"Expected {src_dir} (the upstream `src/` directory) but "
            f"it doesn't exist. The repo layout may have changed; "
            f"check github.com/ZHKKKe/Harmonizer."
        )
    sys.path.insert(0, src_dir.as_posix())


class _RegressorWrapper(nn.Module):
    """Thin wrapper that runs ONLY the filter-argument regressor
    head — what the Flutter HarmonizerService consumes. The full
    Harmonizer also includes the white-box filter application step,
    but we re-implement those filters in the Dart shader chain so
    they don't need to ship in the ONNX graph.

    Two upstream-vs-Dart mismatches we have to bridge:

    1. `Harmonizer.predict_arguments` returns a Python LIST of
       per-cascade-head tensors (each shape `[B, 1]`), not a
       single rolled-up tensor. We `torch.cat` along dim=1 to get
       `[B, head_num]`.

    2. The released upstream Harmonizer ships 6 filter types in
       order [TEMPERATURE, BRIGHTNESS, CONTRAST, SATURATION,
       HIGHLIGHT, SHADOW]. The Flutter `HarmonizerArgs` value class
       expects 8 args in order [brightness, contrast, saturation,
       temperature, tint, sharpness, highlights, shadows]. We
       reorder the 6 predicted scalars into the Dart canonical
       slots and zero-fill `tint` + `sharpness` (the model doesn't
       predict either; zero is the identity for both, so the Dart
       chain leaves those axes untouched).
    """

    def __init__(self, harmonizer):
        super().__init__()
        self.harmonizer = harmonizer

    def forward(self, composite, mask):
        per_head = self.harmonizer.predict_arguments(composite, mask)
        # `per_head` is a Python list [t0, t1, ..., t5] of [B, 1] tensors.
        # Roll up via cat → [B, 6] in upstream's filter-type order.
        upstream = torch.cat(list(per_head), dim=1)
        # Reorder to the Dart canonical layout, zero-filling
        # tint + sharpness which the upstream model never predicts.
        # Upstream order: [TEMP, BRIGHT, CONTRAST, SAT, HIGHLIGHT, SHADOW]
        # Dart order:     [bright, contrast, sat, temp, tint, sharp, hi, shad]
        zero = torch.zeros_like(upstream[:, 0:1])
        out = torch.cat(
            (
                upstream[:, 1:2],  # brightness ← upstream[BRIGHT]
                upstream[:, 2:3],  # contrast   ← upstream[CONTRAST]
                upstream[:, 3:4],  # saturation ← upstream[SAT]
                upstream[:, 0:1],  # temperature← upstream[TEMP]
                zero,              # tint       ← 0 (not predicted)
                zero,              # sharpness  ← 0 (not predicted)
                upstream[:, 4:5],  # highlights ← upstream[HIGHLIGHT]
                upstream[:, 5:6],  # shadows    ← upstream[SHADOW]
            ),
            dim=1,
        )
        return out  # [B, 8] matching HarmonizerArgs.fromList


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--harmonizer-repo", type=Path, required=True,
                    help="Path to the cloned ZHKKKe/Harmonizer repo.")
    ap.add_argument("--weights", type=Path, required=True,
                    help="Path to harmonizer.pth (per upstream README, "
                         "this file lives under `pretrained/` in the "
                         "Harmonizer repo).")
    ap.add_argument("--output", type=Path, required=True,
                    help="Destination .onnx path (e.g. "
                         "assets/models/bundled/harmonizer_eccv_2022_fp32.onnx).")
    ap.add_argument("--input-size", type=int, default=256,
                    help="Spatial input dim. Harmonizer was trained "
                         "at 256; do not change unless you have a "
                         "model retrained at the new size.")
    ap.add_argument("--opset", type=int, default=18,
                    help="ONNX opset version. Default 18 — matches "
                         "what PyTorch 2.x's exporter implements "
                         "natively (opset 17 trips an auto-promote "
                         "warning). onnxruntime_v2 on the Flutter "
                         "side supports up to opset 22 today.")
    args = ap.parse_args()

    _add_repo_to_path(args.harmonizer_repo)
    # Lazy import — only succeeds once the repo is on PYTHONPATH.
    from model import Harmonizer  # type: ignore

    print(f"Loading weights from {args.weights}")
    harmonizer = Harmonizer()
    state = torch.load(args.weights, map_location="cpu", weights_only=False)
    if isinstance(state, dict) and "harmonizer" in state:
        state = state["harmonizer"]
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]
    missing, unexpected = harmonizer.load_state_dict(state, strict=False)
    if missing:
        print(f"  WARNING: {len(missing)} missing keys; head[:5]={missing[:5]}")
    if unexpected:
        print(f"  WARNING: {len(unexpected)} unexpected keys; "
              f"head[:5]={unexpected[:5]}")
    harmonizer.eval()

    wrapper = _RegressorWrapper(harmonizer).eval()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    composite = torch.zeros(1, 3, args.input_size, args.input_size,
                            dtype=torch.float32)
    mask = torch.zeros(1, 1, args.input_size, args.input_size,
                       dtype=torch.float32)
    print(f"Exporting → {args.output} (opset={args.opset})")
    torch.onnx.export(
        wrapper,
        (composite, mask),
        args.output.as_posix(),
        input_names=["composite", "mask"],
        output_names=["args"],
        opset_version=args.opset,
        do_constant_folding=True,
        dynamic_axes=None,
    )

    # Smoke test.
    print("Validating with onnxruntime...")
    import onnxruntime as ort
    import numpy as np
    sess = ort.InferenceSession(args.output.as_posix(),
                                providers=["CPUExecutionProvider"])
    out = sess.run(
        None,
        {
            "composite": np.zeros(
                (1, 3, args.input_size, args.input_size), dtype=np.float32),
            "mask": np.zeros(
                (1, 1, args.input_size, args.input_size), dtype=np.float32),
        },
    )[0]
    if out.shape != (1, 8):
        print(f"  FAIL: expected output shape (1, 8), got {out.shape}")
        return 1
    if out.dtype != np.float32:
        print(f"  FAIL: expected float32, got {out.dtype}")
        return 1
    print(f"  OK — output shape {out.shape}, dtype {out.dtype}")

    sha = hashlib.sha256(args.output.read_bytes()).hexdigest()
    size_bytes = args.output.stat().st_size
    print()
    print("=" * 64)
    print("Manifest-pinning values for `harmonizer_eccv_2022` entry:")
    print(f"  sizeBytes: {size_bytes}")
    print(f"  sha256:    {sha}")
    print(f"  assetPath: {args.output.as_posix()}")
    print("=" * 64)
    print("Drop `harmonizer_eccv_2022` from `deferredDownloadables` in "
          "test/ai/manifest_integrity_test.dart and run "
          "`flutter test test/ai/manifest_integrity_test.dart`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
