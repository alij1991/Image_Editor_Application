# ONNX export scripts

Phase XVI.65 — three Python scripts that convert the remaining
deferred entries in `assets/models/manifest.json` from their
upstream PyTorch checkpoints into ONNX files matching the I/O
contract the Flutter services expect.

After XVI.64 the manifest has three entries left in the
`deferredDownloadables` allow-list of `test/ai/manifest_integrity_test.dart`:

| id                   | upstream weights                                       | status                                  |
| -------------------- | ------------------------------------------------------ | --------------------------------------- |
| `dncnn_color_int8`   | `huggingface.co/deepinv/dncnn` (`*_color.pth`)         | PyTorch — script ready                  |
| `harmonizer_eccv_2022` | `github.com/ZHKKKe/Harmonizer` (Google Drive `.pth`) | PyTorch — pinned in `b2ed00c` ✅        |
| `photo_wct2_fp16`    | `github.com/chiutaiyin/PhotoWCT2` (`ckpts/`)           | **TensorFlow + non-trivial SVD; blocked** |

The first two are PyTorch and convert via `torch.onnx.export`.

The third (PhotoWCT2) is TensorFlow and the stylization core uses
`tf.linalg.svd` with a data-dependent rank truncation that can't
ONNX-export cleanly — see the header comment in
`convert_photo_wct2.py` for the details and the recommended
options. The script does NOT attempt the conversion; it prints
the explanation and exits so you don't sink GB of `tensorflow`
install on a path that wouldn't produce a working ONNX.

## Running a script

Each script targets one model. Common setup:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Then per-model (run from the repo root):

```bash
# DnCNN-color (smallest; ~3 MB ONNX, no upstream repo needed)
python scripts/onnx_export/convert_dncnn_color.py \
  --output assets/models/bundled/dncnn_color_fp32.onnx

# Harmonizer (needs ZHKKKe/Harmonizer cloned alongside)
git clone https://github.com/ZHKKKe/Harmonizer ../Harmonizer
# Download `harmonizer.pth` into ../Harmonizer/pretrained/ per upstream README.
python scripts/onnx_export/convert_harmonizer.py \
  --harmonizer-repo ../Harmonizer \
  --weights ../Harmonizer/pretrained/harmonizer.pth \
  --output assets/models/bundled/harmonizer_eccv_2022_fp32.onnx

# PhotoWCT2 — currently blocked (TF + ONNX-incompatible SVD).
# See header of convert_photo_wct2.py for options. Running it
# just prints the explanation and exits.
python scripts/onnx_export/convert_photo_wct2.py
```

Each script prints the resulting file's sha256 + size in bytes
when it finishes. Copy those into the manifest entry for that id,
flip `bundled: true` + `assetPath: "..."`, drop the entry from
`deferredDownloadables` in `test/ai/manifest_integrity_test.dart`,
and commit.

## I/O contracts the scripts enforce

These match what the Flutter services in `lib/ai/services/` already
parse, so the converted ONNX is drop-in.

### `convert_dncnn_color.py`
- Input: `input` shape `[1, 3, 1024, 1024]` float32 in `[0, 1]`.
- Output: `[1, 3, 1024, 1024]` float32 — the predicted **noise
  residual** (DnCNN trains as residual learning).
  `AiDenoiseService.residualOutput` toggle should be `true` when
  this export is used.

### `convert_harmonizer.py`
- Input 0: `composite` shape `[1, 3, 256, 256]` float32, ImageNet
  mean/std normalised.
- Input 1: `mask` shape `[1, 1, 256, 256]` float32 in `{0, 1}`.
- Output: `[1, 8]` float32 filter args
  (brightness/contrast/saturation/temperature/tint/sharpness/highlights/shadows).

### `convert_photo_wct2.py`
- Input 0: `content` shape `[1, 3, 512, 512]` float32 in `[0, 1]`.
- Input 1: `style` shape `[1, 3, 512, 512]` float32 in `[0, 1]`.
- Output: `[1, 3, 512, 512]` float32 in `[0, 1]` — photoreal
  stylised content.

## Why the scripts hand `--output` paths instead of writing to a
fixed location

The bundled ONNX path follows the manifest entry's `assetPath`,
which the user controls. The scripts intentionally don't hard-code
the destination — pass the `assetPath` value from the manifest
entry you're pinning so the file lands in the exact spot Flutter's
asset system reads from at runtime.

## Verifying after export

Each script ends with an `onnxruntime.InferenceSession` smoke test
on a synthetic input matching the contract above. If the smoke
test passes, the ONNX is loadable; if it fails, the script prints
which dimension or dtype mismatched.

Final step: copy the printed sha256 + size into the manifest, drop
the id from `deferredDownloadables`, and run `flutter test
test/ai/manifest_integrity_test.dart` to confirm the pinning gate
goes green.
