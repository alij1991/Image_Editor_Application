# Editor Audit + Improvement Plan

*Section-by-section audit (2026-04-28), triggered by the XVI.22 gamma
regression. Three Explore agents read every slider's write/read pair
and round-tripped every layer; three research agents surveyed
Lightroom Mobile / Snapseed / Photomator / Capture One Mobile / VSCO /
Photoroom / Apple Photos / Affinity / Procreate / Darkroom 7 SOTA as
of 2025-2026. Findings + impact-ranked phase list per section below.*

## 0. Audit summary

**Bugs found, all fixed:**
- **XVI.22 — gamma slider was a permanent no-op** since the initial
  commit. The OpSpec wrote to `EditOpType.levels` with paramKey
  `'gamma'`, but `EditPipelineExtensions.levelsGamma` read from a
  non-existent `EditOpType.gamma` op with key `'value'`. Slider
  output silently degraded to identity (1.0) regardless of position.
  Fixed + regression test pinned the slider→reader contract.

**Bugs NOT found** — every other audited surface is correct:
- All 13 scalar Light/Color sliders (exposure, brightness, contrast,
  highlights, shadows, whites, blacks, levels.{black,white,gamma},
  temperature, tint, saturation, hue, vibrance) have matching OpSpec
  ↔ reader pairings.
- All Effects shader uniforms align with their Dart wrappers
  (vignette, grain, bilateralDenoise, tiltShift, motionBlur,
  chromaticAberration, pixelate, halftone, glitch).
- Every Geometry op (crop, rotate, flipH/V, straighten,
  perspectiveWarp) round-trips through `geometry_state.dart` cleanly.
- Every layer kind (Text/Sticker/Drawing/Adjustment) round-trips
  through `toParams`/`fromOp` without dropping fields, and every
  AdjustmentKind has a dedicated paint branch in `LayerPainter`.
- Every AI service applies the dispose-guard pattern correctly +
  throws typed exceptions on failure.
- Every built-in preset references registered op types + asset paths
  that exist on disk.

The codebase is in good shape. The XVI.22 regression was a single
typo from the initial commit — every later phase passed quality
gates because the gamma slider just *felt* like nothing, not like an
error. Below is the section-by-section audit + improvement plan
that came out of the parallel research dispatch.

---

## 1. Light section

**State:** solid. Sliders work, shaders match. XVI.22 closed the one
historical gap (gamma reader). Existing surfaces:

| Op | Sliders | Math | Notes |
|---|---|---|---|
| Exposure | 1 (-2..2 stops) | linear-light gain in `color_grading.frag` | matrix-composable |
| Brightness, Contrast | 1 each (-1..1) | matrix | composable |
| Highlights, Shadows, Whites, Blacks | 4 (-1..1) | luminance-masked tone in `highlights_shadows.frag` | works |
| Levels (black/white/gamma) | 3 | `levels_gamma.frag` | XVI.22 fix landed |
| Tone curve | per-channel (Master/R/G/B) point curves | Hermite + 256×4 LUT bake | works |
| Clarity | 1 (-1..1) | inline 9-tap unsharp midtone-masked | XI.0.5 fix made it real |
| Dehaze | 1 (-1..1) | midtone stretch (placeholder) | functional, not state-of-the-art |

**Research gaps vs. 2026 SOTA (Lightroom Mobile, Photomator, Darkroom 7):**

| Gap | Impact | Effort |
|---|---|---|
| **Texture slider** — distinct from Clarity. Same shader at smaller sigma (~3px vs ~30px) for fine-detail enhance without midtone bias. The single biggest "feels like Lightroom" gap. | High | XS |
| **Luma tone curve** — 5th tab on the Curves panel. Operates on Y only (no chroma shift). Implementation: bake luma curve into LUT applied as `out = rgb * curve(Y)/Y`. | High | S |
| **Dehaze via dark-channel prior** (He et al. 2009) — replace the midtone-stretch placeholder with the real algorithm + edge-aware refinement. Recovers atmosphere on actual hazy photos. | Medium | M |
| **Auto-tone (on-device)** — small CNN (~1-3 MB) regressing histogram features → 8-12 slider deltas. Lightroom Sensei does this in <10 MB. | Medium | L |
| **Linear-light verification on Highlights/Shadows** — confirm the masked tone-curve runs on Y in linear-light, not sRGB-perceptual. sRGB-naive shadow lifts desaturate; current shader needs a read-through. | Medium | XS |

### Phase plan

- **XVI.23 — Texture slider** (XS). New OpSpec under Light category, new shader at small-sigma + no midtone mask. Identity 0, range [-1, 1]. Reuse the clarity infrastructure: copy `clarity.frag` to `texture.frag` with `r = 0.5` instead of `r = 1.5`, drop the midtone mask, halve the amount scale. New `_texturePass` builder. Single regression test on the OpSpec ↔ reader path.
- **XVI.24 — Luma tone curve** (S). Add a 5th `ToneCurveSet.luma` channel. Bake the luma curve into the existing 256×4 LUT alongside Master/R/G/B (5×4 → goes into a 256×8 LUT or a separate single-channel LUT). Sample with `out = rgb * lutY(Y)/Y` in `curves.frag`. UI: extend `CurvesSheet` chips with a Y chip.
- **XVI.25 — Linear-light verification on Highlights/Shadows** (XS). Add a unit test that asserts a saturated red pixel under shadows=+0.5 keeps its hue (no desaturation). If it fails, fix the shader to operate on Y-in-linear-light + chroma re-attach.
- **XVI.30 — Dehaze (dark-channel prior)** (M). Defer until after the
  XVI.23-24 quick wins land. Replace `dehaze.frag` body with: down-scale → estimate dark channel → atmospheric light A → transmission map → recover with `J = (I - A) / max(t, 0.1) + A`. Keep the parametric slider but make it actually do something on hazy photos.

---

## 2. Color section

**State:** solid. All sliders correct.

| Op | Sliders | Math | Notes |
|---|---|---|---|
| Temperature, Tint | 2 | `color_grading.frag` (linear-light) | XI.0.6 sign-flip fixed |
| Saturation, Hue | matrix-composable | matrix | XI.0.4 column-major fix |
| Vibrance | 1 | `vibrance.frag` | works, no skin-protect today |
| HSL | 8 bands × 3 (H/S/L) | per-band cosine-weighted hue mask in `hsl.frag` | works |
| Split toning | hi-color + lo-color + balance | `split_toning.frag` | works, dated UX |
| Channel mixer | bespoke matrix | matrix | works |
| Color grading | composed matrix | matrix | works |

**Research gaps vs. 2026 SOTA:**

| Gap | Impact | Effort |
|---|---|---|
| **Color Grading 3-wheel panel** — Lightroom replaced "Split Toning" with shadows/midtones/highlights H/S wheels + global wheel + balance + blending in Oct 2020. Photomator and Darkroom 7 followed. Single split-tone is dated. | High | M |
| **Vibrance with skin-protect hue mask** — current implementation looks like dumb `(1-S)*slider`. Lightroom's vibrance attenuates in the orange-red band (~25° centre, ~30° width) so faces don't go neon. ~20 LOC shader change. | High | XS |
| **Hue-wheel scrubber** — Polarr 6.x and Photoroom Pro 2024 let you tap a colour on the canvas and drag to scrub its hue/sat. Modernises HSL UX without adding a new model. | Medium | M |
| **Oklch colour space for HSL math** — Pixelmator Pro 3.6 (2024) shipped Oklch hue/sat. Better hue stability under saturation/lightness changes than HSL. Drop-in upgrade for `hsl.frag`. | Medium | S |
| **Kelvin temperature for raw + heuristic for JPEG** — Lightroom Mobile shows Kelvin (2000-50000K) when raw metadata is present; falls back to scalar for JPEG/HEIC. We always show a scalar. | Low | S |
| **Auto white balance (rendered JPEG)** — Barron 2017 fast Fourier color constancy, or a 50 KB CNN predicting (R/G, B/G) gains. Cheap win. | Medium | M |

### Phase plan

- **XVI.26 — Vibrance skin-protect** (XS). Add a `skinHueAttenuator(H)` cosine in `vibrance.frag` (centre 25°, half-width 30°). Multiply the (1-S)·strength gain by it. Existing OpSpec range is fine. Regression test asserts an orange skin-tone pixel sees ≤ 50% of vibrance applied vs. a blue sky pixel.
- **XVI.27 — Color Grading 3-wheel panel** (M). New `EditOpType.colorGrading` (already registered as a pseudo-op — promote to a real op). Three H/S wheel widgets + a global wheel + balance + blending. New `color_grading_3wheel.frag`. Replace SplitToningPanel with this. Keep `splitToning` op for back-compat.
- **XVI.28 — Oklch HSL** (S). Convert `hsl.frag` to operate in Oklch instead of HSV. The maths: sRGB → linear → Oklab → Oklch (rotate hue, scale chroma) → Oklab → linear → sRGB. ~60 lines GLSL. No UI change; the result is just better hue stability.
- **XVI.31 — Kelvin temperature when EXIF allows** (S). When the source has `WhiteBalance` / `ColorTemperature` EXIF tags, expose Kelvin. Fall back to scalar otherwise. Implementation: parse EXIF on session start, set a `temperatureMode` flag the slider widget reads.
- **XVI.32 — Auto WB** (M). Fast-Fourier color constancy or small CNN. Pre-bake on the proxy. Adds an "Auto" button next to the WB sliders.

---

## 3. Effects section

**State:** working. Vignette / grain / tilt-shift / motion-blur /
chromatic-aberration / pixelate / halftone / glitch all wired
correctly.

**Research gaps:**

| Gap | Impact | Effort |
|---|---|---|
| **Subject-aware vignette** — toggle that intersects the vignette mask with `BgRemovalService` output so the subject's face/torso doesn't darken. One-line shader change + a new `protectSubject` param. | High | XS |
| **Luminance-banded grain** — Dehancer's 3D-particle grain is too heavy, but per-band amplitude (3 sliders: shadows/midtones/highlights) with per-channel decorrelation matches the perceptual quality at 50 LOC. Blue-noise tile beats Perlin at the same cost. | Medium | S |
| **Lens Blur with on-device depth** — Lightroom Mobile's Lens Blur (Adobe Sensei) is the marquee 2024-2025 feature. Bundle MiDaS-Small or Depth-Anything-V2-Small (~20 MB INT8), bake depth on commit, render a multi-tap disc shader weighted by circle-of-confusion. | High | L |
| **EXIF lens auto-correct (chromatic aberration)** — Lensfun-style profile DB matched against EXIF Make/Model/LensModel. CA shader exists, just needs auto-population. ~1 MB JSON. | Medium | S |
| **Path motion blur** — Photoshop Mobile's path-blur: user draws a curve, blur direction follows it. Niche. | Low | M |

### Phase plan

- **XVI.33 — Subject-aware vignette** (XS). New `protectSubject: bool` param on the vignette op. When true, the pass builder threads the latest `BgRemovalService` mask into the shader's second sampler. Shader does `final = mix(vignetted, src, mask * protectStrength)`.
- **XVI.34 — Banded grain + blue-noise** (S). Replace `grain.frag` Perlin with a sampled blue-noise tile + 3 luminance bands. New OpSpec params: `shadowAmt`, `midAmt`, `highlightAmt` keyed `shadows`/`mids`/`highs`. Keep existing `amount` as a master multiplier.
- **XVI.35 — EXIF lens auto-correct** (S). Bundle `assets/lens_profiles.json` with top 200 phone + DSLR lens entries (distortion polynomial coefs, vignette profile, CA tilt). Auto-populate the chromatic aberration + vignette params on session start when EXIF matches.
- **XVI.40 — Lens Blur with depth** (L). Bundle Depth-Anything-V2-Small ONNX (~20 MB INT8). New AI service `lib/ai/services/depth/depth_estimator.dart` mirroring the bg_removal service shape. New `lens_blur.frag` doing disc-kernel blur weighted by circle-of-confusion derived from the depth map. UI: focus tap-to-set, aperture slider (bokeh radius), bokeh shape picker (circle / 5-blade / cat's-eye). The marquee differentiator vs. Snapseed.

---

## 4. Detail section

**State:** working. Sharpen + bilateral denoise.

**Research gaps:**

| Gap | Impact | Effort |
|---|---|---|
| **Guided filter denoise** (Kaiming He 2010) — strictly better than bilateral at the same cost. O(N) regardless of kernel size, no flat-region staircasing. Drop-in replacement for `bilateral_denoise.frag`. | High | S |
| **Texture slider** — covered in Light section (XVI.23). Mid-frequency unsharp distinct from Sharpen + Clarity. | High | XS |
| **Bundled neural denoise (FFDNet)** — for JPEG inputs, a small ~5 MB FFDNet ONNX outperforms guided filter on chroma noise. Bundle as a "Denoise (AI)" tier behind a button. | Medium | M |
| **Deconvolution sharpen ("AI Sharpen")** — Topaz Sharpen AI ships three specialised models (motion / focus / softness). Mobile-feasible with a single ESRGAN-class deblur ONNX. | Medium | L |

### Phase plan

- **XVI.36 — Guided filter denoise** (S). Replace `bilateral_denoise.frag` body with He et al. 2010's guided filter. Same Dart wrapper, same params (sigmaSpatial → radius, sigmaRange → epsilon). Keep the `denoiseBilateral` op type for back-compat with persisted pipelines. Existing tests already cover the shader pass — verify they still pass under the new math.
- **XVI.50 — FFDNet denoise tier** (M). Bundle `assets/models/bundled/ffdnet_color.onnx` (~5 MB INT8). New AI service. Adds a "Denoise (AI)" button next to the existing slider that pre-processes the source proxy before the shader chain.
- **XVI.55 — AI Sharpen** (L). Bundle a small deblur ONNX. New AI service. Same scaffolding pattern as super-resolution.

---

## 5. Geometry section

**State:** working. Crop / rotate / flip / straighten / perspective.

**Research gaps:**

| Gap | Impact | Effort |
|---|---|---|
| **Auto-straighten in editor** — `estimateDeskewDegrees` already ships in Scanner via Hough lines. Lift it to the editor's Geometry panel. ~30 lines of plumbing. Free win. | High | XS |
| **Smart crop** — bounding-box-pad of `BgRemovalService` mask to target ratio gives a free "Smart crop" button. Photoroom does exactly this. | Medium | S |
| **Guided Upright perspective** — Lightroom Mobile lets the user draw 2-4 lines on the photo; the homography solver makes them parallel/perpendicular. The math (OpenCV `getPerspectiveTransform`) already ships in Scanner. The work is the interactive line-drawing UX. | High | M |
| **Lens distortion correction** — Lensfun-style polynomial. Same EXIF DB as XVI.35 chromatic aberration; just adds the distortion + vignette correction passes. | Medium | M |
| **Generative Expand** — cloud-only in 2026 for production quality (Firefly / FLUX / Gemini). Hooks-shape only for now. | Low | L |

### Phase plan

- **XVI.37 — Auto-straighten in editor** (XS). Lift `estimateDeskewDegrees` from `lib/features/scanner/` to a shared `lib/engine/geometry/auto_straighten.dart`. Add an "Auto" button to the Geometry panel that fills the straighten op's `value` parameter.
- **XVI.38 — Smart crop** (S). New "Smart" crop preset that runs bg-removal (cached if already produced for compose), pads the subject bbox to the user's target ratio. Falls back to centre-crop if bg-removal fails (silent fallback per project convention).
- **XVI.45 — Guided Upright** (M). New `EditOpType.guidedUpright` with 2-4 user-drawn lines stored as normalised `[x1,y1,x2,y2]` quads. Solver in `lib/engine/geometry/guided_upright.dart` returning a 3x3 homography matrix. Persist via the geometry state. The UX (interactive line draw on canvas) is most of the work.
- **XVI.46 — Lens distortion** (M). Same EXIF DB as XVI.35. New shader pass that warps via lens polynomial. Auto-applied when EXIF matches a profile.

---

## 6. Layers section

**State:** working. TextLayer / StickerLayer / DrawingLayer /
AdjustmentLayer all round-trip and paint correctly.

**Research gaps:**

| Gap | Impact | Effort |
|---|---|---|
| **Blend modes** — currently we only have linear stacking. Procreate ships 26, Photoshop 27. The minimum useful set: Normal, Multiply, Screen, Overlay, SoftLight, Color, Luminosity, Add, Difference (8-10). Table-stakes for any "real" mobile editor in 2026. | High | M |
| **Layer effects** — Drop Shadow / Stroke / Inner Glow / Outer Glow. Procreate, Photoshop, Affinity ship them. ~2 days of shader work; instantly closes the Procreate gap for stickers/text. | High | M |
| **Pencil pressure mask painting** — Capture One Mobile, Procreate, Affinity all consume `PointerEvent.pressure` + `tilt`. We currently treat the brush as constant opacity. | Medium | S |
| **Auto-subject mask source** — one-tap "Subject" mask via `BgRemovalService`. Photomator + Lightroom + Capture One all ship this. We have the service; just needs a button. | High | XS |
| **Adjustment layers as Z-order** — promote a group of `EditOperation`s to a "scoped layer" with its own mask. Affinity Photo iPad + Photoshop Mobile work this way. Significant infra change. | Medium | L |
| **Text on path** — Procreate added it 2024. ~600 LOC for the math; UX is the rest. | Medium | L |
| **Smart objects / linked layers** — defer indefinitely; reviewers consistently flag them as low-engagement on mobile. | — | — |

### Phase plan

- **XVI.39 — Auto-subject mask source** (XS). New "Subject" button in the mask painting overlay. One tap → bg-removal cached mask becomes the layer mask.
- **XVI.41 — Pencil pressure mask painting** (S). Wire `PointerEvent.pressure` and `tilt` into the brush's per-stroke opacity and hardness. Pure additive; no breaking changes.
- **XVI.42 — Layer effects** (M). New per-layer effects panel with 4 effects: Drop Shadow / Stroke / Inner Glow / Outer Glow. Each is one shader pass post-layer. Persisted as `LayerEffect` records on `ContentLayer`.
- **XVI.43 — Blend modes** (M). New `LayerBlendMode` enum already exists with `normal/multiply/screen/etc`; verify all 9 modes are implemented in `LayerPainter` (currently only Normal renders). Add a blend-mode picker to the layer tile.
- **XVI.60 — Adjustment-layer Z-order rendering** (L). Promote groups of `EditOperation` to scoped layers with their own mask. Significant rendering refactor. Defer until after the smaller wins.
- **XVI.61 — Text on path** (L). Bezier path glyph layout. Defer until after blend modes + layer effects ship.

---

## 7. AI section

**State:** scaffold. Real models for bg-removal (RVM), face detection
(MediaPipe Face Mesh), portrait beauty (eye/teeth/smooth). Sky
heuristic. Style transfer + inpaint + super-resolution + face-reshape
+ hair-clothes recolour are scaffolds awaiting bundled models.

**Research gaps (2026 frontier):**

| Gap | Model | Size (INT8) | Latency | Impact |
|---|---|---|---|---|
| Bg removal — hair, fur, transparency | **BiRefNet-Lite** | ~44 MB | ~250 ms @ 1024² | High |
| Face landmarks — 478 points + blendshapes | **MediaPipe Tasks FaceLandmarker** (replaces older Face Mesh) | ~5 MB | <10 ms | High |
| Skin smooth — believable | **Frequency separation + bilateral grid** (math, not new model) | 0 | <20 ms | High |
| Sky replace | **SegFormer-B0** trained on ADE20K-sky | ~14 MB | ~100 ms | Medium |
| Inpaint / object remove | **MI-GAN** (Picsart, 2023) | ~30 MB | ~500 ms | High |
| Super-resolution | **Real-ESRGAN-x2plus** tile-based | ~17 MB | 2-4 s for 12 MP | Medium |
| Face restore | **GFPGAN-1.4** or **CodeFormer** | ~80 MB | 2-5 s | Medium |
| Hair / clothes mask | **MediaPipe Selfie Multiclass** (replaces single-class) | ~3 MB | <20 ms | Medium |
| Compose harmonisation | **Harmonizer (ECCV 2022)** or **MKL-Harmonizer (AAAI 2026)** | 10-15 MB | ~50 ms | High |
| Style transfer | **PhotoWCT2** (photoreal) | ~80 MB | ~1 s | Medium |
| AI preset suggestion | **MobileViT v2 / CLIP-mobile** + KNN over preset embeddings | ~30 MB | ~50 ms | Medium |
| Generative inpaint / extend | All cloud-bound at production quality in 2026 | — | — | Low (defer) |

These line up with the harmonisation plan from XVI.20 preamble (which
already pre-charted XVI.21-31 for compose-on-bg). The AI plan extends
that:

### Phase plan

- **XVI.44 — Migrate to MediaPipe Tasks FaceLandmarker** (S). 478 points + blendshapes (52 ARKit-compatible coefficients) instead of 468. Blendshapes give us automatic smile-detect + eye-open-detect for free. Replace the older Face Mesh wiring in `lib/ai/services/face_detect/`.
- **XVI.47 — Selfie Multiclass for hair/clothes** (S). Replace single-class selfie segmentation with MediaPipe Selfie Multiclass — gets hair AND clothes masks from one model. Existing `hair_clothes_recolour_service.dart` keeps its LAB-lift logic, just gets cleaner masks.
- **XVI.48 — Bilateral-grid skin smooth** (M). Replace the simple Gaussian blur in `portrait_smooth_service.dart` with frequency separation: bilateral split → smooth low-freq → preserve high-freq → blend with face mask. The "math, not new model" path that gets you 80% of FaceApp quality.
- **XVI.49 — BiRefNet-Lite bg removal** (M). Bundle ~44 MB INT8 ONNX as a "high quality" toggle alongside RVM. RVM stays the fast path; BiRefNet handles hair/fur/transparency.
- **XVI.51 — MI-GAN inpaint** (L). Bundle ~30 MB INT8. New service replaces the inpaint scaffold. Mask-aware on-device inpainting works on phones in 2026.
- **XVI.52 — SegFormer-B0 sky** (M). Replace the heuristic sky detector with a real model. Curated set of 20-30 sky textures bundled in `assets/skies/`.
- **XVI.53 — Real-ESRGAN-x2 super-res** (L). Bundle ~17 MB tile-based. Replaces the super-res scaffold. Target 2x as default; warn on 4x latency.
- **XVI.54 — Harmonizer compose** (M). Bundle ~15 MB. Plugs into the compose-on-bg pipeline as the harmonisation tier. See harmonisation_plan.md for full plan; this is the XVI.28 of that plan, renumbered into the editor plan.
- **XVI.56 — GFPGAN/CodeFormer face restore** (L). New "Restore Faces" feature. Detect faces → crop → run GFPGAN INT8 → paste back.
- **XVI.57 — PhotoWCT2 photoreal style transfer** (L). Replaces the artistic Magenta scaffold for "match this photo's look." See harmonisation_plan.md XVI.31.
- **XVI.58 — AI Preset suggestion** (M). MobileViT v2 (~30 MB) embeds the source proxy. KNN against pre-baked preset embeddings. Adds a "For You" rail to the preset strip.

---

## 8. Presets section

**State:** solid. 25+ built-in presets, all op types registered, all
LUT assets present, preset thumbnail cache uses `(previewHash,
preset.id)` keying which prevents stale-cache footguns.

**Research gaps:**

| Gap | Impact | Effort |
|---|---|---|
| **Real-render thumbnails for non-matrix presets** — the matrix-only `PresetThumbnailRecipe` is right for color-only presets but breaks down for curves/grain/vignette. Lightroom Mobile renders the user's photo at thumbnail size (~128 px) through every preset's full chain. | Medium | M |
| **0-200 % Amount slider** — Lightroom + VSCO ship 0-200 % (extrapolation). We ship 0-150 %. Niche; "100-200" range is rarely used. | Low | XS |
| **Preset taxonomy reorg** — 5-8 categories beats Lightroom's 12 tabs for a 25-40 preset set. Recommended: For You / Yours / B&W / Cinematic / Film / Portrait / Landscape / Vintage. | Medium | S |
| **AI Preset suggestion** — covered in AI section as XVI.58. | High | M |
| **Preset categories with icons** — visual tab labels beat text-only. | Low | XS |

### Phase plan

- **XVI.59 — Real-render thumbnails for non-matrix presets** (M). When a preset has any of `curves / grain / vignette / lut3d`, render through the full `ShaderRenderer` chain at 96² and cache. Falls back to matrix-only for color-only presets.
- **XVI.62 — Preset taxonomy + icons** (S). Reorg `built_in_presets.dart` categories. Add `category_icon` field to the Preset model.
- **XVI.63 — Amount slider 0-200 %** (XS). Trivial range bump; per-op extrapolation already supported by `PresetIntensity.blend`'s clamp logic at 1.5; bump to 2.0.

---

## 9. Cross-cutting infrastructure

These items don't slot into a single section but support multiple
phases above:

- **EXIF parsing pipeline** — needed by XVI.31 (Kelvin temp), XVI.35 (lens auto-CA), XVI.46 (lens distortion). Add `lib/core/exif/exif_reader.dart` once, reuse across all three.
- **Bundled lens profile DB** — `assets/lens_profiles.json` (~1 MB) shared by XVI.35 + XVI.46. Source: Lensfun (LGPL).
- **AI runtime memory budget** — XVI.40 (depth) + XVI.49 (BiRefNet) + XVI.51 (MI-GAN) + XVI.53 (Real-ESRGAN) + XVI.56 (GFPGAN) all add ~30-100 MB peak per inference. Verify the existing `MemoryBudget` machinery handles concurrent service lifetimes correctly.
- **Telemetry / debug overlay** — every XVI.40+ AI service should emit a `ServiceTelemetry` log line (latency, model id, input/output dims). Wire through `AppLogger`.
- **Silent fallback discipline** — every new AI phase must follow the project convention: bundle fails to load → silently fall back to pre-model behaviour. XVI.49 (BiRefNet) falls back to RVM, etc.

---

## 10. Suggested ship order

Ordered by impact/effort within phase tiers. Each phase is a single
commit named `phase XVI.N of improvement plan`.

```
Tier 1 — quick wins (XS/S effort, big visible impact)
─────────────────────────────────────────────────────
XVI.23  Texture slider                         [Light]
XVI.24  Luma tone curve                        [Light]
XVI.25  Linear-light verify on H/S             [Light]
XVI.26  Vibrance skin-protect                  [Color]
XVI.33  Subject-aware vignette                 [Effects]
XVI.36  Guided filter denoise                  [Detail]
XVI.37  Auto-straighten in editor              [Geometry]
XVI.39  Auto-subject mask source               [Layers]

Tier 2 — meaningful upgrades (S/M effort, table-stakes)
───────────────────────────────────────────────────────
XVI.27  Color Grading 3-wheel                  [Color]
XVI.28  Oklch HSL                              [Color]
XVI.31  Kelvin temperature when EXIF allows    [Color]
XVI.34  Banded grain + blue-noise              [Effects]
XVI.35  EXIF lens auto-correct (CA)            [Effects]
XVI.38  Smart crop                             [Geometry]
XVI.41  Pencil pressure mask painting          [Layers]
XVI.42  Layer effects (drop shadow / stroke …) [Layers]
XVI.43  Blend modes                            [Layers]
XVI.44  MediaPipe Tasks FaceLandmarker         [AI]
XVI.45  Guided Upright perspective             [Geometry]
XVI.46  Lens distortion                        [Geometry]
XVI.47  Selfie Multiclass hair/clothes         [AI]
XVI.48  Bilateral-grid skin smooth             [AI]
XVI.49  BiRefNet-Lite bg removal               [AI]
XVI.52  SegFormer-B0 sky                       [AI]
XVI.54  Harmonizer compose                     [AI]
XVI.59  Real-render preset thumbnails          [Presets]
XVI.62  Preset taxonomy + icons                [Presets]

Tier 3 — major features (L effort, marquee differentiators)
───────────────────────────────────────────────────────────
XVI.30  Dehaze (dark-channel prior)            [Light]
XVI.32  Auto WB                                [Color]
XVI.40  Lens Blur with on-device depth         [Effects]
XVI.50  FFDNet AI denoise                      [Detail]
XVI.51  MI-GAN inpaint                         [AI]
XVI.53  Real-ESRGAN super-res                  [AI]
XVI.55  AI Sharpen                             [Detail]
XVI.56  GFPGAN/CodeFormer face restore         [AI]
XVI.57  PhotoWCT2 photoreal style transfer     [AI]
XVI.58  AI Preset suggestion                   [Presets/AI]

Defer indefinitely (high cost, low engagement on mobile)
────────────────────────────────────────────────────────
XVI.60  Adjustment-layer Z-order
XVI.61  Text on path
        Path motion blur
        Smart objects / linked layers
        Generative inpaint / expand (cloud-only)
```

The Tier-1 set (8 phases, all XS/S effort) closes the most-visible
2026-SOTA gaps without any new bundled model. After that the order
becomes a portfolio decision — pick the marquee features that match
your audience.

## 11. Out-of-scope (researched + parked)

- **HDR / Display P3 / Rec2020 pipeline** — significant infra work in `lib/engine/color/`. Only justified if you ship HDR export with gain maps (ISO 21496-1). Defer.
- **Generative text-prompt inpaint / fill / extend** — all cloud-bound at production quality in 2026 (Firefly, FLUX, Gemini 2.5 Flash Image). On-device SDXS / SD-1.5-LCM works on Apple Silicon iPhones (15 Pro+) but Flutter access to ANE/QNN is currently ugly. Build a hooks-shaped abstraction now; bind to a backend later.
- **Face slim / heavy face-reshape via GAN re-render** — ethics concerns + on-device cost. Apple, Lightroom, Photomator deliberately don't ship it. MLS landmark warp is the right tier (XVI.44 lays the groundwork via blendshapes).
- **Smart objects / linked layers** — Photoshop Mobile + Affinity have them; reviewers consistently flag low-engagement on mobile. Defer indefinitely.
- **Curves video** — Lightroom Video Editor exists; we don't ship video. Skip.

## 12. References

Selected from the research dispatch — full citation lists in each
agent's output, mirrored here for the highest-impact items:

**Light / Color**
- Cambridge in Colour, Tone Curves: <https://www.cambridgeincolour.com/tutorials/photoshop-curves.htm>
- He et al., *Single Image Haze Removal Using Dark Channel Prior*: <https://kaiminghe.github.io/publications/pami10dehaze.pdf>
- Reinhard 2002, *Photographic Tone Reproduction*: <https://www.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf>
- Adobe, *Texture vs Clarity*: <https://blog.adobe.com/en/publish/2019/05/14/new-texture-slider>
- Adobe, *New Color Grading Tool*: <https://blog.adobe.com/en/publish/2020/10/20/new-color-grading-tool-lightroom>
- Björn Ottosson, *Oklab*: <https://bottosson.github.io/posts/oklab/>
- Barron, *Fast Fourier Color Constancy*: <https://arxiv.org/abs/1611.07596>

**Effects / Detail / Geometry / Layers**
- He et al., *Guided Filter*: <https://people.csail.mit.edu/kaiming/publications/eccv10guidedfilter.pdf>
- Adobe, *Lightroom Lens Blur*: <https://helpx.adobe.com/lightroom-cc/using/lens-blur.html>
- Apple, *Depth Pro*: <https://machinelearning.apple.com/research/depth-pro>
- Pixelmator 5× horizon detection: <https://www.idownloadblog.com/2024/08/20/pixelmator-pro-and-photomator-gain-5x-more-accurate-horizon-detection-to-auto-straighten-your-images-like-a-pro/>
- Adobe, *Lightroom Guided Upright*: <https://helpx.adobe.com/lightroom-cc/web/edit-photos/crop-and-rotate/adjust-image-geometry.html>
- darktable lens correction: <https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/lens-correction/>
- Capture One Mobile layers: <https://alexonraw.com/capture-one-mobile-layers-and-masks/>
- Procreate Bloom handbook: <https://help.procreate.com/procreate/handbook/adjustments/bloom>

**AI / Presets**
- BiRefNet: <https://github.com/ZhengPeng7/BiRefNet>
- MediaPipe Tasks FaceLandmarker: <https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker>
- MediaPipe Selfie Multiclass: <https://developers.google.com/mediapipe/solutions/vision/image_segmenter>
- MI-GAN: <https://github.com/Picsart-AI-Research/MI-GAN>
- LaMa: <https://github.com/saic-mdal/lama>
- Real-ESRGAN: <https://github.com/xinntao/Real-ESRGAN>
- GFPGAN: <https://github.com/TencentARC/GFPGAN>
- CodeFormer: <https://github.com/sczhou/CodeFormer>
- SegFormer: <https://github.com/NVlabs/SegFormer>
- Harmonizer (ECCV 2022): <https://github.com/ZHKKKe/Harmonizer>
- PhotoWCT2: <https://github.com/EndyWon/PhotoWCT2>
- Lensfun: <https://lensfun.github.io/>

Cross-reference: the compose-on-bg harmonisation plan (XVI.20 preamble)
in `docs/harmonization_plan.md` shares phases XVI.21-31 with this
document — see that doc for the full per-phase file touch-list of the
harmonisation thread.
