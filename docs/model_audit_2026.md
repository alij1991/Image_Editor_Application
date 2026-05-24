# 2026 AI Model Audit — Drop-In Upgrades & New Capabilities

Phase XVI.67. Inventory of every model the editor currently loads,
benchmarked against state-of-the-art alternatives that have shipped
since the original integrations. Recommendations split into:

- **Drop-in upgrades** — same architecture / interface, sharper output.
- **New tier additions** — additional choices for users in existing
  picker flows.
- **New capabilities** — categories the editor doesn't address today.

For every recommendation: paper, expected quality lift over the
current shipping option, mobile size, integration cost.

---

## 1 · Background removal / matting

**Current tiers (6, after XVI.67):**

| Tier | Model | Size | Quality |
|---|---|---|---|
| Fast | MediaPipe Selfie | bundled | portrait-only, ~0.7 S_α |
| Balanced | MODNet | 26 MB | portrait, ~0.78 |
| General Offline | U²-Netp | bundled | any subject, ~0.74 |
| Hair + fur | RVM | 15 MB | best hair detail, ~0.81 |
| Best | RMBG-1.4 | 44 MB | general, ~0.84 |
| **Premium** | **BiRefNet-Lite** *(XVI.67)* | **178 MB** | **best, ~0.87** |

### Drop-in upgrade candidates

| Model | Paper | Lift vs RMBG | Size | Cost |
|---|---|---|---|---|
| **BiRefNet (full)** | Zheng 2024 | S_α 0.88 (vs 0.84) | ~880 MB | swap manifest pin |
| **BiRefNet-portrait HR** | Zheng 2024 | S_α 0.90 on portraits | ~220 MB | swap manifest pin, set `inputSize: 2048` |
| **InSPyReNet** | Kim ACCV 2022 | comparable to BiRefNet on DIS5K | ~350 MB | new service (different shape) |

**Recommendation:** the XVI.67 BiRefNet-Lite covers the quality
ceiling for now. If a power-user "best possible" toggle is
warranted, add BiRefNet-portrait as a 7th tier (just a manifest
entry — service code handles it because `inputSize` is dynamic).

---

## 2 · Face restoration

**Current:** RestoreFormer++ FP32 (298 MB download, XVI.56 + XVI.64).

| Alternative | Paper | Quality | Size | Cost |
|---|---|---|---|---|
| **GFPGAN v1.4** | Wang CVPR 2021 | comparable PSNR, slightly softer skin | 340 MB FP32 | new service kind, similar I/O contract |
| **CodeFormer** | Zhou NeurIPS 2022 | identity-preserving (good for ID restoration) | 360 MB FP32 | new service, slightly different (codebook lookup) |
| **DiffBIR** | Lin 2024 | diffusion-based, highest fidelity | 1.5 GB | not mobile-feasible |
| **GPEN-512** | Yang CVPR 2021 | comparable, sometimes preferred for selfies | 250 MB | similar to RestoreFormer++ |

**Recommendation:** ship **CodeFormer** as a second tier ("Restore
Faces (identity-preserved)"). Different aesthetic trade-off than
RestoreFormer++; some users prefer it because it doesn't smooth
distinctive features. Integration cost: ~150 LOC for the service.

---

## 3 · Inpainting / Object removal

**Current tiers (2, after XVI.66b):** LaMa (Quality, 208 MB) + MI-GAN
(Fast, 28 MB).

| Alternative | Paper | Quality lift | Size | Cost |
|---|---|---|---|---|
| **MAT** (Mask-Aware Transformer) | Li CVPR 2022 | SOTA on faces / repeated textures | ~300 MB | new service, similar I/O |
| **ZITS++** | Cao CVPR 2023 | structure-aware, better on geometry | 250 MB | new service |
| **PowerPaint** | Zhuang 2024 | diffusion, best subjective quality | 4 GB+ | not mobile-feasible |
| **AOT-GAN** | Zeng ICCV 2021 | comparable to LaMa, sharper edges | 90 MB | new service, similar interface |

**Recommendation:** add **AOT-GAN** as a 3rd inpaint tier ("Sharp
edges"). 90 MB is a sweet spot between LaMa (208 MB, quality) and
MI-GAN (28 MB, speed). Distinguishes the picker with a genuinely
different output character. Integration cost: ~150 LOC.

---

## 4 · Super-resolution

**Current tiers (2, after XVI.66b):** Real-ESRGAN x2 (17 MB ONNX) +
Real-ESRGAN x4 (67 MB TFLite).

| Alternative | Paper | Quality lift | Size | Cost |
|---|---|---|---|---|
| **HAT** (Hybrid Attention Transformer) | Chen CVPR 2024 | +0.5 dB PSNR over Real-ESRGAN | 80 MB FP16 | new service |
| **SwinIR** | Liang ICCV 2021 | sharp Transformer-based output | 130 MB | new service |
| **SAFMN** | Sun 2023 | mobile-tuned, fast | 4 MB | drop-in (similar interface) |
| **DRCT** | Hsu 2024 | SOTA, lightweight variant available | 35 MB | new service |

**Recommendation:** add **SAFMN** as a "Mobile Fast" tier (4 MB
download — basically free). At small upscales it's competitive
with Real-ESRGAN x2 at ~1/4 the size. Useful for "quick upscale
on slow networks". Integration cost: ~100 LOC.

---

## 5 · Denoising / Sharpening

**Current:**
- Denoise: DnCNN-color (2.7 MB bundled, XVI.50 + XVI.65)
- Sharpen / Deblur: NAFNet (92 MB download, XVI.55 + XVI.64)

| Category | Alternative | Paper | Quality lift | Size | Cost |
|---|---|---|---|---|---|
| Denoise | **SCUNet** | Zhang 2022 | Swin-Conv-UNet, better on heavy noise | 60 MB | new service |
| Denoise | **Restormer** | Zamir CVPR 2022 | Transformer-based, SOTA but heavy | 150 MB | new service |
| Sharpen | **Restormer-deblur** | Zamir CVPR 2022 | SOTA on motion blur | 150 MB | new service |
| Sharpen | **FFTformer** | Kong CVPR 2023 | newer, slightly better than NAFNet | 80 MB | new service |

**Recommendation:** the current DnCNN + NAFNet stack is well-tuned
for mobile. **SCUNet** would add value for users with high-ISO
photos (it handles structured noise better than DnCNN). Integration
cost: ~150 LOC. Wait until users report DnCNN insufficient.

---

## 6 · Semantic segmentation (sky, objects, persons)

**Current:**
- Sky: DeepLab-V3 ADE20K (2.4 MB) + SegFormer-B0 (4.4 MB, XVI.52)
- Object: EfficientDet-Lite0 (4.5 MB COCO 90-class)
- Selfie multiclass: MediaPipe Selfie Multiclass (16 MB, hair/clothes)

| Category | Alternative | Paper | Quality lift | Size | Cost |
|---|---|---|---|---|---|
| Universal | **MobileSAM** | Zhang 2023 | Segment Anything for mobile | 10 MB | NEW capability — see §9 |
| Sky/general | **SegFormer-B2** | Xie NeurIPS 2021 | +5 mIoU on ADE20K | 27 MB | drop-in swap of SegFormer-B0 |
| Object detect | **YOLOv8n** | Ultralytics 2023 | +3 mAP over EfficientDet-Lite | 12 MB | new service, NMS in-graph |
| Object detect | **YOLO-NAS** | Deci 2023 | SOTA mobile | 25 MB | new service |

**Recommendation:**
- Add **YOLOv8n** as a second object-detector behind a kind enum.
  Smart-crop's region prior accuracy lifts noticeably. Integration
  cost: ~200 LOC (similar interface to EfficientDet path).
- Defer SegFormer-B2 swap — current sky detection is already good.

---

## 7 · Harmonization / Style transfer

**Current:**
- Harmonizer (19 MB bundled, XVI.65) — composite color matching
- Magenta style transfer (284 KB bundled) — arbitrary style xfer
- photo_wct2_fp16 — deferred indefinitely (TensorFlow + tf.linalg.svd)

| Alternative | Paper | Use case | Size | Cost |
|---|---|---|---|---|
| **PCT-Net** | Guerreiro CVPR 2023 | photoreal color transfer | 50 MB | replaces photo_wct2 with feasible ONNX |
| **DCCF** | Xue ECCV 2022 | deep color consistent filter, smooth output | 30 MB | new service |
| **CIE-XYZNet** | Afifi ECCV 2022 | white-balance correction | 8 MB | NEW capability |
| **PaletteNet** | Cho ACM TOG 2023 | retarget composition's palette to a reference | 40 MB | new service |

**Recommendation:** **PCT-Net** is the right replacement for the
photo_wct2 slot. Has community ONNX exports, mobile-feasible, and
solves the "make my composed subject match the new background"
problem the Harmonizer also targets but with a different signal.
Integration cost: ~150 LOC + service.

---

## 8 · Image embedding (preset suggester)

**Current:** MobileViT-v2 1.0× FP32 (27 MB bundled, XVI.58).

| Alternative | Paper | Quality lift | Size | Cost |
|---|---|---|---|---|
| **DINOv2 small** | Oquab Meta 2024 | self-supervised, richer features | 90 MB | drop-in (same I/O shape) |
| **CLIP ViT-B/16** | Radford OpenAI 2021 | text-image grounded | 350 MB | NEW capability (text search) |
| **SigLIP-base** | Zhai Google 2023 | better than CLIP at smaller size | 200 MB | NEW capability |
| **EVA-02-tiny** | Fang 2024 | SOTA in tiny category | 25 MB | drop-in |

**Recommendation:** MobileViT-v2's preset-rail quality is already
useful. **CLIP / SigLIP** would unlock text-based preset search
("apply a moody sunset preset") — that's a NEW feature, worth a
phase of its own.

---

## 9 · New capabilities (not currently addressed)

### 9a · Universal object segmentation (MobileSAM)

**MobileSAM** (Zhang 2023) — distilled SAM with ViT-Tiny image
encoder. 10 MB total. Lets users tap any object to get a precise
mask in ~200ms.

**Unlocks:**
- "Tap to remove object" (vs current paint-the-mask flow)
- "Tap to extract subject" (vs general matting)
- Smart-crop region selection
- Sky / horizon detection without the heuristic

**Integration cost:** ~300 LOC for the service + tap-to-segment UI
overlay. Major UX upgrade.

### 9b · Depth estimation (Depth Anything V2 small)

**Depth Anything V2 small** — Yang 2024, the SOTA monocular depth
estimator. The manifest already has a placeholder entry
(`depth_anything_v2_small_int8`, ~12 MB) from XVI.40 but the bundled
asset isn't shipped.

**Unlocks:**
- True depth-aware bokeh (vs current shader heuristic)
- Portrait mode (background blur with depth gradient)
- 3D photo / parallax effects
- Better focus-pull for tilt-shift

**Integration cost:** model is already in manifest as a placeholder
— need to source the actual ONNX file + ship bundled. Service is
~200 LOC.

### 9c · Image colorization (DDColor)

**DDColor** — Kang ICCV 2023. Colorizes B&W photos with semantic
awareness. 60 MB.

**Unlocks:** entire "Colorize old photo" flow.

**Integration cost:** ~200 LOC. Marquee feature for restoration
use case.

### 9d · Text-guided everything (CLIP / SigLIP + Florence-2)

Adding a text-encoder pair (CLIP-B/16, ~350 MB) unlocks:
- Text search across the preset library
- Text-guided inpainting ("remove the person in red")
- Text-guided crop ("crop to the dog")
- Auto-tagging photos for filtering

**Integration cost:** large — text encoder + UI + grounded prompting
plumbing. Phase-level project.

### 9e · OCR (PaddleOCR / EasyOCR)

The scanner uses Google ML Kit OCR (bundled). For editor use cases
(extract text from photos), a richer OCR like **PaddleOCR**
(50 MB) supports more languages and better layout detection.

**Integration cost:** ~150 LOC. Niche feature.

---

## Prioritised roadmap

Sorted by **(impact × user-visibility) ÷ effort**:

| # | Add | Why | Effort |
|---|---|---|---|
| **1** | **MobileSAM** (universal segmentation) | tap-to-select unlocks N follow-on flows | high (~300 LOC + UI) |
| **2** | **Depth Anything V2** (real ONNX file) | true bokeh, portrait mode | low (model already in manifest) |
| **3** | **AOT-GAN** (3rd inpaint tier) | sharper edges than LaMa, smaller than MI-GAN's quality | low (~150 LOC) |
| **4** | **CodeFormer** (face restore alt) | identity preservation | medium (~150 LOC + picker) |
| **5** | **PCT-Net** (replace photo_wct2 slot) | photoreal style transfer | medium (~150 LOC) |
| **6** | **DDColor** (colorization) | new headline feature | medium (~200 LOC) |
| **7** | **YOLOv8n** (object detect) | better smart-crop priors | medium (~200 LOC) |
| **8** | **BiRefNet-portrait HR** | 7th matter tier for max quality | trivial (manifest pin) |
| **9** | **SAFMN** (mobile super-res) | tiny size, useful tier | low (~100 LOC) |
| **10** | **CLIP/SigLIP** | text-based search | phase-level project |

---

## Manifest additions shipped in Phase XVI.67 + XVI.68

XVI.67 added 8 entries (BiRefNet-Lite + 7 from the audit roadmap)
based on best-guess HuggingFace URL patterns. XVI.68 added web
access to this session and verified every URL against the actual
HF hub — kept what's available, dropped what isn't, fixed
incorrect URLs + sizes:

| Model | Status | URL outcome | Real size |
|---|---|---|---|
| BiRefNet-Lite | ✓ KEPT (size fixed) | `onnx-community/BiRefNet_lite-ONNX/onnx/model.onnx` correct | 224 MB (was 187) |
| MobileSAM | ✓ SPLIT into encoder + decoder | `Acly/MobileSAM/mobile_sam_image_encoder.onnx` (28.2 MB) + `sam_mask_decoder_single.onnx` (16.5 MB) | 28.2 + 16.5 MB |
| CodeFormer | ✓ KEPT (URL fixed) | re-pointed to `facefusion/models-3.0.0/codeformer.onnx` | 377 MB (was 360) |
| YOLOv8n | ✓ KEPT (URL fixed) | re-pointed to `Kalray/yolov8/yolov8n.onnx` (Ultralytics repo only ships .pt) | 12.8 MB (was 12.2) |
| **AOT-GAN** | ✗ DROPPED | no community ONNX export — NimaBoscarino is PyTorch only, qualcomm uses .so | n/a |
| **SAFMN** | ✗ DROPPED | no community ONNX export — `scripts/to_onnx` exists in GitHub but no pre-converted file on HF | n/a |
| **PCT-Net** | ✗ DROPPED | no community ONNX export — PyTorch only at github.com/rakutentech | n/a |
| **DDColor** | ✗ DROPPED | community ONNX at `facefusion/models-3.0.0/ddcolor.onnx` weighs **980 MB** — exceeds mobile budget. The paper_tiny variant exists as a 220 MB .pth and could be converted, but no pre-converted ONNX | n/a |

**BiRefNet-Lite critical fix in XVI.68:** the model outputs **raw
logits**, not sigmoid'd probabilities. The original XVI.67 service
treated them as already in [0, 1], which would have produced a
near-fully-opaque or near-fully-transparent mask depending on
logit magnitudes. XVI.68 added `sigmoidInPlace` to the service
before the mask is consumed.

**BiRefNet-Lite ORT 1.23.0 regression — XVI.70 runtime fallback:**
the onnx-community export uses ONNX's in-memory external-data
format, which crashes ORT 1.23.0 with `[ShapeInferenceError]
Cannot parse data from external tensors`. The fix is in ORT 1.23.2
(microsoft/onnxruntime#26263, merged Oct 2025) but the
`onnxruntime_v2 1.23.2+2` Flutter package's iOS podspec exact-pins
`onnxruntime-objc (= 1.23.0)` (confirmed via `ios/Podfile.lock`).
`pod update` can't pull the newer native lib forward — the
constraint is an exact pin, not a range.

**The fix that works for any affected model (no manual bake
needed):** XVI.70 added a two-pass loader to
`OrtRuntime.load()` (lib/ai/runtime/ort_runtime.dart):

1. **First attempt** — load with the default
   `graphOptimizationLevel = ortEnableAll` (matches existing
   behaviour, succeeds for every model that doesn't trigger the
   bug).
2. **Detect the specific failure** — catch the exception and
   check whether its message contains
   `"Cannot parse data from external tensors"`. Any other error
   (file missing, op unsupported, etc.) propagates as before.
3. **Second attempt** — recreate session options with
   `setSessionGraphOptimizationLevel(ortDisableAll)`. This skips
   the shape-inference pass that 1.23.0 mishandles. Slightly
   higher inference latency (no operator fusion, no constant
   folding) but the model loads cleanly.
4. **Final failure** — if even the disabled-optimisations retry
   fails, throw with a message that explicitly names the
   `inline_onnx_model.py` script as the remaining workaround.

The two-pass loader handles BiRefNet-Lite TODAY without re-baking
or re-hosting. The optimisation-disabled path is a quiet downgrade
that becomes dead code as soon as `onnxruntime_v2` bumps to a
1.23.2-bundling release.

**Manual re-bake (only if the runtime fallback also fails):**
`scripts/onnx_export/inline_onnx_model.py` handles ANY HF
repo + file or direct URL — not just BiRefNet:

```bash
python inline_onnx_model.py \
  --repo onnx-community/BiRefNet_lite-ONNX \
  --file onnx/model.onnx \
  --out birefnet_lite_inlined.onnx
```

Same trick XVI.65 used for harmonizer's `.onnx.data` sidecar:
`onnx.load() + onnx.save(save_as_external_data=False)` produces
a single .onnx with constants in `raw_data`. Loads on any ORT
version because there are no external references to parse. The
script prints a ready-to-paste manifest snippet with sha256 +
sizeBytes.

**Verification process for the 6 unverified-but-shipped entries:**
1. First user tap downloads from the manifest URL.
2. SHA256 integrity check fails (PLACEHOLDER) → app shows error.
3. Maintainer runs `shasum -a 256 <downloaded_file>` on the
   resulting `<AppDocuments>/models/<modelId>_<version>` file.
4. Replaces the PLACEHOLDER in `assets/models/manifest.json` with
   the real hash.
5. Removes the entry from `deferredDownloadables` in
   `test/ai/manifest_integrity_test.dart`.
6. Re-runs `flutter test test/ai/manifest_integrity_test.dart` to
   confirm the strict-pinning suite passes.

**For the 4 dropped entries**, future revival paths:
- **AOT-GAN**: write a `scripts/onnx_export/convert_aot_gan.py`
  following XVI.65 pattern. Source weights at NimaBoscarino HF.
- **SAFMN**: GitHub has `scripts/to_onnx/` — clone + run, drop
  resulting .onnx into manifest. Issue #42 notes adaptive pool
  needs a small graph workaround.
- **PCT-Net**: PyTorch weights at github.com/rakutentech/PCT-Net.
  Standard torch.onnx.export path.
- **DDColor**: convert the paper_tiny .pth (220 MB) → ONNX via
  the official `scripts/export_onnx.py` and ship that variant
  instead of the 980 MB modelscope variant. Mobile-feasible.

---

## XVI.74 — root-cause fix for the ORT 1.23.0 regression

The XVI.70 runtime fallback worked but had a hidden cost: on
iPhone 15 Pro Max the graph-opt-disabled BiRefNet-Lite inference
OOM'd at MlasTransposeThreaded (>3376 MB high watermark). Without
operator fusion and memory planning, ORT can't reuse intermediate
buffers, so Swin transformer's attention maps stay live in
parallel.

XVI.74 attacks the constraint at the source: `ios/Podfile`
declares `pod 'onnxruntime-objc', '1.24.3'` and relaxes the
`onnxruntime_v2` package's hard-pin via a self-healing pre-amble.
Microsoft never published 1.23.2 to CocoaPods — the trunk repo
skips from 1.23.0 → 1.24.1 — but 1.24.3 contains PR #26263's fix
(merged 2025-10-14), so the regression is structurally gone. The
two-pass loader stays as a safety net for Android and unpatched
installs, but on iOS it's now dead code.

## XVI.75 — FP16 BiRefNet variant for memory fit

XVI.74 unblocked the loader, but BiRefNet-Lite at 1024×1024 input
still hit the iOS 3376 MB ceiling on iPhone 15 Pro Max even with
full graph optimization. The Swin-Tiny backbone in BiRefNet's
decoder produces attention maps whose memory scales quadratically
with input resolution — at 1024 they peak at ~3.4 GB in fp32.

XVI.75 switched the asset to the FP16 variant baked from
`onnx-community/BiRefNet_lite-ONNX/onnx/model_fp16.onnx`:
- File size: 244 MB → 113 MB
- Internal activations: fp16 → peak attention map halves to ~1.7 GB
- Input/output tensors stay fp32 (Cast happens inside the graph)
  so `BiRefNetBgRemoval` needs no Dart-side changes.

Bake pipeline is the same as the v3 FP32 (XVI.73):
`onnx.save(no_external) → onnx.shape_inference.infer_shapes(
data_prop=True) → ORT 1.24 preopt`. The shape-bake step is
preserved as belt-and-suspenders for users running an old
Podfile without XVI.74's pod override. Manifest pin:
`birefnet_lite_fp32` version `2.0-fp16-shapebake`, URL
`birefnet_fp16_v4.onnx`, sha256
`2baf9bb77508d04d5d13c5ed115654a7cecd0cbf7d4dfcf9c746fa096a3fe66d`.

The `id` keeps the `_fp32` suffix as a stable handle (changing it
would force a picker / cache / test plumbing rewrite); the
`version` field captures the FP32 → FP16 transition.
