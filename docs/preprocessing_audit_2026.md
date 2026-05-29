# 2026 Preprocessing & ROI Audit — High-Resolution Quality Recovery

**Triggered:** XVI.80 device-test caught AI Sharpen producing visibly
blurrier output than its input. Root cause: the service hardcoded a
512×512 SQUARE resize for a 1024×768 source — destroying both
detail (~4× downsample) AND aspect ratio. After fixing the sharpen
path (XVI.80, native-resolution rounded to /8 with 1024-long-edge
cap), the user asked: **how many of our other AI services have the
same bug**, and **which best practices from current research could
we adopt to process only the region-of-interest (ROI) instead of
the whole image**?

This document is the answer. It walks every service in
`lib/ai/services/`, classifies each by the quality cost of its
current preprocessing, summarises what 2024–2026 research says
about high-resolution + ROI inference on mobile, and ranks the
fixes by user-facing impact ÷ engineering effort.

---

## 1 · Service-by-service preprocessing inventory

Column legend:
- **Input dims** — what the service forces the source to before
  the model runs.
- **Aspect** — ✓ if preserved, ✗ if a non-square source gets
  squashed into the network's expected square crop.
- **Native?** — does the model actually require those dims, or is
  the underlying architecture fully-convolutional and the resize
  pure self-inflicted damage?
- **ROI?** — is the operation localised (faces, taps) so we already
  process only the relevant region, or global (full image)?
- **Quality cost** — qualitative estimate of how much detail the
  current preprocessing throws away.

### 1.1 Background removal (lib/ai/services/bg_removal/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| MediaPipe SelfieSegmenter | 256×256 (bundled) | ✗ | Fixed | Global | Moderate — designed for video preview |
| MODNet | 512×512 square | ✗ | Dynamic | Global | **HIGH** — portrait-specialist, fine hair detail destroyed |
| RMBG-1.4 | 1024×1024 square (decoded at 4096 native) | ✗ | Dynamic | Global | Moderate — interior pixels native, transition band stuck at 1024 |
| U²-Netp | 320×320 square | ✗ | Dynamic | Global | **SEVERE** — extreme bottleneck, all texture lost |
| RVM (MobileNetV3) | 512×512 square | ✗ | Dynamic | Global | **HIGH** — trained on 1080p video sequences, downsampled to 512 |
| BiRefNet-Lite | 1024×1024 (hard-baked) | ✗ | Fixed at 1024 | Global | Doesn't fit iOS — XVI.77 hidden from picker |

### 1.2 Compose / harmonize (lib/ai/services/compose_on_bg/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| Harmonizer (predict-args) | 256×256 square | ✗ | Dynamic | Global | Minimal — outputs 8 filter params, not pixels |
| ComposeEdgeRefine | Per-source RGBA (no resize) | ✓ | Pure-Dart | ROI (matte transition band) | None |

### 1.3 Denoise / sharpen (lib/ai/services/denoise/, lib/ai/services/sharpen/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| DnCNN (AI Denoise) | 1024×1024 SQUARE | ✗ | Dynamic (any /8) | Global | **HIGH** — same self-inflicted blur the XVI.80 sharpen fix removed |
| NAFNet (AI Sharpen) | Native /8 ≤ 1024 long-edge (XVI.80) | ✓ | Dynamic | Global | Minimal (XVI.80 reference fix) |

### 1.4 Face restore (lib/ai/services/face_restore/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| CodeFormer | 512×512 per-face crop | ✗ on crop | Trained at 512 | **✓ Per-face** | Minimal — 512 IS the native training size |
| RestoreFormer++ (legacy) | 512×512 per-face crop | ✗ on crop | Same | ✓ Per-face | Broken anyway (XVI.79 tombstoned) |

### 1.5 Inpaint (lib/ai/services/inpaint/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| LaMa | 512×512 tile around mask | ✓ on tile | Dynamic | **✓ Mask region** | Moderate — tile crop loses some context; large masks degrade |
| MI-GAN | 512×512 tile around mask | ✓ on tile | Dynamic | ✓ Mask region | Moderate — same as LaMa |

### 1.6 Object detection / depth / segment / select (lib/ai/services/*)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| EfficientDet-Lite0 (object detect) | 320×320 square | ✗ | Fixed | Global | Moderate — small objects suffer |
| YOLOv8n (downloaded, no service yet) | 640×640 square | ✗ | Fixed | Global | n/a (no service code) |
| Depth Anything V2 (placeholder bundle) | 518×518 square | ✗ | Patch-multiple of 14 | Global | n/a |
| MobileSAM encoder | **Native HWC fp32, dynamic** | ✓ | Dynamic | Global encode | None — XVI.78 reference good case |
| MobileSAM decoder | Embedding + point | ✓ | Dynamic | **✓ Per-tap** | None |

### 1.7 Portrait beauty (lib/ai/services/portrait_beauty/)

All four (eye_brighten / face_reshape / portrait_smooth / teeth_whiten)
are **non-ML, landmark-driven heuristics** that already operate per-face
crop. No preprocessing problem — they're the gold standard for ROI.

### 1.8 Preset suggester (lib/ai/services/preset_suggest/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| MobileViT-v2 embedder | 256×256 square | ✗ | Trained at 256 | Global | Minimal — kNN embedding, scale-invariant for similarity |

### 1.9 Selfie / semantic segmentation (lib/ai/services/selfie_segmentation/, semantic_segmentation/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| Selfie Multiclass (TFLite, bundled) | 256×256 square | ✗ | Dynamic | Global | Moderate — class scores at 256, mask upsample loses fine hair |
| DeepLab-v3 PASCAL (sky) | 257×257 square | ✗ | Dynamic | Global | Moderate |
| DeepLab-v3 ADE20K (sky) | 513×513 square | ✗ | Dynamic | Global | Moderate |
| SegFormer-B0 (sky) | 512×512 square | ✗ | Dynamic | Global | Moderate |

### 1.10 Sky replace (lib/ai/services/sky_replace/)

Uses the DeepLab / SegFormer above to predict a sky class mask, then
composites a new sky image into the source. The mask is upsampled
back to source dims — same matte-transition-band issue RMBG has.

### 1.11 Style transfer (lib/ai/services/style_transfer/)

| Service | Input dims | Aspect | Native? | ROI? | Quality cost |
|---|---|---|---|---|---|
| Magenta style-predict (bundled) | 256×256 square | ✗ | Fixed | Global | Minimal — outputs 100-D style vector |
| Magenta style-transfer (bundled) | 384×384 square | ✗ | Fixed | Global | **HIGH** — pixels go in, pixels come out at 384; source > 384 is squashed → preview-only quality |

### 1.12 Super-resolution (lib/ai/services/super_res/)

SuperResX2Service + Real-ESRGAN x4 are *intentionally* a resize (the
whole point is upscaling). Skip from this audit.

---

## 2 · Research findings — best practices 2024–2026

### 2.1 Tile-based inference with halo overlap (NIST 2022, SAHI 2025)

For images larger than the GPU/NPU memory budget, the literature
converges on **overlapping-tile sliding-window** inference:

- Tile size = network's natural input × N (e.g. 512 × 2 = 1024).
- Halo border = half the network's receptive field (typically
  16–64 px for U-Nets, larger for transformers).
- Stride = tile size − halo. Adjacent tile inputs OVERLAP by the
  halo width.
- Outputs join exactly at the seams (the halo region is computed
  twice but used from only one tile, picked by simple distance-
  to-tile-center).

[Exact Tile-Based Segmentation Inference (NIST, 2022)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10914126/)
shows this gives bit-exact results vs whole-image inference
provided the halo ≥ receptive-field/2. The 2025 SAHI (Slicing-
Aided Hyper Inference) extension adds R-tree indexed mask merging
for instance segmentation. See:

[Slicing-Aided Hyper Inference + R-Tree (MDPI 2025)](https://www.mdpi.com/2227-7390/13/19/3079)

Practical implementation: OnnxStream's tile blending demo runs
Stable Diffusion XL on a Raspberry Pi Zero 2 in 298 MB by tiling
the VAE decoder.

[OnnxStream (overlapping tile blend)](https://github.com/vitoplantamura/OnnxStream)

**Applicability to us:** This is the right approach when the source
is bigger than the network can swallow at once — e.g. a 4096×3072
photo through RMBG's 1024 budget. Today we just bilinear-downsample,
losing detail proportional to the scale factor.

### 2.2 Patch-based matting with cross-patch context (HDMatt, 2020 + 2024 follow-ups)

For matting specifically, naive patching produces edge-of-tile
seams in the alpha mask. **HDMatt** introduces a Cross-Patch
Contextual (CPC) module that, for each patch, looks at the
adjacent patches' trimaps and feature maps so the alpha
prediction is consistent across seams.

[High-Resolution Deep Image Matting (HDMatt, 2020)](https://arxiv.org/pdf/2009.06613)

A simpler approach if implementing CPC is too much:
**low-res base + selective high-res patches** — predict a coarse
matte at 512, identify the boundary regions (where alpha is not
0 or 1), then re-run the network ONLY on tiles containing those
boundaries at native resolution. The interior pixels keep the
512-quality prediction (which is fine because they're fully-
opaque or fully-transparent), edges get a 4× upgrade.

[Real-Time High-Resolution Background Matting](https://arxiv.org/pdf/2012.07810)
implements this pattern and achieves 4K-60fps on a desktop GPU.

**Applicability to us:** Drop into RMBG, RVM, BiRefNet, sky
replace. The shared piece is a "matte boundary band detector"
that runs in pure Dart on the low-res mask, returns rects.

### 2.3 RVM is explicitly designed for 1080p / 4K

Per the [RVM repo](https://github.com/PeterL1n/RobustVideoMatting):

> "Real-time inference on any video … 4K 76FPS and HD 104FPS on
> Nvidia GTX 1080 Ti."
>
> "Pre-built CoreML models are available at resolutions of
> 1280×720 and 1920×1080 with both FP16 and int8 quantization."

We're feeding it 512×512 SQUARE. This destroys the temporal-
recurrent state architecture's intended use case — and matches the
user's "hair detail soft" complaints. RVM has dynamic input dims
in the PyTorch model; the ONNX export we have is unfortunately
512-locked. Best path: re-export at 1024 (or use the published
1080p CoreML model directly via a CoreML-only code path).

### 2.4 MI-GAN's recommended pipeline is what we already do

Per the [MI-GAN ONNX docs](https://www.iopaint.com/models/erase/migan):

> "Pipeline: uint8→float32, crop around mask, resize to 512×512,
> normalise, inference, resize back, blend, float32→uint8."

That's exactly our `_renderMaskPng` → 512 tile flow. The fix
we'd want for MI-GAN/LaMa is the same as RMBG — tile-and-blend
when the mask region is larger than 512, instead of forcing the
entire crop to 512.

### 2.5 SAM detect-then-process (Meta SAM 2/3, 2024–2025)

Meta's [SAM 3](https://ai.meta.com/blog/segment-anything-model-3/)
made the "tap-to-edit" pattern mainstream:

> "Creators can apply dynamic effects to people or objects in their
> videos — simplifying a complex editing workflow to just one tap.
> Auto-segment subjects in photos using text ('main dancer',
> 'car', 'sky'), apply filters, color changes, or effects to only
> the segmented regions."

We shipped MobileSAM tap-to-segment in XVI.78 — the same pattern
generalises to: every full-image AI op can be wrapped in a
"target this subject" gate by chaining MobileSAM → mask → run AI
only on the mask region (or just on the cropped subject bbox).

### 2.6 Sparse refinement for high-resolution segmentation (MIT-Han Lab 2024)

[Sparse Refinement for Efficient High-Resolution Semantic Segmentation](https://arxiv.org/pdf/2407.19014)
demonstrates that only ~10% of pixels in a typical segmentation
map are "uncertain" (near class boundaries). Process the easy 90%
at low res, then re-classify ONLY the uncertain pixels at native
resolution.

**Applicability to us:** Sky replace + selfie multiclass mask
quality goes up dramatically with no per-pixel cost increase on
the easy regions.

### 2.7 Guided filter upscale (alternative to bilinear)

For mask upsampling specifically, [guided image filter (He et al
2010)](https://kaiminghe.github.io/eccv10/) preserves the source's
edges in the mask far better than bilinear. The mask boundary
"snaps" to the underlying photo's gradients. Implementation is
~50 lines of pure Dart against an integral-image; no model
needed.

This is a one-off fix that benefits EVERY service whose output is
a small mask upsampled back to source dims (selfie_multiclass,
sky_replace, RMBG, BiRefNet, MobileSAM).

---

## 3 · Prioritized fix recommendations

Sorted by `user-visible quality lift × users affected ÷ engineering effort`. Each is a self-contained phase.

### Tier A — high impact, low effort (do these first)

**A1 — AI Denoise: adopt XVI.80's native-resolution pattern.**
Mechanical copy-paste of `computeTargetDims` + `chwToRgba`
rectangular signature from the sharpen service into the denoise
service. DnCNN's manifest comment explicitly says "any /8 works".
Same bug as the sharpen fix, same fix. ETA: 1 commit, ~40 LOC
+ 6 tests.

**A2 — Guided filter mask upsample utility + drop-in for sky / selfie / RMBG / BiRefNet matte upscale.**
Pure-Dart implementation, one file, no model. Wire as a swap in
the post-inference path of every service that currently bilinearly
upsamples a low-res mask to source dims. Quality lift is most
visible at hair/fur/lace edges — exactly what the user keeps
flagging on RMBG. ETA: 2 commits (1 lib + 1 wiring), ~150 LOC
+ 12 tests.

**A3 — MobileSAM "detect-then-target" wiring on any AI op.**
We have MobileSAM. We have face restore (CodeFormer) running ROI-
only on detected faces. The same pattern can be exposed via a
"Smart Target" toggle on every AI op: tap subject → SAM → mask →
run the op on `subject_bbox + 30% padding`, blend back. Sky replace
becomes "tap any sky region → SAM with text-prompt 'sky' → swap".
Object inpaint becomes the XVI.78c flow we already have. ETA: 1
phase per AI op, ~80 LOC per wiring.

### Tier B — high impact, medium effort

**B1 — U²-Netp retirement OR 512 bump.**
The 320×320 bottleneck destroys quality and U²-Netp is rarely
chosen anyway (RMBG is better at the same model size). Cheap
option: hide from the picker via the XVI.77 `visibleInPicker`
mechanism. Better option: re-export from PyTorch at 512 (~30 min
of bake-script work, follows `scripts/onnx_export/inline_onnx_model.py`).
ETA: 1 commit, ~10 LOC for the hide.

**B2 — RVM at 1024 (or wire to ByteDance's published 1080p
CoreML model).**
The current 512 square is the worst-case mismatch in the audit.
Two paths:
  i. Re-export the PyTorch RVM at 1024 → ONNX, host on the GitHub
     release. ~1 hr work in the bake venv we already have.
  ii. Use [DmitriySidnev/RobustVideoMatting](https://github.com/DmitriySidnev/RobustVideoMatting)'s
      published CoreML model at 1280×720 / 1920×1080 directly via
      a new `CoremlRvmBgRemoval` service that bypasses ORT
      entirely. iOS-only; quality should be reference.
ETA: 2–3 commits, ~250 LOC.

**B3 — Tile-based RMBG / BiRefNet matte at >1024 source.**
For 4K+ sources (modern iPhones shoot ~4032×3024), the
single-shot 1024 mask underuses the source data. Implement
512-stride / 256-halo tile loop in pure Dart, blend with
distance-to-tile-center weighting. Combines naturally with the A2
guided-filter upscale for the easy regions. ETA: 1 phase, ~300
LOC + 10 tests.

### Tier C — medium impact, larger effort

**C1 — Inpaint mask-aware tiling for large masks.**
Today, when the user paints a big mask (say, half the image),
LaMa/MI-GAN crops the mask region to a single 512 tile and
loses fine context. Better: tile the mask region into overlapping
512 patches, run the model on each, blend with the existing
feather logic. Combines with A3 (SAM tap-to-inpaint generates
naturally-bounded masks that DO fit a single tile, so this is
only for the brush-painted big-mask case). ETA: 2 commits, ~200
LOC.

**C2 — Sparse-refinement for sky / selfie segmentation.**
Run DeepLab/SegFormer at the current 256/512 to get a coarse
mask, identify uncertain pixels (logit margin < threshold),
re-classify only those at native resolution. Cuts wall-time vs
"run at native everywhere" by ~5× while delivering 80% of the
quality lift. ETA: 1 phase per segmentation service, ~150 LOC each.

### Tier D — research-mode

**D1 — Patch-based matting with cross-patch context (HDMatt
port).** The full 2020 paper port. Worth doing only if Tier B/C
land and the user still wants more matte fidelity. ETA: 1 month.

**D2 — Re-export Magenta style-transfer at 1024.**
The 384 cap is hard-wired into the bundled TFLite. Bake an ONNX
port from arbitrary-style-transfer's PyTorch source. ETA: 1 week.

---

## 4 · Suggested execution order

If we ship two phases per device-test cycle:

| Round | Phases | User-visible win |
|---|---|---|
| 1 | A1 (denoise) + A2 (guided filter) | Denoise no longer blurs; bg-removal hair detail visibly sharper |
| 2 | A3 (SAM-target on sky replace) + B1 (U²-Netp hide) | "Tap to change sky" UX; picker cleaned up |
| 3 | B2 (RVM 1024) + C2 (sparse selfie segment) | Premium matter actually premium; portrait selection cleaner |
| 4 | B3 (tile RMBG) + A3 wiring on inpaint | 4K source quality matched in matte; "tap to remove object" |
| 5+ | C1 (mask tiles) + research items | Long-tail edge cases |

This delivers measurable quality lift on EVERY round without any
single change being risky — same approach that produced XVI.78
(MobileSAM) and XVI.80 (sharpen native-res) cleanly.

---

## Addendum — XVI.103–105 decode-resolution sweep (2026-05)

Triggered by a device test showing **AI Denoise + AI Deblur still
blurry** after the XVI.102 wet/dry blend. The log
(`AiDenoiseService source decoded w=768 h=1024` on a 4284×5712
source) revealed the blend ran on a 1024-capped buffer — the model
AND the blend were at 768×1024, so the cutout upscaled ~2.5× on the
preview / 5.6× on export. This is the XVI.80 resize bug one stage
earlier (DECODE, not the model resize).

A parallel audit of **every** `decodeFileToRgba` call site classified
each AI service by (a) its decode tier and (b) whether it returns a
FULL-FRAME `ui.Image` composited onto the canvas. Verdicts:

| Service | Decode tier (pre-fix) | Full-frame output? | Verdict | Fixed in |
|---|---|---|---|---|
| AI Denoise (DnCNN) | 1024 (default) | yes | **BUG** | XVI.103 |
| AI Deblur (NAFNet) | 1024 (default) | yes | **BUG** | XVI.103 |
| MODNet bg-removal | 1024 (default) | yes | **BUG** | XVI.104 |
| RVM bg-removal | 1024 (default) | yes | **BUG** (XVI.86 fixed tensor dims, not decode) | XVI.104 |
| Face restore (CodeFormer) | 1024 (default) | yes (whole frame) | **BUG** | XVI.104 |
| Hair/clothes recolour | 1024 (default) | yes | **BUG** | XVI.104 |
| Inpaint (LaMa) | 2048 (preview) | yes (tile→base) | minor → fixed | XVI.105 |
| MI-GAN inpaint | 2048 (preview) | yes (tile→base) | minor → fixed | XVI.105 |
| RMBG bg-removal | 4096 (native) | yes | **OK — reference** | — |
| Sky replace | 2048 (preview) | yes | DEFERRED (see below) | — |
| Style transfer (Magenta) | 384 (fixed model) | yes | DEFERRED (see below) | — |
| Super-res ×2 / ×4 | inputSize (by design) | upscaler | OK | — |
| Depth estimator | 1024 (default) | depth-map sampler | OK (not a pixel layer) | — |
| MobileSAM | 1024 | mask only | OK | — |
| Preset embedder / style-predict | 256 | vector | OK | — |
| Portrait beauty (eye/teeth/smooth/reshape) | 2048 (preview) | yes | OK (preview-quality contract) | — |
| Presets / 3D LUT / tone-curve / export | n/a — parametric | full-res shader chain | **OK — clean** | — |

**New policy constant:** `BgRemovalImageIo.fullFrameDecodeDimension`
(= `nativeQualityDecodeDimension` = 4096) names the rule "full-frame
AI outputs decode at native quality" at every call site, pinned by
`test/ai/services/full_frame_decode_resolution_test.dart`. In every
case the model still runs at its own ≤1024 input (letterbox /
computeTargetDims / per-face crop), so **inference cost is
unchanged** — only the decode + final encode + blend move to native
res, which is where the preserved (non-model) pixels live.

### Deferred (with rationale)

- **Sky replace (2048).** The replacement sky is a procedural
  gradient (low-frequency, survives upscale); only the preserved
  foreground softens mildly on >2048 export. Bumping the DECODE to
  4096 would 4× the per-pixel mask-build + SegFormer-union + colour-
  gate cost (~1.7 s → ~6 s) for a small gain. The correct fix is to
  DECOUPLE mask resolution from composite resolution (build the mask
  at ~2048, bilinear/guided-upsample it to native, composite the
  native source + native sky through it) — the RMBG pattern. Tracked
  as a follow-up; not a regression vs the reported sky-bleed issue
  (fixed in XVI.100).
- **Style transfer (Magenta, 384²).** The bundled INT8 transfer
  model has a hard-baked `[1,384,384,3]` input/output, so the
  stylized result is fundamentally 384 px. A plain upscale-to-native
  doesn't improve sharpness (same bilinear stretch, moved earlier).
  The real fix is a **joint-bilateral / guided upsample** of the
  stylized output using the full-res content as the guide (snaps the
  stylized colours to the source edges), or swapping to a dynamic-
  input style model. Both are visually-uncertain changes that can't
  be validated in `flutter test`; deferred rather than shipped blind.
  Not user-reported.

---

## Sources

- [HDMatt — High-Resolution Deep Image Matting (Patel et al, AAAI 2021)](https://arxiv.org/pdf/2009.06613)
- [Real-Time High-Resolution Background Matting (Lin et al, CVPR 2021)](https://arxiv.org/pdf/2012.07810)
- [Robust Video Matting (Peter L1n, WACV 2022)](https://github.com/PeterL1n/RobustVideoMatting)
- [DmitriySidnev/RobustVideoMatting — pre-built CoreML 1280×720 + 1920×1080 + int8](https://github.com/DmitriySidnev/RobustVideoMatting)
- [LaMa — Resolution-robust Large Mask Inpainting (Suvorov et al, WACV 2022)](https://github.com/advimman/lama)
- [MI-GAN: A Simple Baseline for Image Inpainting on Mobile Devices (ICCV 2023)](https://github.com/Picsart-AI-Research/MI-GAN)
- [Exact Tile-Based Segmentation Inference (NIST, J Res 2022)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10914126/)
- [Slicing-Aided Hyper Inference + R-tree (MDPI 2025)](https://www.mdpi.com/2227-7390/13/19/3079)
- [Sparse Refinement for Efficient High-Resolution Semantic Segmentation (MIT-Han Lab, ECCV 2024)](https://arxiv.org/pdf/2407.19014)
- [Meta SAM 3 — Segment Anything with Concepts (2025)](https://ai.meta.com/blog/segment-anything-model-3/)
- [OnnxStream — overlapping tile blending demo](https://github.com/vitoplantamura/OnnxStream)
- [Guided Image Filter (He et al, ECCV 2010)](https://kaiminghe.github.io/eccv10/) — for mask upsampling
- [Attention Guided Filter and Refinement Feature Network (Knowledge-Based Systems, Mar 2025)](https://www.sciencedirect.com/science/article/abs/pii/S0950705125003405)
