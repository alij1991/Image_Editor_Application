#!/usr/bin/env python3
"""
Phase XVI.65 — convert chiutaiyin/PhotoWCT2 PyTorch checkpoints to
ONNX matching the I/O contract `lib/ai/services/style_transfer/
photo_wct_service.dart` expects.

PhotoWCT2 (Chiu & Gurari, WACV 2022) is a compact autoencoder for
photoreal style transfer. It uses a fixed VGG-19 encoder + a
blockwise-trained decoder; the WCT (whitening-coloring transform)
sits at the bottleneck and matches the content's covariance to the
style's.

The architecture is upstream-specific so this script ASSUMES the
user has cloned chiutaiyin/PhotoWCT2 locally. Two model variants
exist: `conv` (VGG conv4-1) and `relu` (VGG relu4-1). Default to
`conv`; the relu variant produces slightly stronger color matching.

Source weights:
    https://github.com/chiutaiyin/PhotoWCT2  (ckpts/ckpts-conv etc.)

I/O contract (matches PhotoWctService):
    Input 0: 'content' [1, 3, 512, 512] float32 in [0, 1]
    Input 1: 'style'   [1, 3, 512, 512] float32 in [0, 1]
    Output:  'output'  [1, 3, 512, 512] float32 in [0, 1]
                       — photoreal stylised content.

Usage (from the repo root):
    git clone https://github.com/chiutaiyin/PhotoWCT2 ../PhotoWCT2
    python scripts/onnx_export/convert_photo_wct2.py \\
      --photowct2-repo ../PhotoWCT2 \\
      --variant conv \\
      --output assets/models/bundled/photo_wct2_conv_fp32.onnx
"""
import argparse
import hashlib
import sys
from pathlib import Path

import torch
import torch.nn as nn


def _add_repo_to_path(repo: Path) -> None:
    if not repo.exists():
        raise SystemExit(
            f"PhotoWCT2 repo not found at {repo}. "
            f"Run `git clone https://github.com/chiutaiyin/PhotoWCT2 "
            f"{repo}` first."
        )
    sys.path.insert(0, repo.as_posix())


class _PhotoWctWrapper(nn.Module):
    """Glue around the upstream `PhotoWCT2` class so its forward
    accepts (content, style) tensors directly — the upstream API
    does style transfer through a `transfer()` helper that accepts
    an iterable of style images, which `torch.onnx.export` can't
    trace cleanly. Wrap once.
    """

    def __init__(self, photowct2):
        super().__init__()
        self.photowct2 = photowct2

    def forward(self, content, style):
        # The upstream class exposes either `transfer()` or
        # `forward()` depending on fork; both signatures take
        # (content, style) tensors and return the stylised output.
        # We try transfer() first since that's the documented entry
        # point in the PhotoWCT2 paper code.
        if hasattr(self.photowct2, "transfer"):
            return self.photowct2.transfer(content, style)
        return self.photowct2(content, style)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--photowct2-repo", type=Path, required=True,
                    help="Path to the cloned chiutaiyin/PhotoWCT2 repo.")
    ap.add_argument("--variant", choices=("conv", "relu"), default="conv",
                    help="Which VGG variant to export. `conv` uses "
                         "VGG conv4-1 features (default in upstream); "
                         "`relu` uses VGG relu4-1 features.")
    ap.add_argument("--ckpts-dir", type=Path,
                    help="Override path to the ckpts directory. "
                         "Defaults to <repo>/ckpts/ckpts-<variant>.")
    ap.add_argument("--output", type=Path, required=True,
                    help="Destination .onnx path.")
    ap.add_argument("--input-size", type=int, default=512,
                    help="Spatial input dim. Default 512.")
    ap.add_argument("--opset", type=int, default=17,
                    help="ONNX opset version. Default 17.")
    args = ap.parse_args()

    _add_repo_to_path(args.photowct2_repo)
    # Lazy import the right variant.
    if args.variant == "conv":
        from utils.model_conv import PhotoWCT2  # type: ignore
    else:
        from utils.model_relu import PhotoWCT2  # type: ignore

    ckpts_dir = args.ckpts_dir or (
        args.photowct2_repo / "ckpts" / f"ckpts-{args.variant}"
    )
    if not ckpts_dir.exists():
        raise SystemExit(f"ckpts directory not found at {ckpts_dir}")

    print(f"Loading PhotoWCT2 ({args.variant}) from {ckpts_dir}")
    model = PhotoWCT2()
    model.load_state_dict(
        torch.load(ckpts_dir, map_location="cpu", weights_only=False)
        if ckpts_dir.is_file()
        else _load_from_dir(model, ckpts_dir),
        strict=False,
    )
    model.eval()
    wrapper = _PhotoWctWrapper(model).eval()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    content = torch.zeros(1, 3, args.input_size, args.input_size,
                          dtype=torch.float32)
    style = torch.zeros(1, 3, args.input_size, args.input_size,
                        dtype=torch.float32)
    print(f"Exporting → {args.output} (opset={args.opset})")
    torch.onnx.export(
        wrapper,
        (content, style),
        args.output.as_posix(),
        input_names=["content", "style"],
        output_names=["output"],
        opset_version=args.opset,
        do_constant_folding=True,
        dynamic_axes=None,
    )

    print("Validating with onnxruntime...")
    import onnxruntime as ort
    import numpy as np
    sess = ort.InferenceSession(args.output.as_posix(),
                                providers=["CPUExecutionProvider"])
    out = sess.run(
        None,
        {
            "content": np.zeros((1, 3, args.input_size, args.input_size),
                                dtype=np.float32),
            "style": np.zeros((1, 3, args.input_size, args.input_size),
                              dtype=np.float32),
        },
    )[0]
    expected = (1, 3, args.input_size, args.input_size)
    if out.shape != expected:
        print(f"  FAIL: expected {expected}, got {out.shape}")
        return 1
    if out.dtype != np.float32:
        print(f"  FAIL: expected float32, got {out.dtype}")
        return 1
    print(f"  OK — output shape {out.shape}, dtype {out.dtype}")

    sha = hashlib.sha256(args.output.read_bytes()).hexdigest()
    size_bytes = args.output.stat().st_size
    print()
    print("=" * 64)
    print("Manifest-pinning values for `photo_wct2_fp16` entry:")
    print(f"  sizeBytes: {size_bytes}")
    print(f"  sha256:    {sha}")
    print(f"  assetPath: {args.output.as_posix()}")
    print("=" * 64)
    print("Drop `photo_wct2_fp16` from `deferredDownloadables` in "
          "test/ai/manifest_integrity_test.dart and run "
          "`flutter test test/ai/manifest_integrity_test.dart`. "
          "Also rename the manifest id to "
          "`photo_wct2_<variant>_fp32` for honesty (the upstream "
          "ckpts ship FP32, not FP16).")
    return 0


def _load_from_dir(model, ckpts_dir: Path):
    """PhotoWCT2 sometimes stores per-block .pth files in a directory
    instead of a single rolled-up checkpoint. Walk the dir and
    merge.
    """
    merged = {}
    for pth in sorted(ckpts_dir.glob("*.pth")):
        merged.update(torch.load(pth, map_location="cpu", weights_only=False))
    return merged


if __name__ == "__main__":
    sys.exit(main())
