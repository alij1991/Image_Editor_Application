#!/usr/bin/env python3
"""
Phase XVI.65 — convert DnCNN-color PyTorch weights to ONNX matching
the I/O contract `lib/ai/services/denoise/ai_denoise_service.dart`
expects.

DnCNN (Zhang et al. 2017, TIP) is a 17-layer residual-learning CNN.
The architecture is small enough to define inline so this script
has no upstream-repo dependency — the user just supplies (or lets
the script download) the .pth weights and runs.

Source weights:
    https://huggingface.co/deepinv/dncnn/resolve/main/dncnn_sigma2_color.pth

I/O contract (matches AiDenoiseService.residualOutput=True path):
    Input:  'input'  [1, 3, 1024, 1024] float32 in [0, 1]
    Output: 'output' [1, 3, 1024, 1024] float32 — predicted NOISE
                     (residual). Service computes
                     clean = input - output.

Usage (from the repo root):
    python scripts/onnx_export/convert_dncnn_color.py \\
      --output assets/models/bundled/dncnn_color_fp32.onnx
"""
import argparse
import hashlib
import os
import sys
from pathlib import Path

import torch
import torch.nn as nn

# ----------------------------------------------------------------
# Architecture — inlined from the canonical DnCNN paper. 17 layers,
# 64 filters per hidden layer, 3 input/output channels for color.
# ----------------------------------------------------------------
class DnCNN(nn.Module):
    def __init__(self, depth=17, n_channels=64, image_channels=3):
        super().__init__()
        kernel_size = 3
        padding = 1
        layers = []
        # First layer: Conv + ReLU (no BN per the original).
        layers.append(nn.Conv2d(image_channels, n_channels,
                                kernel_size=kernel_size,
                                padding=padding, bias=True))
        layers.append(nn.ReLU(inplace=True))
        # Middle layers: Conv + BN + ReLU.
        for _ in range(depth - 2):
            layers.append(nn.Conv2d(n_channels, n_channels,
                                    kernel_size=kernel_size,
                                    padding=padding, bias=False))
            layers.append(nn.BatchNorm2d(n_channels, eps=1e-4,
                                         momentum=0.95))
            layers.append(nn.ReLU(inplace=True))
        # Last layer: Conv (predicts the residual / noise).
        layers.append(nn.Conv2d(n_channels, image_channels,
                                kernel_size=kernel_size,
                                padding=padding, bias=False))
        self.dncnn = nn.Sequential(*layers)

    def forward(self, x):
        # Predict the noise; AiDenoiseService.residualOutput=True
        # then computes clean = x - noise on the Dart side.
        return self.dncnn(x)


def _download_weights(dest_path: Path) -> None:
    """Pull the deepinv/dncnn sigma2-color checkpoint from HF."""
    from huggingface_hub import hf_hub_download
    print(f"Downloading dncnn_sigma2_color.pth → {dest_path}")
    cached = hf_hub_download(
        repo_id="deepinv/dncnn",
        filename="dncnn_sigma2_color.pth",
    )
    Path(cached).rename(dest_path) if dest_path != Path(cached) else None
    print(f"Cached at {cached}")


def _load_state_dict(path: Path) -> dict:
    """Load the .pth payload, peeling whatever wrapper deepinv used.

    deepinv's checkpoint may be the raw state_dict OR a dict with a
    'state_dict' key. We probe both.
    """
    raw = torch.load(path, map_location="cpu", weights_only=False)
    if isinstance(raw, dict) and "state_dict" in raw:
        return raw["state_dict"]
    if isinstance(raw, dict) and "model_state_dict" in raw:
        return raw["model_state_dict"]
    return raw


def _strip_module_prefix(state_dict: dict) -> dict:
    """`torch.nn.DataParallel` wraps every key with `module.`. Strip
    that so it loads into a plain Sequential.
    """
    out = {}
    for k, v in state_dict.items():
        if k.startswith("module."):
            out[k[len("module."):]] = v
        else:
            out[k] = v
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", type=Path,
                    help="Path to the .pth weights. If omitted, "
                         "downloads dncnn_sigma2_color.pth from "
                         "huggingface.co/deepinv/dncnn.")
    ap.add_argument("--output", type=Path, required=True,
                    help="Destination .onnx path "
                         "(e.g. assets/models/bundled/dncnn_color_fp32.onnx).")
    ap.add_argument("--input-size", type=int, default=1024,
                    help="Spatial dimension of the synthetic export "
                         "input. Default 1024 — matches "
                         "AiDenoiseService.inputSize.")
    ap.add_argument("--opset", type=int, default=17,
                    help="ONNX opset version. Default 17 (covers "
                         "every op DnCNN uses + good ORT support).")
    args = ap.parse_args()

    weights_path = args.weights
    if weights_path is None:
        weights_path = args.output.parent / "dncnn_sigma2_color.pth"
        weights_path.parent.mkdir(parents=True, exist_ok=True)
        if not weights_path.exists():
            _download_weights(weights_path)

    print(f"Loading weights from {weights_path}")
    state = _load_state_dict(weights_path)
    state = _strip_module_prefix(state)

    model = DnCNN(depth=17, n_channels=64, image_channels=3)
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing:
        print(f"  WARNING: {len(missing)} missing keys; head[:5]={missing[:5]}")
    if unexpected:
        print(f"  WARNING: {len(unexpected)} unexpected keys; head[:5]="
              f"{unexpected[:5]}")
    model.eval()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    dummy = torch.zeros(1, 3, args.input_size, args.input_size,
                        dtype=torch.float32)
    print(f"Exporting → {args.output} (opset={args.opset})")
    torch.onnx.export(
        model,
        dummy,
        args.output.as_posix(),
        input_names=["input"],
        output_names=["output"],
        opset_version=args.opset,
        do_constant_folding=True,
        # Keep batch + spatial fixed: AiDenoiseService runs at a
        # single fixed resolution, and a static graph quantises +
        # caches better than a dynamic one.
        dynamic_axes=None,
    )

    # ----------------------------------------------------------------
    # Smoke-test with onnxruntime.
    # ----------------------------------------------------------------
    print("Validating with onnxruntime...")
    import onnxruntime as ort
    import numpy as np
    sess = ort.InferenceSession(args.output.as_posix(),
                                providers=["CPUExecutionProvider"])
    x = np.zeros((1, 3, args.input_size, args.input_size), dtype=np.float32)
    out = sess.run(None, {"input": x})[0]
    expected_shape = (1, 3, args.input_size, args.input_size)
    if out.shape != expected_shape:
        print(f"  FAIL: expected output shape {expected_shape}, "
              f"got {out.shape}")
        return 1
    if out.dtype != np.float32:
        print(f"  FAIL: expected float32, got {out.dtype}")
        return 1
    print(f"  OK — output shape {out.shape}, dtype {out.dtype}")

    # ----------------------------------------------------------------
    # Hash + size for manifest pinning.
    # ----------------------------------------------------------------
    sha = hashlib.sha256(args.output.read_bytes()).hexdigest()
    size_bytes = args.output.stat().st_size
    print()
    print("=" * 64)
    print("Manifest-pinning values for `dncnn_color_int8` entry:")
    print(f"  sizeBytes: {size_bytes}")
    print(f"  sha256:    {sha}")
    print(f"  assetPath: {args.output.as_posix()}")
    print("=" * 64)
    print("Drop `dncnn_color_int8` from `deferredDownloadables` in "
          "test/ai/manifest_integrity_test.dart and run "
          "`flutter test test/ai/manifest_integrity_test.dart` "
          "to confirm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
