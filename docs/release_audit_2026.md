# Release Audit & Internal Test Plan — 2026-Q2

**Status:** Pre-release gate review. Produced from a full code audit (every
subsystem) + 2025–2026 SOTA research + a competitive/legal teardown.
Companion doc: `docs/enhancement_roadmap_2026.md` (SOTA upgrades + new
capabilities). This doc = **what must be true before we ship**.

**Verdict: NOT release-ready.** The engineering interior is strong
(75k LOC, ~2,100 tests, mature parametric engine + on-device AI suite),
but there is a cluster of **hard blockers concentrated in the seams**:
model licensing, store/platform config, preview↔export correctness,
stability/observability, and compliance. None are deep architectural
problems; all are finishable. Estimate: **~3–5 focused weeks** to clear
P0 + P1.

---

## 0 · The headline findings (read these first)

1. **⚖️ Model-license blocker — several SHIPPING/DEFAULT models forbid
   commercial use.** This is the single most important finding.
   - **CodeFormer** (our **default** face-restore tier) — S-Lab License 1.0,
     **non-commercial only**.
   - **RMBG-1.4** (a bg-removal tier) — CC BY-NC 4.0; commercial needs a
     paid BRIA agreement.
   - **RVM** (the "hair/fur" bg tier) — **GPL-3.0**: fatal for a
     closed-source app unless the whole app is GPL.
   - **GFPGAN** (referenced in audits) — *labelled Apache* but its own
     LICENSE excludes StyleGAN2 (NVIDIA-NC) + DFDNet (CC BY-NC-SA);
     effectively non-commercial.
   - **Depth Anything V2 Base/Large** — CC-BY-NC-4.0 (the **Small**
     variant is Apache-2.0 and fine — we target Small, good).
   - **Clean / commercial-OK** (initial family-level guess; superseded by
     the verified exact-weights audit in **A9** — note NAFNet is **MIT**
     and DnCNN is **BSD-3 (deepinv export)**, not as first guessed):
     BiRefNet (MIT), U²-Net (Apache), LaMa (Apache), MI-GAN (MIT),
     Real-ESRGAN (BSD-3), NAFNet (MIT), DnCNN (BSD-3), MobileSAM (Apache),
     Magenta (Apache), MediaPipe (Apache), MODNet (Apache — confirmed in
     A9: the NC clause is only the PPM-100 eval benchmark), Depth-Anything
     **Small** (Apache).
   - **Action:** see §1.A. Face restoration is the hardest to replace
     cleanly; bg-removal/depth have easy permissive swaps.

2. **🗓️ Apple age-rating questionnaire deadline (Jan 31 2026) has
   PASSED.** As of today, un-answered apps have updates blocked. The new
   4+/9+/13+/16+/18+ system + AI-capability questions must be completed in
   App Store Connect **before any further iOS submission**. Treat as P0,
   do immediately.

3. **🧭 Export silently drops rotation / flip / straighten** — the
   preview shows them, the exported file doesn't (`export_service.dart`
   `renderToImage` applies only crop). A user rotates a photo, sees it
   rotated, exports, gets the original orientation. Highest-visibility
   correctness bug. No test covers it.

4. **🤖 Android release build is unshippable as configured** — `INTERNET`
   permission is missing from the *main* manifest (present only in
   debug/profile), so **all model downloads die on a release Android
   build**; and the release build is **signed with debug keys** +
   boilerplate `applicationId` → guaranteed Play rejection.

5. **🍎 No iOS `PrivacyInfo.xcprivacy`** (app-level) → App Store Connect
   upload rejection (required since May 2024; required-reason APIs in use:
   UserDefaults, file-timestamp, disk-space).

6. **💥 Zero crash visibility** — only `FlutterError.onError` is set; no
   `runZonedGuarded` / `PlatformDispatcher.instance.onError`, no
   Crashlytics/Sentry. Field crashes will be invisible, and Google Play
   gates store visibility on crash-rate (<1.09%).

7. **🕳️ Misleading dead controls** — depth-aware **Lens Blur** is a
   visible Effects op whose model isn't shipped AND whose `DepthEstimator`
   is never instantiated → moving the sliders does nothing. Same class as
   the (already-fixed) U²-Netp/BiRefNet picker entries — must hide or
   finish.

8. **🧱 Local/selective adjustments are data-modeled but never rendered.**
   `EditPipeline.adjustmentGroups` has full CRUD + masks but nothing in
   the render path reads it. Brush/linear/radial-masked exposure etc. is
   table-stakes for a 2026 "photo editor" — and the data model implies we
   intended it. Product decision required (ship without, or build it).

The rest of this doc is the full enumeration.

---

## 1 · RELEASE BLOCKERS (P0 — must fix before any store submission)

**Progress (2026-Q2):** ✅ B1 INTERNET permission (XVI.109) · ✅ A1
face-restore dropped (XVI.112) · ✅ A2 RMBG-1.4 dropped + A3 RVM dropped
(XVI.111) · ✅ A4 GFPGAN confirmed not shipped · ✅ A5 depth pinned to
Apache Small + size fixed (XVI.113) · ✅ **C1 export geometry** —
rotation/flip/straighten now applied in export, matching the preview;
transform derived + adjudicated via a workflow and pinned by a vector-
table corner-mapping test (XVI.115). All verified: full suite passes,
analyze 57 baseline. · ✅ **C2 dead Lens-Blur hidden** — `OpSpec.hidden`
flag filtered in `forCategory`; the 4 lensBlur specs marked hidden (kept
in `OpSpecs.all` so legacy-pipeline serialise/identity-collapse intact);
pinned by `op_spec_hidden_test.dart` (XVI.117). · ✅ **D1 crash capture**
— `runZonedGuarded` + `PlatformDispatcher.onError` + `FlutterError.onError`
centralised in a testable `installErrorHandlers`; async/platform errors
now reach the logger (XVI.116). · Doc/manifest hygiene from the C2/D1
adversarial review (XVI.118): stale comments + CLAUDE.md snapshot fixed.
**Remaining P0:** B2 signing, B3 appId, B4 iOS PrivacyInfo, B5 age rating,
B6–B10 store config (incl. NDK on build machine), A6 licenses screen,
C3/C4 model-manager states, D2–D4 stability (crash reporter, collage OOM,
isolate encodes), E1–E5 AI-content, F1 accessibility.

**Latent follow-ups surfaced by the C2/D1 dead-control critic — both now
RESOLVED:** (1) ✅ **XVI.119** — `ModelRegistry.resolve` now verifies a
`bundled:true` model's asset actually shipped (against `AssetManifest`,
injected at bootstrap) before reporting it available, instead of handing
back a path that throws at load. (2) ✅ **XVI.119** — pruned the dead
`espcn_3x` entry (zero Dart references); KEPT `u2netp` — it's an
intentional XVI.101 tombstone with a live `generalOffline.modelId` +
its own test, now correctly reported unavailable by the new check.

### A · Legal / model licensing

| # | Item | Fix |
|---|---|---|
| A1 | **CodeFormer (default face restore) is non-commercial** → **DROP** *(XVI.111)* | Web-verified there is **no clean permissive (MIT/Apache/BSD) face-restore model at comparable quality**: CodeFormer = S-Lab NC; GPEN = academic-only (2048 variant pulled "due to commercial issues"); GFPGAN = Apache base but StyleGAN2 (NVIDIA-NC) + DFDNet (CC-BY-NC-SA) deps; RestoreFormer++ = broken export anyway. **Action: drop face restore from the commercial build** — hide the "Restore Faces" entry, remove `codeformer_fp32` + `restoreformer_pp_fp32` manifest entries (so they can't be downloaded), keep service code as a tombstone for licensed revival. Classical **portrait-beauty (eye/teeth/smooth — license-clean, landmark-driven)** remains as the portrait-enhance path. |
| A2 | **RMBG-1.4 bg tier non-commercial** → **DROP** *(XVI.111)* | CC-BY-NC. Hide from picker + remove `rmbg_1_4_int8` manifest entry. **MODNet (Apache, weights confirmed Apache) stays as the quality tier**; MediaPipe (Apache) stays as fast/portrait. General-subject (non-portrait) matting now has no clean tier — recover via **BiRefNet (MIT)** or **BEN2 (MIT)** or shipping **U²-Net (Apache)** as a P2 enhancement. |
| A3 | **RVM bg tier is GPL-3.0** → **DROP** *(XVI.111)* | GPL is fatal for a closed-source app. Hide from picker + remove `rvm_mobilenetv3_fp32` manifest entry. "Hair/fur" niche → MODNet for now; a MIT matting model (MatAnyone/BiRefNet-matting) is the P2 recovery. |
| A4 | **GFPGAN** | ✅ Not shipped — appears only in code comments; nothing to remove. |
| A5 | **Depth Anything — pin the Small (Apache) checkpoint** *(XVI.113)* | Manifest targets `depth_anything_v2_small_int8` (Small = Apache-2.0, clean). Ensure we never ship Base/Large (CC-BY-NC). Fix the manifest `sizeBytes` (12.5 MB → actual **27.3 MB**). Depth is not yet wired/shipped, so low risk. |
| A6 | **Licenses screen + NOTICES** — ✅ **DONE (XVI.130)** | `showLicensePage` (already wired in Settings) auto-lists Dart packages incl. the native plugins onnxruntime/litert/opencv_dart. New `core/licenses/model_licenses.dart` (`registerModelLicenses`, called from `main()`) registers the shipped ML model-weight attributions via `LicenseRegistry.addLicense`, grouped by license: Apache-2.0 (MediaPipe ×4, EfficientDet, Magenta, DeepLab, LaMa, MODNet, MobileSAM — full Apache text reproduced), MIT (MI-GAN, NAFNet), BSD-3 (DnCNN/deepinv, Real-ESRGAN), Apple ml-cvnets notice (MobileViT). Dropped NC models (SegFormer, Harmonizer) are NOT attributed. Pinned by `model_licenses_test.dart` (entries present, license bodies correct, NC models absent). |
| A7 | **SegFormer-B0 sky model is NON-COMMERCIAL** → ✅ **DROPPED (XVI.128)** | Surfaced by the A6 license verification: the bundled `segformer_b0_ade20k_512_int8.onnx` is the Xenova ONNX re-export of `nvidia/segformer-b0-finetuned-ade-512-512`, whose weights carry the **NVIDIA Source Code License (non-commercial / research-only)** — illegal to ship in a paid app (Apache-2.0 governs the *code*, not these weights). Removed the bundled asset + manifest entry + the "High-quality (SegFormer-B0)" sky-engine picker; sky replace now uses bundled **DeepLabV3-ADE20K (Apache-2.0)** + the colour heuristic. `SegFormerSkyService` kept as a tombstone — revive with the MIT-licensed `keras/segformer_b0_ade20k_512` weights (re-export ONNX + verify I/O). |
| A8 | **Harmonizer is CC-BY-NC-SA-4.0** → ✅ **DROPPED (XVI.129)** | Also surfaced by the A6 verification: the bundled `harmonizer_eccv_2022_fp32.onnx` (ZHKKKe/Harmonizer) is **CC-BY-NC-SA-4.0** (NonCommercial + ShareAlike — the repo README states it verbatim; the roadmap's "Apache" was wrong). It was an **unwired scaffold** — `HarmonizerService` is never instantiated and `ComposeOnBackgroundService` never called it — so removing the asset + manifest entry changed nothing functionally (compose-on-bg already composites + edge-refines without learned harmonisation). Service kept as a tombstone. No clean learned harmoniser exists (the field trains on the iHarmony4 NC dataset); revival = classical Cohen-Or hue-template in Dart. |
| A9 | **Full bundled-weights license audit + bar decision** — ✅ **DONE (XVI.128–129)** | A1–A5 audited model *families*; A6 verification checked the *exact bundled-weights provenance* of every shipped model (web-sourced) and found SegFormer + Harmonizer non-commercial (A7/A8). **Verified clean on the model/weights license:** all MediaPipe (Apache), Magenta (Apache), Real-ESRGAN ×2/×4 (BSD-3), MobileSAM (Apache), DnCNN — **corrected to BSD-3 (deepinv)**, was wrongly "MIT/KAIR" — NAFNet (MIT), LaMa (Apache), MobileViT (Apple ml-cvnets, permissive + notice), DeepLab (Apache), MODNet (Apache — the cited NC clause is only the PPM-100 *eval* benchmark, not the shipped matting weights). **Licensing bar decision:** enforce the **model/weights license** (what the author grants), not the upstream **training-data** ToU. Rationale: data taint (Places2/DIS5K/iHarmony4) is near-universal in open models, legally unsettled for derived weights, and not the bar applied so far (LaMa already shipped as clean Apache despite Places2). **Noted-not-enforced data taint** (revisit with counsel if a stricter posture is wanted): MI-GAN + LaMa (Places2), BiRefNet-Lite (DIS5K — already hidden). Enforcing it would remove inpainting entirely (no clean inpainter exists). YOLOv8n (AGPL-3.0) is already download-blocked (C3) so never ships. |

### B · Platform / store configuration

| # | Item | File |
|---|---|---|
| B1 | Add `<uses-permission android:name="android.permission.INTERNET"/>` to the **main** manifest | `android/app/src/main/AndroidManifest.xml` |
| B2 | Real production **signing config** (release keystore), not debug keys | `android/app/build.gradle` |
| B3 | Real owned **applicationId / bundle id** (replace `com.imageeditor.image_editor` boilerplate) | gradle + Xcode |
| B4 | App-level **`ios/Runner/PrivacyInfo.xcprivacy`** (`NSPrivacyTracking=false` + reason codes `CA92.1`, `C617.1`, `E174.1`) | new file |
| B5 | **Answer the Apple age-rating questionnaire** (deadline passed — do now) | App Store Connect |
| B6 | Bump `version: 0.1.0+1` → real release version | `pubspec.yaml` |
| B7 | Set Android `targetSdk` = **35** now (36 required by 2026-08-31) | gradle |
| B8 | Prefer the **Android Photo Picker** (no `READ_MEDIA_IMAGES`, no permissions-declaration form) | picker call sites |
| B9 | Privacy-policy URL + Play **Data Safety** ("No data collected") + iOS privacy nutrition label | store consoles |
| B10 | **Install the Android NDK** (`27.0.12077973`) on the build machine — `flutter build apk/appbundle --release` fails at project configuration (`NDK not configured`) without it, because `:app`'s native plugins (opencv_dart / onnxruntime / litert) require it. `sdkmanager "ndk;27.0.12077973"`. (Discovered XVI.109: this is an iOS-dev machine; Android native tooling was never set up.) | build env / CI |

### C · Correctness

| # | Item |
|---|---|
| C1 | ✅ **DONE (XVI.115)** — `renderToImage` now applies rotation/flip/straighten + crop, mirroring the `ImageCanvas` widget tree (output dims swap on 90°/270°, upper clamp removed). Transform independently derived 3× + adjudicated against the widget tree (geometry-derivation workflow); pinned by `renderToImage geometry` corner-mapping tests in `export_service_test.dart`. |
| C2 | ✅ **DONE (XVI.117)** — gated the op out of the Effects tab via a new `OpSpec.hidden` flag filtered in `OpSpecs.forCategory` (the single UI render path: LightroomPanel + gesture layer + dock tab filter). The 4 lensBlur specs carry `hidden: true` and stay in `OpSpecs.all` so legacy-pipeline serialise/identity-collapse are unaffected. Pinned by `op_spec_hidden_test.dart` (gone from panel, present in `all`, *only* lensBlur hidden). Adversarial review confirmed `forCategory` is the only render path and no preset/AI-tab/deep-link surfaces the op. Revive by flipping `hidden`→false + wiring `DepthEstimator` once a bundled depth model ships. |
| C3 | ✅ **DONE (XVI.120)** — found YOLOv8n was reachable for *download* (pickerVisible true + PLACEHOLDER sha → downloader skipped verification → cached unverified bytes). Fixed code-only: `download()` now refuses any empty/PLACEHOLDER-sha fetch before touching the network (verification is mandatory), and `pickerVisible` hides downloadables with an unverifiable sha. RestoreFormer++ confirmed unreachable (manifest-dropped XVI.112; tombstones only). Tests: downloader refusal (no network hit), descriptor `pickerVisible`, and a manifest guard that no unverifiable-sha model is picker-visible. |
| C4 | ✅ **DONE (XVI.121)** — added the `queued` render state. The mapping (extracted to the pure `modelManagerStatusFor` in `model_manager_status.dart`) now returns `queued` for a `DownloadQueued` instead of falling through to `downloadable`; the row renders a disabled "Queued" button + Cancel + chip + icon, and the duplicate-tap guard moved above the confirm dialog so a re-tap is a true no-op. Pinned by `model_manager_status_test.dart`. |

### D · Stability / observability

| # | Item |
|---|---|
| D1 | ✅ **DONE (XVI.116)** — wrapped the whole startup + `runApp` in one `runZonedGuarded` (ensureInitialized in-zone to avoid the zone-mismatch assert), set `PlatformDispatcher.instance.onError`, and centralised both + `FlutterError.onError` in a testable `installErrorHandlers(AppLogger)`. All three route to the logger today; the D2 crash-reporter forward slots in at those two `log.e` sites. Pinned by `error_handlers_test.dart` (both hooks installed + forward + PlatformDispatcher returns true). |
| D2 | Add crash reporting. For the no-cloud ethos: **Sentry (EU region, `sendDefaultPii=false`, opt-in consent)** is the narrowest honest option; or ship none and accept blindness (risky given Play's crash vital). Decision required. |
| D3 | ✅ **DONE (XVI.123)** — two OOM caps: (a) `collage_canvas.dart` sizes each cell's decode `cacheWidth` to the **export ceiling** (`collageCellCacheWidth` = `cellLongEdge × maxOutputLongEdge / canvasLongEdge`) — sized to export, not screen, so the export (which rasterises this same tree) stays **sharp** while total decode is bounded to ~one export buffer (≤ `maxOutputLongEdge²·4`) instead of ~700 MB of full-res sources; (b) `CollageExporter` clamps the export pixelRatio (`effectiveCollagePixelRatio`) so the rasterised long edge can't exceed a device-tier ceiling (`previewLongEdge × 2` = 2880/3840/5120 px ≈ 33/59/105 MB) instead of a blind 8× (~8640² ≈ 299 MB). The page passes the same ceiling to both the canvas and the exporter. Both pure helpers pinned by `collage_memory_test.dart`. The PNG encode stays via engine-side `toByteData(png)` (not a Dart-isolate concern); the editor/scanner Dart encodes are D4. |
| D4 | ✅ **DONE (XVI.125–126)** — heavy pure-Dart encodes now run on worker isolates via `Isolate.run` (the `image` 4.x package has no `executeThread`). XVI.125: editor export codec (new `core/io/isolate_image_codec.dart` — `encodeRgbaInIsolate`; `toByteData` stays on the UI thread since dart:ui handles can't cross the boundary, the RGBA bytes do). XVI.126: scanner exporters — JPEG-ZIP + DOCX deflate via new `core/io/isolate_archive.dart` (`zipFilesInIsolate`); DOCX and PDF moved their **entire** assembly (per-image re-encode/decode-for-dims, OOXML/PDF build, deflate/`doc.save`) into a single `Isolate.run`, reading files on the main isolate first and passing sendable bytes + OCR primitives. Text exporter left as-is (string concat, not CPU-bound). Pinned by new isolate-helper tests + the existing exporter e2e/OCR-toggle suites (output unchanged). |

### E · Privacy / AI-content compliance

| # | Item |
|---|---|
| E1 | **In-app "report/flag this AI result" control** on every AI-output surface (required by Google Play AI-content policy; must route in-app + be moderated). |
| E2 | **Metered-network gate** before 100+ MB model downloads (add `connectivity_plus`; default Wi-Fi-only with explicit override). Today the only protection is an advisory sentence. |
| E3 | **Permission-denial UX** on every photo entry point (editor + collage pickers + scanner Manual/Auto) — Settings CTA, no raw `$e`, no silent abort. Currently only the scanner *camera* path handles denial. |
| E4 | If any **generative-portrait / face** feature ships: add input/output safety filtering (no nonconsensual/sexual/CSAM); Apple is actively removing "nudify" apps. |
| E5 | Write IPTC `digitalSourceType=compositeWithTrainedAlgorithmicMedia` into XMP on AI exports (EU AI Act Art. 50 generative-output marking, effective 2026-08-02). Full C2PA is deferrable for an indie under thresholds. *(Legal-counsel item, not just engineering.)* |

### F · Accessibility (store-review + compliance risk)

| # | Item |
|---|---|
| F1 | 🟡 **PARTIAL (XVI.131)** | An a11y audit showed the baseline is better than feared: ~25+ icon buttons already carry tooltips (which screen readers announce) and Flutter `Slider`s expose value semantics. The real gap was **discrete selectable tiles whose selection was colour-only** (invisible to screen readers). New reusable `core/widgets/accessible_tile.dart` (`AccessibleTile`) merges label + `selected` + button role + tap/long-press into one node + keeps the sighted tooltip; pinned by `accessible_tile_test.dart`. Wired into the **collage template thumbnails** and the **editor preset tiles** (the two highest-traffic selection grids). **Deferred (lower SR value / harder):** custom gesture canvases (curves editor, inpaint/refine-mask brush, snapseed parameter-cycling layer — the standard `Slider` path already provides an accessible way to adjust) and scanner corner-drag handles; plus a dynamic-type pass. The slider/tooltip baseline + the two selection grids cover the bulk of routine screen-reader navigation. |

---

## 2 · Per-subsystem audit (condensed)

### 2.1 Editor engine — strong interior, two seam bugs
- **Solid:** op registry (single source of truth, consistency-tested), shaders (27 `.frag`, ping-pong pool bounds memory, dark-channel dehaze, Oklch HSL, chroma-preserving highlights/shadows), tone curves (monotone Hermite, 256×5 LUT, isolate bake), presets+LUTs (ownership-correct), layers/masks (4 kinds, 13 blend modes, gradient cache), history/memento (RAM ring + disk spill, undo never depends on an evicted memento), **full-res export path is correct** (renders shader chain at native res — not the proxy).
- **Blockers:** C1 (export geometry), the unrendered local-adjustment data model.
- **Polish:** Stroke/Inner-Glow/Outer-Glow layer effects are no-ops (only Drop Shadow renders) — gate or implement; EXIF/ICC dropped on export; dormant ops/shaders (`gamma`, `gaussianBlur`, `radialBlur`) wired but never emitted; text-on-path math done but painter unshipped; `clarity.frag` radius is tight.
- **Missing vs 2026 competitors:** local/selective adjustments (rendered), live histogram, healing/clone brush, HSL targeted-color scrubber, RAW decode, HDR/P3, curves TAT.

### 2.2 AI subsystem — well-built, coherent recent fixes, a few dead entries
- **Runtime is solid:** two-pass ORT loader (external-data fallback), opt-in CoreML EP with CPU fallback, LiteRT delegate walk with leak-safe release, isolate inference.
- **The XVI.100–107 decode-resolution sweep is real and coherent:** every full-frame op now decodes at 4096 while the model still runs ≤1024 (inference cost unchanged); sky colour-gate + connectivity cleanup; LaMa per-region tiling. Verified.
- **State table:** most ops **WORKING**; **HEURISTIC** = portrait beauty ×4 (landmark-driven, good), style presets (synthetic vectors); **WORKING-LIMITED** = MODNet (512² square squash — distorts aspect), sky (procedural gradient, decode 2048), Magenta style transfer (hard 384² → preview-quality only); **HIDDEN (correct)** = U²-Netp (asset never shipped), BiRefNet (iOS OOM); **BROKEN/SCAFFOLD** = depth/Lens-Blur (B-block C2), RestoreFormer++ tombstone, YOLOv8n (no service), photo_wct2 (won't ONNX-export).
- **Dispose-guard:** correct before-await everywhere; **gap** — heavy pixel services don't re-check `_closed` *after* `runTyped` (contract deviation, not a safety bug; cheap hardening).
- **AI Test Lab readiness ≈ Phase B 50%, C/D 0%:** metric library + corpus + UI scaffold built and tested; **the per-op runners (B4) are stubs** ("TODO (B4)" banner) — so it is **not yet a gate**. See §3.

### 2.3 App shell / scanner / collage / infra
- **Scanner is release-grade** (every OpenCV call has a Dart fallback + `finally` Mat disposal, OCR never throws, PDF password resolved) — but exporters run synchronously on the UI isolate (D4) and the gallery-permission-denied path silently aborts (E3).
- **Persistence/auto-save is the most mature subsystem** (atomic writes, gzip, schema versioning + migration, non-fatal failure policy).
- **Memory governance is sophisticated** (RAM-tiered budgets, cache watchdog) **but bypassed** by collage full-res decode + uncapped export (D3).
- **Blockers:** B1–B9, D1–D4, E1–E4, F1 all live here.
- **Dependency posture:** conservative with documented pins; 2 discontinued *dev-only* transitive packages (`build_resolvers`, `build_runner_core`); the hand-patched `onnxruntime_v2` podspec is fragile (re-applies each `pod install`).
- **No i18n** despite `flutter_localizations` wired (no delegates/`.arb`) — blocker only if launching localized; else deferred debt.

---

## 3 · Internal test plan (finish the AI Test Lab → make it a real gate)

The single highest-leverage QA investment. Current lab is a navigable shell
with a correct metric core but stub runners. To turn it into a pre-commit
gate:

**Tier 1 — deterministic, on CI (`flutter test integration_test`):**
1. **Wire the B4 per-op runners** (replicate the `sky_replace_test` pattern
   for the ~8 remaining ops) so each op runs in-app and computes its metric
   (mask IoU / Boundary IoU / PSNR / SSIM / Laplacian-var / matting SAD).
2. Move the runners into `integration_test/` so they run on a device/simulator
   in CI and on **Firebase Test Lab** (real + virtual devices).
3. **Phase C baseline:** run the matrix on `main`, write
   `docs/ai_lab_baseline_2026.md` — the pass/fail table becomes the real
   priority queue.
4. **Phase D gate:** `scripts/run-ai-lab.sh` + an opt-in pre-commit hook that
   fires when `lib/ai/services/**` or `lib/ai/inference/**` changes; refuse
   commits that regress a metric beyond the 5% band.

**Tier 2 — perceptual, manual on device:** LPIPS/DISTS/NIQE/BRISQUE via the
lab UI; paste results into the commit `Lab:` trailer. (Needs a bundled
perceptual net — defer until Tier 1 is solid.)

**Corpus:** expand the real-photo set (`assets/test_images/real/`,
gitignored) beyond the one tulip-bench scene — add complex hair, multi-
subject, low-light, motion-blur, and the failure photos the user reports.

**Editor/UI coverage (the documented gap):**
- Migrate goldens to **`alchemist`** (golden_toolkit is discontinued); use
  its CI mode (text → colored rects) for deterministic cross-machine goldens.
- Golden the **design-system primitives** (tool tiles, sliders, panels), not
  full screens.
- Add `integration_test` flows for the top journeys: open→edit→export
  (with geometry — guards C1), bg-removal→compose, scan→OCR→PDF, collage.
- Add `patrol` for native permission-dialog flows (guards E3).

**Device matrix:** iOS ~4–5 devices / 2–3 OS versions (iOS is concentrated).
Android **6–8 devices across 3–4 OEMs**, including **2–3 low-RAM (2–3 GB)**
budgets — our highest OOM risk given on-device models.

**Performance gates (Android vitals / store visibility):** crash-free
≥ 99% (target 99.95%), ANR < 0.47%, cold-start < ~2 s (defer model loading),
frame build+render ≤ 8 ms each. Memory: never hold >1 stacked full-res copy;
run AI inference + `CurveLutBaker` + exports in isolates.

**Manual pre-launch QA checklist (per release):** run every AI op on the real
corpus on a real device; verify export == preview (all geometry); denied-
permission flows; airplane-mode (no models) graceful degradation; low-RAM
device pass; VoiceOver/TalkBack pass on the main journeys.

---

## 4 · Prioritized release roadmap

**P0 — Ship blockers (do first; ~2–3 wk):** §1 A–F in full. Specifically the
license swaps (A1–A5), platform config (B1–B9), export geometry (C1), dead-
control hide (C2), crash capture + a decision on reporting (D1–D2), collage
OOM (D3), AI-report control (E1), metered-download gate (E2), permission UX
(E3), accessibility pass (F1), age-rating questionnaire (B5).

**P1 — Quality bar (~1–2 wk):** finish the AI Test Lab Tier-1 gate (§3);
fix MODNet aspect squash; decouple sky mask-res from composite-res (kill the
2048 cap properly); move encodes to isolates (D4); gate/implement layer
effects; export EXIF/ICC; resolve the local-adjustment product decision.

**P2 — SOTA enhancements (see `enhancement_roadmap_2026.md`):** the
license-clean drop-ins that are also quality wins — RealPLKSR/SAFMN++ super-
res, SCUNet blind denoise, Depth-Anything-Small + real bokeh, Zero-DCE++
auto-tone/low-light (we have *nothing* here today), DDColor colorization.

**P3 — New capabilities / differentiation:** on-device AI assistant (VLM →
EditOperations), auto-tagging/alt-text (Florence-2), and a cloud generative
tier (text inpaint + outpaint via an IP-safe API behind a thin proxy) — the
features 2026 buyers expect, added without compromising the privacy story.

**Strategic frame (carried from the competitive teardown):** do **not** chase
cloud generative breadth. Own the one position no competitor can claim — **a
complete, private, on-device AI editor with no credits and no cloud** ("a
Lightroom-class editor you actually own" / "the AI editor that never uploads
your photos"). On-device inference has ~zero marginal cost, enabling a flat
sub or **lifetime unlock** the credit-metered field (Adobe/Photoroom/Picsart)
cannot match.

---

## 5 · Appendix — model license verdicts (verified at source)

🔴 = non-commercial / copyleft (blocker). 🟢 = commercial-OK.

🔴 RMBG-1.4 (CC BY-NC) · 🔴 CodeFormer (S-Lab NC) · 🔴 GFPGAN (NC via
StyleGAN2/DFDNet) · 🔴 RVM (GPL-3.0) · 🔴 Depth-Anything V2 Base/Large
(CC-BY-NC).

🟢 BiRefNet (MIT) · 🟢 BEN2 (MIT) · 🟢 U²-Net (Apache) · 🟢 MODNet
(Apache, verify weights) · 🟢 LaMa (Apache) · 🟢 MI-GAN (MIT) · 🟢
Real-ESRGAN (BSD-3) · 🟢 NAFNet (MIT) · 🟢 DnCNN/deepinv (BSD-3) · 🟢
MobileSAM (Apache) · 🟢 Magenta (Apache) · 🟢 MediaPipe (Apache) · 🟢
Depth-Anything V2 **Small** (Apache).

*This is engineering analysis, not legal advice; confirm the EU AI Act
provider/deployer classification and the model-license interpretations with
counsel before commercial launch.*
