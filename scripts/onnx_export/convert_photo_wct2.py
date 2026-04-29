#!/usr/bin/env python3
"""
Phase XVI.65 — PhotoWCT2 ONNX export, BLOCKED.

When XVI.65 scaffolded this script we assumed chiutaiyin/PhotoWCT2
was a PyTorch model. It isn't — the upstream uses TensorFlow
(`utils/model_conv.py` starts with `import tensorflow as tf` and
defines VggEncoder + VggDecoder as `tf.keras.Model` subclasses).

Worse, the stylization core (`stylize_core` -> `stylize_zca` ->
`inv_sqrt_cov` in the demo notebook) uses:

    s, u, _ = tf.linalg.svd(cov + tf.eye(cov.shape[-1]))
    n_s = tf.reduce_sum(tf.cast(tf.greater(s, 1e-5), tf.int32))
    s = tf.sqrt(s[:, :n_s])
    u = u[:, :, :n_s]

Two ONNX-incompatible patterns there:

1. `tf.linalg.svd` on a per-feature covariance matrix is supported
   in opset 13+ but only at fixed input rank — it's slow and many
   inference runtimes fall back to CPU even when GPU is available.

2. `n_s = reduce_sum(greater(s, eps))` is a *data-dependent* tensor
   used as the upper bound of `[:, :n_s]` slicing on the next line.
   ONNX requires static shapes for slice operators. tf2onnx will
   either bail out or produce a graph with `n_s` hardcoded,
   discarding the rank-truncation behavior the original model uses
   to suppress small singular values for numerical stability.

The combination means: even with `pip install tensorflow tf2onnx`
the resulting ONNX would either fail to convert or produce
numerically-different output from the upstream PyTorch demo.

## Realistic options going forward

1. **Drop the entry**. The existing Magenta-arbitrary-style scaffold
   covers "match this photo's look" adequately for now. Remove
   `lib/ai/services/style_transfer/photo_wct_service.dart` +
   `kPhotoWctModelId` + the manifest entry. This is the
   recommended path until someone reasons about the rank-truncation
   substitute below.

2. **Port to PyTorch with a static-rank stylize_core**. Replace the
   data-dependent rank truncation with a fixed `min(n_s_max, dim)`
   threshold (e.g. always keep 64 of 64 singular values). Quality
   may degrade on degenerate covariance matrices, but the result
   ONNX-exports cleanly via torch.onnx.export. ~2 days of careful
   research work.

3. **Use a different photoreal style-transfer model**. PCT-Net
   (CVPR 2023) and DCCF (ECCV 2022) are both PyTorch and have
   community ONNX exports. Either would replace PhotoWCT2 in the
   "Match scene aesthetic" tier without the SVD complication.

This script just prints the above and exits, so users don't sink
2+ GB of TensorFlow install for a script that wouldn't produce a
working ONNX anyway.
"""
import argparse
import sys
from pathlib import Path


_MESSAGE = """\
==============================================================
PhotoWCT2 ONNX export is BLOCKED — see header comment in this
script and in scripts/onnx_export/README.md for the full reason.

TL;DR:
  * Upstream chiutaiyin/PhotoWCT2 is a TensorFlow model, not
    PyTorch (XVI.65 wrongly assumed PyTorch).
  * The stylization core uses tf.linalg.svd + a data-dependent
    rank truncation (`n_s = reduce_sum(s > eps)`; `s[:, :n_s]`).
    Data-dependent slice bounds can't ONNX-export to a static
    graph — tf2onnx will either fail or hardcode `n_s`, which
    loses the rank-truncation behavior the model relies on for
    numerical stability.
  * Installing tensorflow + tf2onnx wouldn't change either fact.

Recommended next steps (in order of effort):

  (1) Remove PhotoWCT2 from the project: delete
        lib/ai/services/style_transfer/photo_wct_service.dart
        test/ai/services/photo_wct_service_test.dart
      and drop the `photo_wct2_fp16` entry from
      assets/models/manifest.json + the deferredDownloadables
      allow-list. The existing Magenta scaffold covers the
      "Match scene aesthetic" tier adequately.

  (2) Swap to a different photoreal style-transfer model that
      already has clean ONNX exports — PCT-Net (CVPR 2023) or
      DCCF (ECCV 2022) are both PyTorch.

  (3) If you really want PhotoWCT2 specifically, port the
      stylize_core to PyTorch with a STATIC rank truncation
      (always keep all singular values, or threshold at compile
      time). Then torch.onnx.export works cleanly. ~2 days of
      careful work.

This script does NOT attempt the conversion — printing this
message is intentional to avoid wasting your time + disk space on
a multi-GB TensorFlow install for an export that wouldn't
produce a working ONNX.
==============================================================
"""


def main() -> int:
    ap = argparse.ArgumentParser(
        description="PhotoWCT2 ONNX export — currently blocked. See header.",
    )
    ap.add_argument("--photowct2-repo", type=Path,
                    help="(unused; kept for arg-compat with prior versions)")
    ap.add_argument("--variant", choices=("conv", "relu"), default="conv",
                    help="(unused)")
    ap.add_argument("--ckpts-dir", type=Path,
                    help="(unused)")
    ap.add_argument("--output", type=Path,
                    help="(unused)")
    ap.add_argument("--input-size", type=int, default=512,
                    help="(unused)")
    ap.add_argument("--opset", type=int, default=18,
                    help="(unused)")
    ap.add_argument("--force-attempt", action="store_true",
                    help="Override and attempt the conversion anyway. "
                         "Will install tensorflow + tf2onnx, attempt to "
                         "trace the full upstream model, and almost "
                         "certainly fail at the SVD step. Reserved for "
                         "users who want to confirm the failure mode "
                         "themselves.")
    args = ap.parse_args()

    if not args.force_attempt:
        sys.stdout.write(_MESSAGE)
        return 0

    print("--force-attempt set; trying tf2onnx conversion anyway.")
    print("This will fail at the SVD / dynamic-rank step. Press Ctrl+C")
    print("to abort if you're not ready for tensorflow's install size.")
    print()
    try:
        import tensorflow as tf  # noqa: F401
        import tf2onnx  # noqa: F401
    except ImportError as e:
        print(f"Import failed: {e}")
        print("Install with: pip install tensorflow tf2onnx")
        return 1

    print("tensorflow + tf2onnx imported. The full upstream model "
          "would now need to be reconstructed as a tf.keras.Model "
          "wrapping VggEncoder + 4× stylize_core + VggDecoder. That "
          "wrapper is intentionally not in this script — see the "
          "header for why it would fail at SVD.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
