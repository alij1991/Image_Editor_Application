# Improvements Register

Consolidated list of every "Known limits & improvement candidates" bullet across the 12 [engineering guide](guide/GUIDE.md) chapters. Each candidate carries a priority (P0–P3) and a theme, plus a chapter pointer so the full context is one click away.

## How to read this file

- **Priority** — what to do first, not how hard:
  - **P0** — data loss, silent wrong behaviour, security, or dead-end UX. Fix before anything else.
  - **P1** — user-visible impact AND the fix is small (one file, one day). Best ROI.
  - **P2** — user-visible impact but requires structural work (multiple files, a pattern change).
  - **P3** — internal polish, dead-code cleanup, minor inconsistencies. Safe to bundle into other work.
- **Theme** — groupings for batching (fix several related items at once).
- **Ref** — the chapter where the candidate is documented with surrounding context.

## By the numbers

| Tag | Count | Share |
|---|---|---|
| `[correctness]` | 61 | 40% |
| `[ux]` | 27 | 18% |
| `[perf]` | 23 | 15% |
| `[test-gap]` | 21 | 14% |
| `[maintainability]` | 20 | 13% |
| **Total** | **152** | 100% |

| Priority | Count | What it looks like |
|---|---|---|
| **P0** | 9 | Security / data loss / silent-broken features |
| **P1** | 26 | One-file fixes with visible impact |
| **P2** | 58 | Multi-file or architectural work with visible impact |
| **P3** | 38 | Polish, duplication cleanup, dead-code removal |
| **Test gaps** | 21 | Uncovered behaviours, addressed together in a dedicated pass |

---

## Recommended starter batch

If you want to pick a day's worth of work, here are 10 items where the fix is small and the payoff is concrete:

1. **Delete `SuperResolutionService` scaffold** (P1, ch 21) — confusing duplicate of `SuperResService`. One file.
2. **Fix stale StyleTransfer input-size comment** (P3, ch 21) — doc says 256, code says 384. One comment.
3. ~~**Remove or wire `colorization_siggraph`** (P0, ch 20) — manifest URL is `https://example.com/`; the op type is defined. Either build the service or remove the op type.~~ ✅ *landed in Phase I.6: op type + manifest entry deleted; legacy pipelines gracefully ignore the stale op string.*
4. ~~**Drop `NLM denoise` from `shaderPassRequired`** (P0, ch 10) — op type is claimed but `_passesFor()` doesn't handle it; pipelines with it silently render wrong.~~ ✅ *Phase I.7: `denoiseNlm` constant + its `presetReplaceable` membership deleted; consistency test surfaces the remaining phantoms.*
5. **Add sha256 for the 2 biggest models** (P0, ch 20) — LaMa (208 MB) and RMBG (44 MB) ship with `PLACEHOLDER_FILL_WHEN_PINNED`, silently disabling verification.
6. **Add schema version to `ScanRepository`** (P0, ch 32) — parallel to `ProjectStore`'s pattern; prevents silent session loss on future schema change.
7. **LUT intensity participates in preset amount** (P1, ch 12) — single entry in `_interpolatingKeys`; scales LUT strength with the Amount slider.
8. **Warn before `setTemplate` drops collage images** (P0, ch 40) — 9 → 4 cells silently loses 5 picks with no undo.
9. **Remove `SharedPreferences` flicker on boot** (P1, ch 40) — move `ThemeModeController._hydrate` into `main()`.
10. **Rename `ApplyPresetEvent`** (P3, ch 11) — name is misleading now that it's also used for layer additions. Mechanical rename.

---

## P0 — Ship blockers

Fix before anything else. These are silent-broken features, integrity issues, and data-loss paths.

### Data durability

- **Collage has no persistence.** Closing the route drops the whole session. A 3×3 collage with 9 carefully-picked images is lost on an accidental back-tap. [40]
- **Collage `setTemplate` silently drops images when switching to smaller layout.** 9 → 4 cells keeps 4 images and permanently loses 5, with no undo or warning. [40]
- **Project-store silent schema drop.** On a schema bump from 1 to 2, every existing user's projects evaporate on first open — no warning, no confirm, no fallback. [05]
- **No write-ahead for pipeline JSON.** A kill during `writeAsString` leaves a truncated file; next open parse-fails and the user loses every edit since the last successful save. Atomic write via `.tmp` + rename is standard practice. [05]
- **`ScanRepository` has no schema versioning.** Unlike `ProjectStore`, there's no `_kSchemaVersion` gate. A future change to `ScanPage.toJson` silently breaks older sessions on load. [32]
- ~~**`AdjustmentLayer.cutoutImage` lost on session reload.** A persisted pipeline with AI layers reloads with those layers *present but invisible* — the user sees nothing happened. Needs memento persistence. [11]~~ ✅ *Phase I.9: new `CutoutStore` (PNG-keyed, `(sourcePath, layerId)`, 200 MB disk budget matching `MementoStore`). `EditorSession._cacheCutoutImage` persists on every AI-op; `EditorSession.start` hydrates on open. 15 store-level tests; full end-to-end editor integration deferred to Phase IX `[test-gap]`.*

### AI integrity

- **Placeholder sha256 disables download verification.** Every downloadable model ships with `"sha256": "PLACEHOLDER_FILL_WHEN_PINNED"`, so MITM and CDN corruption go undetected. Start with the largest (LaMa 208 MB, RMBG 44 MB). [20]
- ~~**`colorization_siggraph` URL is `https://example.com/`.** The op type exists in `EditOpType` but downloading would fail; any pipeline referencing `aiColorize` is a ticking bomb. [20]~~ ✅ *Phase I.6: op type removed, manifest entry deleted, legacy round-trip test added.*

### User-facing "does nothing" states

- ~~**PDF password is silently ignored.** The export sheet accepts a password; the exporter logs a warning and produces an *unprotected* PDF. Users expecting confidentiality get a false sense of security. [32]~~ ✅ *Phase I.8: the export sheet never actually exposed a password field (the PLAN assumption was wrong), but `ExportOptions.password` + the exporter's TODO branch were still there as a latent trap. Both deleted; NOTE comments in both source files audit the decision. A `pdf_exporter_password_honesty_test.dart` runtime-asserts no `/Encrypt` token in exported bytes.*
- ~~**`EditOpType.aiColorize` has no service.** Defined, in `mementoRequired`, no implementation. Any loaded pipeline with this op silently renders wrong. [21]~~ ✅ *Phase I.6: op type removed; legacy pipelines tolerate the stale op string at load time.*
- ~~**`NLM denoise` op has no pass.** `EditOpType.denoiseNlm` is in `shaderPassRequired` but no branch in `_passesFor()` handles it — pipelines with it silently render unchanged. [10]~~ ✅ *Phase I.7: op type removed; see `shader_pass_required_consistency_test.dart` for the guard against recurrence.*
- **`clarity` op has no `_passesFor()` dispatch.** `ClarityShader` class exists and 7 built-in presets emit `EditOpType.clarity`, but `editor_session.dart::_passesFor` has no branch — the op silently renders unchanged. **Surfaced by** Phase I.7's consistency test (entry in `_knownGaps`). [10]
- **`gaussianBlur` op has no shader + no dispatch.** Classified in `shaderPassRequired` but `GaussianBlurShader` doesn't exist and `_passesFor()` has no branch. [10]
- **`radialBlur` op has no dispatch.** `RadialBlurShader` class exists at `effect_shaders.dart:216` but `_passesFor()` never calls it. Every pipeline carrying this op silently renders unchanged. [10]
- **`perspective` op has no `_passesFor()` dispatch.** `PerspectiveWarpShader` exists; may be applied via a geometry pre-transform path instead of `_passesFor()`. Needs audit to decide whether to (a) wire it into `_passesFor()`, (b) move it out of `shaderPassRequired` and document the geometry path, or (c) delete if unreachable. [10]

---

## P1 — Quick wins

One-file fixes with visible impact. Best ROI per hour of work.

### Dead / duplicate code

- **Duplicate super-resolution services.** `SuperResService` works; `SuperResolutionService` is a scaffold that always throws. Calling the wrong one produces a confusing error. [21]
- ~~**`IsolateInterpreterHost` is never used.** Described as the isolate boundary in `ml_runtime.dart`, but neither session wrapper routes through it. Either adopt or delete. [20]~~ ✅ *Phase I.11: deleted the scaffold + its 5 orphan tests. `flutter_litert` / `onnxruntime_v2` already run off-main, and Phase V #8 is the real seam for persistent-worker work.*
- **Bundled `selfie_segmenter` / `face_detection_short` manifest entries are theatre.** Both are listed as `bundled: true`, but no code resolves them — ML Kit bundles its own models. Mark as "UI-only metadata" or remove. [21]

### Stale docs / comments

- **StyleTransfer input-size comment drift.** [style_transfer_service.dart:16](../lib/ai/services/style_transfer/style_transfer_service.dart:16) says 256×256; code uses 384. One comment. [21]

### One-line behaviour fixes

- **LUT intensity not in `_interpolatingKeys`.** `filter.lut3d.intensity` should scale with preset amount but doesn't; a LUT-backed preset applied at 50% still shows at full LUT strength. [12]
- **`OpenCvCornerSeed` 10% area floor excludes small documents.** Business cards or distant receipts get rejected. Sliding floor (5% on high-aspect, 10% on square) is a few lines. [30]
- **`approxPolyDP` epsilon fixed at 2%.** Low-contrast pages polygonize to 5–6 points and get rejected. Fallback to 3% → 4% on no-quad recovers many edge cases. [30]
- **Theme hydration runs async after first frame.** Moving `ThemeModeController._hydrate` into `main()` alongside `hydratePersistedLogLevel` removes the one-frame flash of dark on light-mode users. [40]
- **`_refreshRecents` walks every project JSON.** Sidecar `recents.json` index on each `save` turns 50 reads into one. [40] (also [05])
- **`customTitle` re-read every save.** Small in-memory cache on `ProjectStore` eliminates the round-trip. [05]
- **`DirtyTracker._mapEquals` is shallow.** `==` on `List` / `Map` values always diverges; HSL and split-toning force unnecessary re-renders. [02]

### UX feedback gaps

- **Missing-shader fallback is silent from the renderer.** First-frame race vs genuinely-broken shader look identical. A subtle "loading" state would distinguish them. [03]
- **Failure listeners fire once per key, forever.** After one GPU OOM, users never hear about shader load failures again. [03]
- **Download prompts don't show estimated time.** Showing "44 MB (~15 s on Wi-Fi)" instead of just "44 MB" would prevent abandonment on large models. [21]
- **Coaching banner doesn't point to which page.** "2 of 3 pages" could tell the user *which* page needs attention; the pagination strip already knows. [30]
- **Strong presets default to 80% but slider is behind second tap.** Inline Amount slider under the strip is discoverable. [12]
- **`ExportHistoryEntry` missing-file row has no re-export action.** If the file was swept, the user can only delete. Linking entries back to the source project unlocks "re-export". [40]
- **`FirstRunFlag` keyed off versioned strings.** `OnboardingKeys` central registry would keep versions in one place. [40]
- **`lastOpType` / `nextOpType` are raw op-type strings.** `color.brightness` shows up in the tooltip if a localization pass is missed. [04]
- **Model Manager "cancel" leaves partial file on disk.** "Cancel & delete" action would be clearer when the user actually wants to bail. [40]

### UX discoverability

- **Blend-mode picker not exposed on layers.** Engine supports 13 modes; `LayerEditSheet` only shows opacity. A blend-mode chip is cheap. [11]
- **Custom presets hidden under category pills.** Intentional but surprising. A "Custom" pill would fix it. [12]
- **Router has no deep-link validation.** `/editor` without `extra` renders dead-end scaffold. Redirect to `/` with a snackbar. [01]
- **No "Save to Files" shortcut after export.** iOS users expect one-tap save; today's flow requires Share → pick target. [32]
- **Filter chips show labels but not previews.** A `PresetThumbnailCache`-style filter preview would make the strip self-documenting. [31]
- **`CollageExporter` fixed at `pixelRatio: 3.0`.** Exporter supports the parameter; UI doesn't. A "resolution" picker unlocks 4K+ output. [40]

---

## P2 — Structural improvements

Multi-file or architectural changes. User-visible impact but bigger surgery.

### Registration fragmentation (the biggest theme)

- **Tool registration split across 4 places.** Adding a scalar op requires `EditOpType` + `OpSpecs.all` + shader wrapper + `_passesFor()` branch. Miss one → silent bad render or UI disappearance. A single `registerOp(...)` helper would consolidate. [10]
- **Four classifier sets in `EditOpType` must stay in sync.** `matrixComposable` / `shaderPassRequired` / `mementoRequired` / `presetReplaceable`. A per-op declaration (`registerOp('fx.foo', shaderPass: true, memento: false, …)`) replaces all four. [02]
- **Two classifier sets for preset-owned ops.** `PresetApplier._presetOwnedPrefixes` (prefixes) vs `EditOpType.presetReplaceable` (set). Pick one source of truth. [12]
- **Bootstrap bag vs DI container.** `BootstrapResult` has 10 fields and each new AI feature adds one plus a mirror provider. `GetIt` or tagged `ProviderFamily` scales better at 15+. [01]

### Serialization / migration consolidation

- **Two serialization paths co-exist.** `ProjectStore` uses `EditPipeline.fromJson` directly; `PipelineSerializer` has gzip + a migration seam. Drift risk — pick one and migrate. [05]
- **Migration seam present but untested.** `PipelineSerializer._migrate()` is a no-op with no v0→v1 fixture. First real migration has no regression target. [02]
- **`PresetRepository` has no `onUpgrade`.** Sqflite version 1 only; a future schema bump crashes. [12]

### File-save duplication

- **Four separate `_saveBytes` / `_timestampName` implementations** across scanner exporters. Shared `ExportFileSink` removes ~60 lines. [32]
- **Three separate file-save helpers** across collage/scanner/editor exports. Same consolidation. [40]

### Memory scaling

- **RAM-ring memento capacity fixed at 3 across all devices.** 12 GB Android could hold 6–8 snapshots. `MemoryBudget.maxRamMementos` should scale with RAM. [04]
- **`ProxyCache` max = 3 is fixed.** Same observation; should scale with `imageCacheMaxBytes / avgProxyBytes`. [05]
- **`MemoryBudget.probe` uses `.data['physicalRamSize']`.** String-key lookup into a `@visibleForTesting` map. Typed API or pinned plugin version would be safer. [05]
- **`ImageCachePolicy.purge()` is implemented but never wired.** Dead mitigation for Flutter #178264. Either wire a watchdog or delete. [05]
- **`ModelCache.evictUntilUnder` never called.** Disk growth is unbounded — users who download all models pay 270 MB forever. [20]

### Per-frame allocation / GC pressure

- **`ShaderRenderer.shouldRepaint` always returns true.** Repaints on every ancestor `markNeedsPaint` bubble, even when no uniforms changed. Content-hash would save repaints on scroll. [03]
- **Intermediate `PictureRecorder` allocations per pass per frame.** 5-pass pipeline = 20 GPU objects/frame. Ping-pong texture pool is the biggest perf win at this layer. [03]
- **Matrix composition rebuilds `Float32List` on every tick.** Reusable scratch buffer eliminates per-slider allocations. [02]
- **`LayerPainter` recomputes blend / mask gradients per frame.** Pooling computed paints across frames saves allocation. [11]

### Big-file decomposition

- **`editor_session.dart` is 2132 lines.** Mixes pipeline orchestration, render pass construction, LUT baking, AI coordination, auto-save, gestures. A documented refactor into `EditorPipelineFacade` / `RenderDriver` / `AutoSaveController` / `AiAdapter` is overdue. [01]
- **Service classes are flat — no base class.** Every AI service re-implements `_closed`, `FooException`, `fooFromPath`, dispose-guard. `AbstractAiService` owns 30 lines × 10 services. [21]
- **Two runtime tracks (LiteRT / ORT) share ~40% of structure** (delegate chain, isolate wrap, error typing) without code sharing. Template method would cut drift risk. [20]

### Memory budget coverage

- **`compute()` failure in scanner falls back to main thread.** 3-7 s frozen UI on 12 MP captures. `Isolate.run` with a restart path avoids the freeze. [31]
- **Per-page full-res scanner render is not cancellable.** `_processGen` drops stale results but the isolate keeps running wasted work. `Isolate.run` with kill signal. [31]
- **OCR `runOcrIfMissing` runs pages serially.** `Future.wait` halves wall time on multi-page sessions. [32]
- **Beauty services re-run face detection per service.** Session-level `FaceDetectionResult` cache eliminates 3× overhead. [21]
- **Scanner seeder runs serially per page.** `Future.wait` halves capture-to-crop latency. [30]
- **OpenCV seeder FFI round-trip per page.** Batching in one isolate that keeps Mat buffers warm saves per-page overhead. [30]
- **`DocxExporter` re-decodes each JPEG** — once for SOI sniff, once for dimensions. One decode + reuse halves work. [32]
- **`StylePredictService` has no result cache.** The 100-d vector depends only on the reference image; sha256-keyed cache eliminates redundant runs. [21]
- **Curve LUT bake runs on UI isolate.** Offloading to worker keeps drag responsive on weak devices. [03]
- **Shader preload is unbounded parallel.** 23 concurrent `FragmentProgram.fromAsset` reads; a `Pool(4)` is nicer on mid-range Android. [03]
- **ORT spawns fresh isolate per run.** 5-10 ms per inference; persistent ORT worker amortizes. [20]
- **NNAPI / CoreML disabled for LiteRT.** Delegates are in the preferred chain but `_buildOptionsFor` has `break;` for both. Android NNAPI-capable devices pay 2-3× inference cost. [20]
- **`ProjectStore.list` reads every JSON then discards.** 50 projects = 50 full decodes just to render the recents strip. Sidecar index. [05]

### Orthogonal model-management gaps

- ~~**Bootstrap silently degrades on manifest-load failure.** Empty manifest → all downloadable AI silently off. A visible non-fatal banner would surface. [01]~~ ✅ *Phase I.10: `BootstrapDegradation` record + `detectManifestDegradation` helper; `manifestDegradationProvider` exposes it; Model Manager sheet renders a `_DegradationBanner` with the human-readable cause. Classifies two reasons (`manifestLoadFailed`, `manifestEmpty`). 4 pure-function + 2 widget tests.*
- **Download-required is an enum, not a helper.** UI layer has to look up size, wire downloader itself. `factory.prepare(kind, onProgress)` centralizes. [20]
- **Shader preload is fire-and-forget.** First drag can race the preload and drop one frame; awaiting with a timeout is more predictable. [01]
- **Delegate leak path is paper-thin.** Options/delegate cleanup is per-attempt; pre-attempt failures can still leak. Scope-guard (`withOptions`) hardens. [20]
- **Manifest size estimates drift from `content-length`.** 5% tolerance papers over it. Pin to real content-length when hashes are pinned. [20]
- **ORT bundled-load hard-rejected.** Mirrors LiteRT's temp-file copy in ~30 lines. [20]

### Behaviour: classifier / heuristic tuning

- **Sky mask heuristic silently accepts blue walls.** Upper-bound on coverage + "this doesn't look like a sky" coaching. [21]
- **`DocumentClassifier` doesn't consider image blur.** Blurry document captures mis-classify as `photo`. Laplacian variance in `ImageStats`. [31]
- **`ClassicalCornerSeed.fellBack` is a single-threshold heuristic.** Smoothed distribution catches near-boundary cases. [30]
- **`estimateRotationDegrees` can't detect 180°.** Out-of-scope per comment; at minimum, surface the limitation in the review page. [31]

### State model hardening

- **`_snapshotForUndo` snapshots mutable `ScanSession`.** In-place mutation would corrupt the undo stack. Immutable classes harden. [32]
- **Two "layer invisible" concepts — `ContentLayer.visible` + `EditOperation.enabled`.** Kept in sync by the session but one inconsistent update breaks the sync. [11]
- **`reshapeParams` / `skyPresetName` stored on every `AdjustmentLayer`.** Meaningless for 7 of 9 kinds. Sealed hierarchy enforces "right kind carries its params." [11]
- **Parameters map is untyped.** `Map<String, dynamic>` means every op reader re-validates at read time. Typo silently returns identity. Sealed hierarchy or param-schema registry would catch at construction. [02]
- **`FaceReshape` warp not reproducible from params.** Depends on detector output; reload with slightly different contours produces different pixels. Parametric-promise softened here. [21]
- **`DrawingStroke.hardness` blur can exceed stroke width.** Clamp blur radius relative to stroke width. [11]
- **Compare-hold fully invalidates dirty cache.** Releasing re-renders from scratch — jarring for pipelines with expensive AI ops. Key caches by `(opId, enabled)` or snapshot "disabled view." [02]
- **`drop()` returns `Future<void>` but callers don't await.** Orphaned memento files on session close + app kill; bounded by `clear()`'s recursive delete but only if it ran. [04]
- **`historyLimit` = 128 silently evicts oldest.** No user signal when the earliest edit becomes unrevertable. Indicator or configurable cap. [04]
- **Memento disk-budget eviction is LRU-by-insertion.** 40 MB super-res + 2 MB drawing treated identically. Size-aware eviction. [04]
- **Exporters throw on missing image.** `processedImagePath` may have been swept; per-page fallback to `rawImagePath` across all exporters. [32]
- **`PdfExporter._ocrOverlay` assumes source-pixel bounds.** If ML Kit ever returns logical pixels, overlays mis-scale. No defensive check. [32]
- **Capability probe fails open on `MissingPluginException`.** Missing Android channel → user hits `ScannerUnavailableException` on first tap instead of seeing disabled tile. Retry with banner. [30]
- **Permission pre-check covers Native only.** Manual + Auto gallery picks fall through to generic "Capture failed" on permanent denial; same "Open Settings" CTA would apply. [30]
- **`_isFullRect` tolerance is frame-independent.** 0.005-per-side "did-I-move" ambiguity triggers unnecessary warp. Tighten or make content-aware. [31]
- **B&W threshold-offset range mismatch.** Code is ±30 C-value; UI slider is ±1. Scale factor needs a test. [31]

### Packaging / build

- **`_perspectiveWarpDart` compiled in every release build.** 150 lines of dead code on end-user devices. `@visibleForTesting` or build-flag guard. [31]
- **`tool/bake_luts.dart` is Dart-only.** No community `.cube` support; if user-LUT import ships later, parser + on-device bake is a chunk of work. [12]
- **Built-in LUT paths are string literals.** Scattered across `BuiltInPresets` + pubspec + `tool/bake_luts.dart`. `LutAssets` constants prevent typos. [12]
- **`tool/bake_luts` pinned to one format.** 1089×33 PNG only; no alternative format for future model size needs. [12]
- **Shader wrappers and `.frag` files drift independently.** Uniform added to frag requires manual wrapper update; no compiler catch. Generate wrapper or add runtime assertion. [03]
- **Import discipline unenforced.** Nothing prevents `engine/ → features/` imports. `import_lint` or `dependency_validator` locks it. [01]

### Minor UX tuning

- **`Drop at identity` is all-or-nothing on multi-param ops.** Vignette at amount=0 but feather=0.6 survives as a no-op shader pass. Dropping on "effect-strength param at identity" would keep the chain shorter. [10]
- **Snap-to-identity band fixed at 2%.** On narrow ranges (gamma 0.1-4) that's 0.078; on wide ranges (hue ±180°) it's 7.2°. Per-spec tuning would be nice. [10]
- **`CurvesSheet` entry is Light-tab only.** R/G/B curves could also live under Color. Re-visit once per-channel authoring ships. [10]
- **Native-path bypasses crop page entirely.** No way to re-crop a native scan; Review page could expose "Re-crop this page" that opens Crop with `Corners.inset()`. [30]
- **Magic-color `scale: 220` hardcoded.** A "Magic Color intensity" slider (180-240) gives user control. [31]
- **DOCX visible OCR text has no toggle.** Users wanting image-only have no option. "Include OCR as editable paragraphs" checkbox. [32]
- **No "revert to prior look" after Preset Apply.** Only undo. Snapshot-before-preset banner that survives subsequent edits. [12]
- **Layer reorder via drag only.** "Send to front/back" context action for large stacks. [11]
- **`OcrService` Latin-only.** Chinese/Japanese/Korean/Devanagari recognizers via separate ML Kit instances. Auto-detect or picker. [32]
- **Scanner undo/redo stacks in-memory only.** Resume from History loses buffered steps. Serialize truncated last-N. [32]
- **Mask rendering supports only `none/linear/radial`.** Brush-painted and AI-mask scaffolding doesn't exist. [11]
- **No `CollageRepository`.** Re-open past collages not supported. [40]
- **No per-cell zoom/pan in collage.** `BoxFit.cover` only — portrait in landscape cell crops top/bottom with no user control. Single most useful collage improvement. [40]
- **Only MediaPipe bg removal is always-available offline.** Wiring bundled `u2netp` as a fourth strategy gives non-portrait offline coverage. [21]

### Persistence keying

- **`sha256(sourcePath)` is absolute-path sensitive.** iOS container UUID changes across reinstalls shift the key and hide the prior project. Content-hash keying survives path changes. [05]
- **Home rename does load → save round-trip.** Loads full pipeline just to rewrite the title. Crash between corrupts. `ProjectStore.setTitle(path, title)` is safer. [40]

### Architectural hygiene

- **`ApplyPresetEvent` is used for layer additions too.** Naming mismatch; logs read like "preset applied" for "Add text layer." Rename to `ApplyPipelineEvent`. [11]
- **Two corner taxonomies.** `SeedResult.fellBack` and `corners == Corners.inset()` mean the same thing — they can drift. Make `fellBack` a computed property. [30]
- **HSL / split-toning / curves bypass `OpSpec`.** Bespoke panels for 3 ops today; fine, but any new multi-op would copy the pattern from scratch. [10]
- **Fast-path `_valueFor` drifts from `OpSpecs.all`.** New scalars silently use slow generic path. Assertion or refactor to one typed reader. [10]
- **`_BoolPrefController` instantiated per pref.** Generic `PrefController<T>` consolidates future toggles. [40]
- **`_passesFor()` branch order is implicit.** 300-line chain — new ops guess placement. Declarative pass-order table + ordering test. [03]
- **`PresetStrength` is side-table metadata, not on `Preset`.** Custom presets always default to `standard`. Either auto-infer strength from op magnitudes or add a picker. [12]
- **`_onSetAll` relies on identity comparison for release.** Current behaviour correct but invariant is implicit. [04]
- **Filter chain has implicit ordering.** Declarative `List<FilterStep>` with stamped identities. [31]
- **`PresetStrip` opens its own `PresetRepository`.** Two editor pages open two sqflite connections. `presetRepositoryProvider` shares one. [12]
- **Optics tab invisible.** Enum value defined, zero specs; tab hidden. Remove from enum or ship stub specs. [10]

---

## P3 — Polish

Small, internal, or test-only. Roll up into P1/P2 work when you're in the neighbourhood.

- Shader registry preload is parallel-unbounded → `Pool(4)`. [03]
- `_valueFor` fast path is an opt-in lookup table. [10]
- `lastOpType` raw strings in tooltips. [04]
- No conflict detection between auto-save + future explicit save. [05]

### Cross-chapter duplicates (same concern, multiple chapters)

These aren't separate items — they're the same improvement flagged from two angles. Address once:

- **"Reads every JSON then filters"** — [05] `ProjectStore.list` + [40] `_refreshRecents`. One sidecar index fixes both.
- **"Fixed-at-3 capacity across all devices"** — [04] `maxRamMementos` + [05] `ProxyCache max`. One RAM-scaled policy.
- **"Three separate file-save helpers"** — [32] 4 scanner exporters + [40] collage + editor-export. One `ExportFileSink`.
- **"Migration seam / schema versioning"** — [02] `PipelineSerializer._migrate` untested + [05] `ProjectStore` silent drop + [32] `ScanRepository` missing + [12] `PresetRepository` no `onUpgrade`. One persistence-migration pattern across all four stores.
- **"Classifier sets that must stay in sync"** — [02] `EditOpType` four sets + [12] `_presetOwnedPrefixes` vs `presetReplaceable`. One `registerOp` helper.

---

## Test gap backlog

All `[test-gap]` candidates consolidated. These are worth scheduling a dedicated "testing debt" pass once P0/P1 items settle.

### Engine-layer gaps

- No test for the `bootstrapResultProvider` throw contract. [01]
- No test for `reorderLayers` vs mixed non-layer ops. [02]
- No test asserts `presetReplaceable` excludes every AI op. [02]
- No golden test for the color chain composition. [03]
- `_passesFor()` has no direct test. [03]
- No concurrency test for `MementoStore.store` under rapid AI ops. [04]
- Memento fallback "undo via re-render" is asserted only in comments. [04]
- No integration test for disk-full auto-save path. [05]

### Editor-layer gaps

- No widget test for snap-to-identity. [10]
- No regression test for the dock's empty-category filter. [10]
- No golden tests for per-shader visual output. [10]
- No test for `AdjustmentKind` enum order stability. [11]
- No test asserts `_interpolatingKeys` stays in sync with `OpSpecs.all`. [12]

### AI-layer gaps

- No end-to-end test for `bootstrap()`'s AI wiring. [20]
- No integration test for "AI op → memento captured → undo restores pre-op pixels". [21]

### Scanner-layer gaps

- No test for gallery-pick → undecodable-file chain. [30]
- No test for `permanentlyDenied` → `requiresSettings` flag. [30]
- No end-to-end test for `_processGen` stale-result guard. [31]
- Exporters (`PdfExporter`, `DocxExporter`, `TextExporter`, `JpegZipExporter`) are untested. [32]

### Other-surfaces gaps

- Collage has zero test coverage. [40]
- `PerfHud`'s `kReleaseMode` guard is untested. [40]

---

## Suggested work packages

Grouping the backlog into batches that travel well together:

### Package A — AI integrity & cleanup (P0 + P1, 1-2 days)
Addresses: sha256 pinning, `colorization_siggraph` URL, duplicate super-res service, `IsolateInterpreterHost` unused, bundled-manifest theatre, StyleTransfer stale comment.
Files: `assets/models/manifest.json`, `lib/ai/services/super_resolution/`, `lib/ai/runtime/isolate_interpreter_host.dart`.
Impact: every downloadable AI feature gets integrity + one confusing bug is gone.

### Package B — Persistence hardening (P0, 2-3 days)
Addresses: schema versioning across all four stores (`ProjectStore`, `ScanRepository`, `PresetRepository`, `PipelineSerializer`), atomic write via `.tmp` + rename, collage persistence + `setTemplate` warning, PDF password removal (or wiring).
Files: `lib/features/editor/data/project_store.dart`, `lib/features/scanner/data/scan_repository.dart`, `lib/engine/presets/preset_repository.dart`, `lib/engine/pipeline/pipeline_serializer.dart`, new `lib/features/collage/data/collage_repository.dart`, `lib/features/scanner/data/pdf_exporter.dart`.
Impact: no more silent-drop categories; password confusion resolved.

### Package C — Op registration consolidation (P2, 3-5 days)
Addresses: four classifier sets in `EditOpType`, `OpSpecs` registration split, `_passesFor` branch order, `PresetApplier._presetOwnedPrefixes` duplication, `NLM denoise` missing pass.
Files: `lib/engine/pipeline/edit_op_type.dart`, `lib/engine/pipeline/op_spec.dart`, `lib/features/editor/presentation/notifiers/editor_session.dart` (the `_passesFor` extraction), `lib/engine/presets/preset_applier.dart`.
Impact: adding a new op becomes a single-entry change; several dormant bugs get fixed en route.

### Package D — Memory scaling (P2, 2-3 days)
Addresses: `maxRamMementos` fixed at 3, `ProxyCache` fixed at 3, `MemoryBudget.probe` magic-key, `ImageCachePolicy.purge` unwired, `ModelCache.evictUntilUnder` unwired.
Files: `lib/core/memory/memory_budget.dart`, `lib/engine/proxy/proxy_cache.dart`, `lib/ai/models/model_cache.dart`, a new low-disk watchdog in `bootstrap`.
Impact: high-end devices start using the RAM they have; disk growth becomes bounded.

### Package E — Per-frame allocation (P2, 3-4 days)
Addresses: `PictureRecorder` per-pass allocation, `MatrixComposer` Float32List churn, `LayerPainter` per-frame gradient recompute, `shouldRepaint` always-true.
Files: `lib/engine/rendering/shader_renderer.dart` (ping-pong pool), `lib/engine/pipeline/matrix_composer.dart` (scratch buffer), `lib/features/editor/presentation/widgets/layer_painter.dart`.
Impact: "biggest single perf win" — editor drag performance measurably improves.

### Package F — Parallel work unblocking (P2, 1-2 days)
Addresses: serial seeder per page, serial OCR, serial beauty services re-running face detect, serial home refresh, beauty-services no shared detector cache.
Files: `lib/features/scanner/infrastructure/manual_document_detector.dart`, `lib/features/scanner/application/scanner_notifier.dart`, `lib/features/editor/presentation/notifiers/editor_session.dart` (face-detect cache).
Impact: every multi-item flow (capture, OCR pass, beauty stack) halves in wall time.

### Package G — Test-gap pass (dedicated sprint)
Addresses: every `[test-gap]` item above. Split across engine / editor / AI / scanner / other-surfaces — roughly 2-3 days per area.
Impact: the 21 gaps are all items where a small test would pin a contract that today depends on reviewer vigilance.

---

## What's *not* in here

- **Genuine new features.** R/G/B curves, 180° auto-rotate, user LUT import, GPU bilateral, CollageRepository — these are new scope, not improvements. Mentioned in chapters but not itemized here.
- **Vendor version bumps.** `flutter_litert`, `onnxruntime_v2`, `opencv_dart` upgrades carry their own risk and are out of scope for this register.
- **Cosmetic Markdown / rename changes.** A handful of stale comments are flagged in P3; broader doc cleanup is part of Phase 7 Polish.
