# Subject ↔ Background Harmonisation — Phase Plan

*Drafted as the XVI.20 preamble; reviewed and prioritised before any code lands.*

## 1. Problem statement

Today the compose-on-bg pipeline cuts the subject (RVM matte, XVI.20 feather), recolours it via a single global Reinhard LAB transfer (`RgbOps.reinhardLabTransfer`, strength 0.8), and pastes onto the chosen background. On unimodal scenes this is convincing; on **mismatched-illuminant** scenes the subject still looks pasted. The user's canonical example: a subject extracted from a sunny daytime photo dropped onto a night-city background — the subject keeps its warm sun cast, has no rim from streetlights, and reads as too sharp against grain in the night plate.

Decomposing the artefact into the failure modes the literature names:

| Tell | Failure mode | Where it lives |
|------|-------------|----------------|
| Subject too bright | luminance / exposure mismatch | global low-frequency |
| Subject orange-tinted on a blue-cast scene | white balance mismatch | global low-frequency |
| Subject saturation higher than scene | global statistic mismatch | global low-frequency |
| Hard sun shadow on cheek but moonlit scene | directional lighting mismatch | high-frequency, geometric |
| No rim/wrap light from streetlights | scene → subject light leakage missing | edge-local compositing primitive |
| Subject crisp, scene grainy | sensor-grain / softness mismatch | high-frequency stochastic |
| Subject reads too close in a hazy long-distance plate | atmospheric perspective mismatch | distance-dependent |

The single global Reinhard fixes only rows 1–3 (and only on average). The rest needs targeted upgrades.

## 2. Capability tiers

A user-visible "Match scene" control should expose **strength**, not technique. Behind that knob the pipeline ramps through four tiers:

| Tier | What it does | Cost | Always-on? |
|------|--------------|------|------------|
| **0 — current** | Global Reinhard LAB transfer at fixed strength 0.8 | <5 ms CPU | yes |
| **1 — global stats++** | + auto exposure + WB scalars, LAB-ab histogram match, MKL covariance transfer | <15 ms CPU+GPU | yes |
| **2 — compositing primitives** | + rim / wrap light from background mean, fog tint from luminance gradient, grain matching | <5 ms GPU | yes (low strength by default) |
| **3 — local stats** | + tile-based mean–variance match for multi-illuminant scenes | <30 ms CPU+GPU | gated by user toggle (or auto when bg variance > threshold) |
| **4 — neural harmoniser (small)** | A bundled white-box filter regressor (Harmonizer ECCV 2022 or MKL-Harmonizer AAAI 2026) emits 8 filter args / one 3×4 matrix; pipeline applies via existing shader chain | <500 ms NPU | gated, off by default |
| **5 — directional relight (face only)** | DPR (face-only, ~30 MB int8) on top of the face crop, conditioned on background SH fit | <800 ms NPU | gated, opt-in |
| **6 — style transfer (heavy)** | PhotoWCT2 (~7 M params) for "match scene aesthetic" stronger than colour-stat transfer can express | ~1 s | gated, opt-in |

Tiers 0–3 are pure Dart/GLSL. Tier 4 introduces one bundled or downloaded `.onnx`. Tier 5 needs `face_mesh.tflite` (already bundled) + a downloaded DPR `.onnx`. Tier 6 needs a bundled or downloaded `.onnx` of PhotoWCT2.

Diffusion-class harmonisers (IC-Light, Relightful Harmonization, ObjectStitch, ControlCom, SwitchLight, SynthLight, Comprehensive Relighting, StyleID) are **off the on-device table for 2026** — they all need SD- or SDXL-class backbones (≥860 M params, ≥10 s/inference on a flagship phone). They stay off the plan.

## 3. Phase list

Each phase follows the project conventions: one commit per phase named `phase XVI.N of improvement plan`, `flutter analyze` + `flutter test` clean before commit, models silently fall back to the prior tier when assets fail to load. Effort tags: **S** ≤ ½ day, **M** 1–2 days, **L** 3+ days.

### XVI.21 — Auto exposure + white-balance scalars (Tier 1) — **S**

The single biggest visible-win-per-line-of-code. Compute median luminance + median (R−G), (B−Y) chromaticity gaps from a 64×64 thumbnail of background and subject (masked). Push two scalars into a one-pass shader applied to the subject before the existing Reinhard transfer.

- **New shader**: `shaders/harmonize_exposure_wb.frag` — `rgb *= exposureGain; rgb.r += chromaShiftR; rgb.b += chromaShiftB;`
- **New Dart wrapper**: `lib/engine/rendering/shaders/harmonize_exposure_shader.dart`
- **New helper**: `lib/ai/inference/scene_stats.dart` — `SceneStats.fromRgba(rgba, mask)` returning `medianY`, `medianRG`, `medianBY`. Pure Dart, isolate-friendly.
- **Wired into**: `compose_on_background_service.dart` step ~5 (before the Reinhard call). Returns the augmented `recoloured` buffer.
- **Pipeline op**: extend the existing `composeOnBackground` op's params with `exposureGain`, `chromaShiftR`, `chromaShiftB`. Persist + clamp on `fromOp`.
- **Success**: a sunny-day subject on a night background drops ~1.5 stops of luminance and gains a cyan cast before any user adjustment. Unit test: synthetic warm-on-cool fixture asserts post-transfer median ΔE ≤ 6.

### XVI.22 — LAB-ab histogram match (Tier 1) — **M**

Reinhard matches mean+σ. A full CDF match catches bimodal colour distributions Reinhard can't. Restricting to the a*/b* channels (skip L) preserves subject contrast / geometry — pure-RGB histogram matching used to introduce skin-tone banding, which is why we never shipped it.

- **New helper**: `lib/ai/inference/lab_histogram_match.dart` — `buildAbLuts(srcStats, tgtStats) -> (Uint8List lutA, Uint8List lutB)`. CDF-walk over 256 bins each.
- **New shader**: `shaders/harmonize_ab_lut.frag` — converts to LAB, samples the two 256×1 LUT textures for a/b, converts back.
- **New Dart wrapper**: `lib/engine/rendering/shaders/harmonize_lut_shader.dart` (mirror of `curves.frag`'s LUT plumbing).
- **Wired into**: `compose_on_background_service.dart` after XVI.21's WB pass and before Reinhard (so Reinhard becomes a residual on the histogram-matched signal).
- **Success**: on the night-bg fixture, post-transfer subject's a*/b* CDFs deviate ≤ 5 percentile bins from background's. Test fixture exists — `compose_edge_refine_test.dart` style.

### XVI.23 — Cheap rim / wrap light (Tier 2) — **S**

The "the subject doesn't touch the new scene" tell. Nuke's classic LightWrap recipe: take the alpha-matte gradient as a rim mask, sample background colour from a few pixels OUTSIDE the alpha edge, multiply by user strength, add to the subject edge.

- **New shader**: `shaders/harmonize_rim_light.frag` — `vec2 g = vec2(dFdx(alpha), dFdy(alpha)); float rim = length(g) * strength; vec3 bg = texture(background, uv + g * sampleOffset).rgb; outColor.rgb += rim * bg;`.
- **New Dart wrapper**: `lib/engine/rendering/shaders/rim_light_shader.dart`
- **Wired into**: `_passesFor()` in `editor_session.dart` for `composeSubject` layers — emits one extra pass when `rimLightStrength > 0`.
- **Persisted op**: extend `AdjustmentLayer` with `rimLightStrength` (default 0.0). Off by default; ON via the eventual "Match scene" UI.
- **Success**: synthetic A/B render shows visible coloured halo on subject edges aligned with bright bg regions; off-default keeps existing tests untouched.

### XVI.24 — Grain match (Tier 2) — **S**

Subject crisp on grainy night plate is a Hollywood cliché tell. Estimate `σ_bg = std(bg − blur5(bg))` and the same for the subject; dial subject's grain strength so the noise std-dev matches.

- **Reuses existing**: `shaders/grain.frag`
- **New helper**: `lib/ai/inference/grain_estimator.dart` — `estimateGrainStdDev(rgba, mask)` on a 256×256 thumbnail with a 5×5 box-blur reference.
- **Wired into**: `compose_on_background_service.dart` — populates a new `grainMatchStrength` on the subject layer.
- **Success**: night-plate fixture sees subject grain σ rise from baseline (~0.5) to within ±20 % of background.

### XVI.25 — MKL (Pitié) covariance colour transfer (Tier 1, replaces Reinhard) — **M**

Reinhard treats R/G/B (or L/a/b) as independent. MKL captures the full 3×3 covariance, so a "warm sun → cool moon" transfer also rotates the RGB axis instead of just sliding per-channel means. Closed form:

```
T = Σ_fg^{-1/2} · (Σ_fg^{1/2} · Σ_bg · Σ_fg^{1/2})^{1/2} · Σ_fg^{-1/2}
```

The matrix-square-root needs an eigendecomposition Dart's `vector_math` doesn't ship — implement Jacobi eig (3×3, ~30 LOC) in a new `linalg_3x3.dart` helper.

- **New helper**: `lib/ai/inference/linalg_3x3.dart` — Jacobi eigenvalues + eigenvectors for symmetric 3×3.
- **Extends**: `RgbOps.mklTransfer` (alongside the existing `reinhardLabTransfer`). Gated by a `colourTransferKind: ColourTransferKind.mkl|reinhard` enum on the compose op so we can A/B + roll back.
- **Wired into**: `compose_on_background_service.dart` step 4. The XVI.21+22 outputs feed in here, MKL becomes the residual fix.
- **Tests**: new `test/ai/mkl_transfer_test.dart` — identity case, two-mode case proving covariance is rotated not just translated.
- **Success**: on a synthetic warm/cool test pair, MKL closes ΔE residual by ≥ 30 % vs. Reinhard.

### XVI.26 — Atmospheric / fog tint (Tier 2) — **S**

For long-distance / hazy backgrounds. Sample background luminance gradient (top vs bottom averages); if gradient strength > τ, mix subject toward `mix(bgTop, bgBottom, subjectY)` at low strength. Adobe Lightroom's "Dehaze (negative)" pass approximated.

- **New shader**: `shaders/harmonize_atmosphere.frag`
- **New Dart wrapper**: `lib/engine/rendering/shaders/atmosphere_shader.dart`
- **Wired into**: `_passesFor()` in `editor_session.dart`.
- **Persisted op**: `atmosphereStrength` on the subject layer.
- **Success**: hazy-mountain bg fixture shows top-of-subject blue-shift, bottom-of-subject warm-shift, both at ≤ 8 ΔE.

### XVI.27 — Local mean-variance match for multi-illuminant scenes (Tier 3) — **M**

Global Reinhard / MKL fail on backgrounds with very different illuminants in different regions (e.g. a subject standing between a warm streetlight on the left and a blue moonlit wall on the right). Tile both subject and background to 16×16, compute (μ, σ) per tile, upsample bilinearly with a feathered mask, output `(fg − μ_fg)/σ_fg · σ_bg + μ_bg`.

- **New helper**: `lib/ai/inference/local_stats_grid.dart` — produces `Float32List` (μ, σ) tile maps.
- **New shader**: `shaders/harmonize_local_match.frag` — samples the two tile maps (uploaded as small textures).
- **New Dart wrapper**: `lib/engine/rendering/shaders/local_match_shader.dart`
- **Auto-engage heuristic**: turn on when `var(bg tile means) > τ`. Otherwise no-op.
- **Persisted op**: `localMatchStrength` on subject layer; default off.
- **Success**: split-illuminant fixture (warm left / cool right bg) shows subject's left half warmed, right half cooled, matching tile means within ΔE ≤ 8.

### XVI.28 — White-box filter regressor (Tier 4): Harmonizer (ECCV 2022) ONNX — **L**

Drop in a small (~2 M params, ~8 MB FP16) network that predicts the 8 white-box filter args (brightness, contrast, saturation, hue, colour curve coefficients) directly from the foreground+background composite. Apply via the existing colour-grading shader chain — no new GPU paths.

- **New service**: `lib/ai/services/compose_on_bg/harmonizer_service.dart` (`OrtRuntime`-backed; CPU-only, mirrors the bg-removal service pattern).
- **Bundle / download**: `assets/models/manifest.json` entry `harmonizer.onnx`, ~8 MB. Bundled (small enough). Source: <https://github.com/ZHKKKe/Harmonizer> + ONNX export script.
- **Wired into**: `compose_on_background_service.dart` step 4b (BEFORE Reinhard, so Reinhard becomes a residual). Falls back to XVI.25 MKL if the model fails to load (silent fallback per project convention).
- **UI**: a single "Match scene" toggle in the Layers sheet's compose-subject row, off by default. Future plumb into the eventual "strength" slider.
- **Tests**: `test/ai/harmonizer_service_test.dart` exercises load → infer-on-fixture → params-in-expected-range. Integration test asserts compose pipeline still produces a valid `ComposeResult` when model is missing.
- **Success**: bundled model loads <100 ms; one inference on 256² thumbnail ≤ 200 ms on iPhone 14; output filter args within sane bounds; A/B vs. XVI.25 baseline shows ≥ 25 % ΔE reduction on the test fixture suite.

### XVI.29 — MKL-Harmonizer (AAAI 2026) experiment — **M**

Once XVI.28 is plumbed, evaluate replacing the regressor head with the AAAI 2026 MKL-Harmonizer (1–3 M params) which emits one 3×4 colour matrix specifically tuned for AR-style composites. Likely faster + more on-distribution than ZHKKKe's general harmoniser. Same scaffolding as XVI.28; flip via the same `colourTransferKind` enum.

- **Touch**: `lib/ai/services/compose_on_bg/harmonizer_service.dart` (model-id branch), `assets/models/manifest.json` (new entry).
- **Success**: ≥ 15 % ΔE improvement vs. XVI.28 on the same fixture suite OR ≥ 30 % latency reduction. If neither, abandon and stay on XVI.28.

### XVI.30 — Subject-only directional relight, face-aware (Tier 5) — **L**

Once colour stats are matched, the residual "wrong sun direction" tell is the next-biggest. Run DPR on the FACE crop only (we already detect faces for portrait beauty), conditioned on a 9-coefficient SH light fit estimated from the background.

Two halves:

1. **Background → SH coefficients**. For outdoor scenes, fit Hold-Geoffroy 2017's small ResNet (sun azimuth/elevation + sky colour). For indoor, fall back to a luminance-gradient SH fit (no model). Hybrid behind `lib/ai/services/scene_lighting/scene_light_estimator.dart`.
2. **Face relight**. Bundle DPR int8 (~30 MB) under `assets/models/manifest.json` (downloaded, not bundled — over the 200 MB budget if combined with other phases). New service `lib/ai/services/compose_on_bg/dpr_face_relight_service.dart`. Run on the face crop, composite back into the subject raster via the face landmarks (already produced by `face_mesh.tflite`).

- **New op param**: `relightStrength: double` on the subject layer.
- **Fallback chain**: if DPR fails to load → SH-only shader pass on the whole subject (cheap, dumb, but better than nothing). If face_mesh fails → no-op.
- **Tests**: synthesised hard-side-light fixture; expect post-relight luminance gradient on face matches background SH fit within τ.
- **Success**: outdoor portrait test set, A/B asks ≥ 60 % preference for relit over baseline. Latency budget ≤ 1.5 s end-to-end on iPhone 14.

### XVI.31 — Optional aesthetic transfer (Tier 6) — **L**

When colour stats matching plus directional relight isn't enough — the user wants the subject to read as if it was *photographed* in the night scene (lower contrast, slight blur, characteristic palette). Bundle PhotoWCT2 (~7 M params, ~28 MB FP16, photo-realistic — does NOT add brushwork) as a final optional pass.

- **New service**: `lib/ai/services/compose_on_bg/photo_wct_service.dart`, `OrtRuntime`-backed.
- **Manifest entry**: `photo_wct2.onnx` ~28 MB, downloaded.
- **Wired into**: `_passesFor()` only when `aestheticTransferStrength > 0`.
- **UI**: separate "Style match" slider in the Edge Refine sheet (now grown into a "Match scene" sheet) — clamped to 0..0.5 by default since strong transfer over-saturates.
- **Success**: A/B on a curated fixture set; user-preference rate ≥ 50 %.

## 4. Suggested ship order

```
XVI.21  Auto exposure + WB scalars                  ← biggest quick win
XVI.22  LAB-ab histogram match                       ← still pure-Dart
XVI.23  Rim / wrap light                             ← single biggest "the subject is in the scene" tell
XVI.24  Grain match                                  ← tiny effort, very visible
─── ship a "Match scene v1" UI here, all four chained ──
XVI.25  MKL covariance colour transfer               ← upgrades existing Reinhard
XVI.26  Atmospheric / fog tint                       ← long-distance scenes
─── ship a "Match scene v2" UI here ──
XVI.27  Local mean-variance match                    ← multi-illuminant scenes
─── decide whether to bundle a neural harmoniser ──
XVI.28  Harmonizer ONNX (white-box regressor)
XVI.29  MKL-Harmonizer ONNX (only if XVI.28 wins justify a swap)
─── decide whether to ship directional relight ──
XVI.30  DPR face relight (SH fit + face crop pass)
─── decide whether to ship aesthetic transfer ──
XVI.31  PhotoWCT2 (heavy, opt-in)
```

After XVI.21–XVI.24 the user already has a "Match scene" control that ships a coherent outcome (the user-quoted "sunny on night" case mostly resolves). Each subsequent phase is a marginal upgrade, so we can stop the chain early without leaving an unfinished feature. XVI.28 is the first phase that introduces a downloadable model and should not ship before the prior tiers are in production.

## 5. Out of scope (and why)

| Technique | Why deferred |
|-----------|--------------|
| **IC-Light v1/v2** | SD-1.5 / Flux backbones, ≥10 s/inference on iPhone 15. Server-only. |
| **Relightful Harmonization** (Adobe CVPR 2024) | Weights not released; SD-class. |
| **SwitchLight** (Beeble) | Closed weights. |
| **Total Relighting** (Google) | No public release. |
| **ObjectStitch / ControlCom / DiffHarmony** | Diffusion, server-only. |
| **StyleID / Z-STAR / InstantStyle** | Diffusion, server-only. |
| **WCT2 / StyTr² / CAST** | Either too heavy (StyTr² transformer attention) or wrong tool (CAST adds brushwork). |
| **Cast-shadow synthesis (PixHt-Lab, SSN, GCDP)** | Solves a real artefact (subject doesn't cast a shadow on the new ground) but requires depth/geometry estimation. Track as XVI.32+ once Tier 5 lands. |
| **Body-normal estimation for full-body relight** | No sub-50 MB on-device estimator exists in 2026. Face-only relight (XVI.30) is the realistic ceiling. |
| **Relightful Harmonization-class joint relight + harmonise** | Requires SD-scale backbone. The chain XVI.28 + XVI.30 is the on-device approximation. |

## 6. Cross-cutting work

- **Telemetry / debug overlay** — every phase from XVI.21 should emit a `SceneMatchDiag` log line (median ΔE before/after, gain values, model latencies). Wire through the existing `AppLogger`.
- **Regression fixture set** — `test/ai/scene_match_fixtures/` with 8 paired (subject, background, expected-stat-bands) fixtures. New phases must not regress existing ones.
- **Strength UX** — the eventual "Match scene" slider maps a single user `[0, 1]` to a *vector* of internal strengths (exposure, WB, ab-LUT, MKL, rim, grain, …). Build the mapping once, in `lib/features/editor/presentation/widgets/match_scene_sheet.dart`, so XVI.21+ all cluster behind one knob.
- **Persisted-pipeline back-compat** — every new field on the compose op gets the XVI.20 treatment: `fromOp` reads + clamps; `toParams` only emits when non-default. No silent default-flip on reload.

## 7. References

Selected from the research dump:
- Harmonizer (ECCV 2022) — <https://github.com/ZHKKKe/Harmonizer>, ~2 M params, white-box filter args.
- PCT-Net (CVPR 2023) — <https://github.com/rakutentech/PCT-Net-Image-Harmonization>.
- DCCF (ECCV 2022) — <https://github.com/rockeyben/DCCF>.
- MKL-Harmonizer (AAAI 2026) — <https://arxiv.org/html/2511.12785>.
- BCMI Awesome list — <https://github.com/bcmi/Awesome-Image-Harmonization>.
- DPR — <https://github.com/zhhoper/DPR>.
- PhotoWCT2 (WACV 2022) — <https://github.com/chiutaiyin/PhotoWCT2>, 7.05 M params, photo-realistic.
- Hold-Geoffroy outdoor estimator — <https://arxiv.org/abs/1611.06403>.
- Pitié MKL colour transfer — <https://github.com/frcs/colour-transfer>.
- Foundry LightWrap reference — <https://learn.foundry.com/nuke/content/reference_guide/draw_nodes/lightwrap.html>.
- Reinhard 2001 (current implementation reference) — see `lib/ai/inference/rgb_ops.dart:310`.
