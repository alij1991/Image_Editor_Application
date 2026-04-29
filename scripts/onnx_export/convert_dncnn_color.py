#!/usr/bin/env python3
"""
Phase XVI.65 — convert DnCNN-color PyTorch weights to ONNX matching
the I/O contract `lib/ai/services/denoise/ai_denoise_service.dart`
expects.

The first XVI.65 attempt inlined a "canonical DnCNN-17 with BN"
architecture, but the deepinv/dncnn weights on HF use a different
shape: depth=20, bias=True on every conv, NO batch norm, and the
forward already adds the residual back so the output is the
*clean image* (not the noise residual). Using the canonical-17
arch silently dropped every weight and exported a random model.

This rev imports `from deepinv.models import DnCNN` so we get the
exact architecture the weights were trained against. `deepinv` is
listed in requirements.txt for that reason.

Source weights:
    https://huggingface.co/deepinv/dncnn/resolve/main/dncnn_sigma2_color.pth

I/O contract:
    Input:  'input'  [1, 3, 1024, 1024] float32 in [0, 1]
    Output: 'output' [1, 3, 1024, 1024] float32 — CLEAN image
                     direct (deepinv's DnCNN.forward does
                     `out_conv(x1) + x`, so the residual add is
                     already inside the graph).

  *** AiDenoiseService.residualOutput should be `false` for this
      export — the model emits the clean image, not the noise
      residual the canonical-17 variant would. ***

Usage (from the repo root):
    python scripts/onnx_export/convert_dncnn_color.py \\
      --output assets/models/bundled/dncnn_color_fp32.onnx
"""
import argparse
import hashlib
import sys
from pathlib import Path

import torch


def _download_weights() -> Path:
    """Pull the deepinv/dncnn sigma2-color checkpoint from HF.

    Returns the path huggingface_hub resolved to in its local
    cache (`~/.cache/huggingface/hub/.../dncnn_sigma2_color.pth`).
    We DON'T move/rename the file out of the cache — the original
    XVI.65 attempt to rename the symlink into the project tree
    silently failed when the HF Xet symlink target couldn't be
    re-resolved from the new location, leaving torch.load with
    nothing to open.
    """
    from huggingface_hub import hf_hub_download
    print("Downloading dncnn_sigma2_color.pth from "
          "huggingface.co/deepinv/dncnn")
    cached = hf_hub_download(
        repo_id="deepinv/dncnn",
        filename="dncnn_sigma2_color.pth",
    )
    print(f"Cached at {cached}")
    return Path(cached)


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
    ap.add_argument("--opset", type=int, default=18,
                    help="ONNX opset version. Default 18 — matches "
                         "what PyTorch 2.x's exporter implements "
                         "natively (opset 17 trips an auto-promote "
                         "warning). Every DnCNN op is supported in "
                         "every modern opset.")
    args = ap.parse_args()

    weights_path = args.weights
    if weights_path is None:
        # Pull from HF cache; don't try to move the file into the
        # project tree — the XVI.65 first attempt at .rename() out
        # of the HF cache silently broke the symlink. We just read
        # the cached file directly.
        weights_path = _download_weights()
    args.output.parent.mkdir(parents=True, exist_ok=True)

    print(f"Loading weights from {weights_path}")
    state = _load_state_dict(weights_path)
    state = _strip_module_prefix(state)

    # `pretrained=None` skips deepinv's auto-download — we already
    # resolved the weights above and want strict control over which
    # variant lands in the ONNX. depth=20 / bias=True / nf=64 are
    # the deepinv defaults; in/out_channels=3 picks the color
    # variant matching dncnn_sigma2_color.pth.
    try:
        from deepinv.models import DnCNN as DeepinvDnCNN
    except ImportError as e:
        print("\nFailed to import deepinv.models.DnCNN.")
        print("Install with: pip install deepinv")
        print(f"Underlying error: {e}")
        return 1
    model = DeepinvDnCNN(
        in_channels=3,
        out_channels=3,
        depth=20,
        bias=True,
        nf=64,
        pretrained=None,
        device="cpu",
    )
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing:
        print(f"  WARNING: {len(missing)} missing keys; head[:5]={missing[:5]}")
        print("  Aborting — every key should load against the deepinv "
              "DnCNN architecture; missing keys mean the weights are "
              "from a different variant.")
        return 1
    if unexpected:
        print(f"  WARNING: {len(unexpected)} unexpected keys; head[:5]="
              f"{unexpected[:5]}")
    model.eval()

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
    print("After pinning the manifest entry:")
    print("  1. Drop `dncnn_color_int8` from `deferredDownloadables` "
          "in test/ai/manifest_integrity_test.dart.")
    print("  2. *** Set `residualOutput: false` in the AiDenoiseService "
          "constructor where this model is wired up. *** The deepinv "
          "DnCNN's forward already adds the residual back inside the "
          "graph, so the model output is the clean image, NOT the "
          "noise residual. The original AiDenoiseService scaffold in "
          "XVI.50 assumed `residualOutput: true` for the canonical-17 "
          "variant — the deepinv export inverts that assumption.")
    print("  3. Run `flutter test test/ai/manifest_integrity_test.dart` "
          "to confirm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
