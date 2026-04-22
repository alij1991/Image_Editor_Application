# Improvements Register

Consolidated list of every "Known limits & improvement candidates" bullet across the 12 [engineering guide](guide/GUIDE.md) chapters. Each candidate carries a priority (P0–P3) and a theme, plus a chapter pointer so the full context is one click away.

> **Shipped items.** Bullets with `~~strikethrough~~ ✅ *Phase X.Y: …*` are resolved; the rationale stays inline for grep-discoverability. A chronological, phase-grouped archive of the same fixes (86 items, Phase I → X) lives in [CHANGELOG-improvements.md](CHANGELOG-improvements.md).

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

1. ~~**Delete `SuperResolutionService` scaffold** (P1, ch 21) — confusing duplicate of `SuperResService`. One file.~~ ✅ *Phase II.1: scaffold + its test deleted; guide cleaned up.*
2. ~~**Fix stale StyleTransfer input-size comment** (P3, ch 21) — doc says 256, code says 384. One comment.~~ ✅ *Phase II.4: fixed — 6 stale 256 occurrences updated to 384.*
3. ~~**Remove or wire `colorization_siggraph`** (P0, ch 20) — manifest URL is `https://example.com/`; the op type is defined. Either build the service or remove the op type.~~ ✅ *landed in Phase I.6: op type + manifest entry deleted; legacy pipelines gracefully ignore the stale op string.*
4. ~~**Drop `NLM denoise` from `shaderPassRequired`** (P0, ch 10) — op type is claimed but `_passesFor()` doesn't handle it; pipelines with it silently render wrong.~~ ✅ *Phase I.7: `denoiseNlm` constant + its `presetReplaceable` membership deleted; consistency test surfaces the remaining phantoms.*
5. **Add sha256 for the 2 biggest models** (P0, ch 20) — LaMa (208 MB) and RMBG (44 MB) ship with `PLACEHOLDER_FILL_WHEN_PINNED`, silently disabling verification.
6. **Add schema version to `ScanRepository`** (P0, ch 32) — parallel to `ProjectStore`'s pattern; prevents silent session loss on future schema change.
7. ~~**LUT intensity participates in preset amount** (P1, ch 12) — single entry in `_interpolatingKeys`; scales LUT strength with the Amount slider.~~ ✅ *Phase III.4: tagged on `OpRegistration` + renderer clamp + 5 tests.*
8. **Warn before `setTemplate` drops collage images** (P0, ch 40) — 9 → 4 cells silently loses 5 picks with no undo.
9. **Remove `SharedPreferences` flicker on boot** (P1, ch 40) — move `ThemeModeController._hydrate` into `main()`.
10. ~~**Rename `ApplyPresetEvent`** (P3, ch 11) — name is misleading now that it's also used for layer additions. Mechanical rename.~~ ✅ *Phase II.7: renamed to `ApplyPipelineEvent` across all 3 production files + 4 guide docs + CLAUDE.md.*

---

## P0 — Ship blockers

Fix before anything else. These are silent-broken features, integrity issues, and data-loss paths.

### Data durability

- **Collage has no persistence.** Closing the route drops the whole session. A 3×3 collage with 9 carefully-picked images is lost on an accidental back-tap. [40]
- **Collage `setTemplate` silently drops images when switching to smaller layout.** 9 → 4 cells keeps 4 images and permanently loses 5, with no undo or warning. [40]
- **Project-store silent schema drop.** On a schema bump from 1 to 2, every existing user's projects evaporate on first open — no warning, no confirm, no fallback. [05]
- ~~**No write-ahead for pipeline JSON.** A kill during `writeAsString` leaves a truncated file; next open parse-fails and the user loses every edit since the last successful save. Atomic write via `.tmp` + rename is standard practice. [05]~~ ✅ *Phase I.1 introduced `atomicWriteString` + `atomicWriteBytes` in `lib/core/io/atomic_file.dart` (tmp + flush + rename + test-only `debugHookBeforeRename`). Adopted across every persistence-layer store: `ScanRepository.save` (I.1), `CollageRepository.save` (I.3), `ProjectStore.save` (IV.2 via `atomicWriteBytes` when the wire format became marker+gzip bytes). Phase IV.5 was a no-op audit confirming the adoption — 66 atomic-adjacent tests across the three stores all green.*
- **`ScanRepository` has no schema versioning.** Unlike `ProjectStore`, there's no `_kSchemaVersion` gate. A future change to `ScanPage.toJson` silently breaks older sessions on load. [32]
- ~~**`AdjustmentLayer.cutoutImage` lost on session reload.** A persisted pipeline with AI layers reloads with those layers *present but invisible* — the user sees nothing happened. Needs memento persistence. [11]~~ ✅ *Phase I.9: new `CutoutStore` (PNG-keyed, `(sourcePath, layerId)`, 200 MB disk budget matching `MementoStore`). `EditorSession._cacheCutoutImage` persists on every AI-op; `EditorSession.start` hydrates on open. 15 store-level tests; full end-to-end editor integration deferred to Phase IX `[test-gap]`.*

### AI integrity

- ~~**Placeholder sha256 disables download verification.** Every downloadable model ships with `"sha256": "PLACEHOLDER_FILL_WHEN_PINNED"`, so MITM and CDN corruption go undetected. Start with the largest (LaMa 208 MB, RMBG 44 MB). [20]~~ ✅ *Phase I.5 (LaMa + RMBG) + Phase IV.9 (modnet + real_esrgan_x4): 4 of 5 downloadables pinned via HuggingFace `X-Linked-ETag` — real 64-char hashes + accurate byte sizes. `test/ai/manifest_integrity_test.dart` (7 tests) enforces "every downloadable has a pinned sha256 or lives in a named, justified allow-list." Only `magenta_style_transfer` remains `PLACEHOLDER` — upstream migrated tfhub.dev → Kaggle `.tar.gz` bundles; unblocking is either a `ModelDownloader` tar-unpack refactor or bundling the 278 KB `.tflite` in assets. Tracked below.*
- **Magenta style transfer URL is dead.** `tfhub.dev/google/lite-model/…/int8/transfer/1?lite-format=tflite` returns 404 after Kaggle migration; Kaggle only serves the model inside a `.tar.gz` bundle. `StyleTransferService` code is fully implemented but the model hasn't been fetchable since the tfhub deprecation. Bundle the 278 KB `.tflite` under `assets/models/bundled/` alongside `magenta_style_predict_int8.tflite`, or extend `ModelDownloader` to unpack tar.gz archives. [20, 21]
- ~~**`colorization_siggraph` URL is `https://example.com/`.** The op type exists in `EditOpType` but downloading would fail; any pipeline referencing `aiColorize` is a ticking bomb. [20]~~ ✅ *Phase I.6: op type removed, manifest entry deleted, legacy round-trip test added.*

### User-facing "does nothing" states

- ~~**PDF password is silently ignored.** The export sheet accepts a password; the exporter logs a warning and produces an *unprotected* PDF. Users expecting confidentiality get a false sense of security. [32]~~ ✅ *Phase I.8: the export sheet never actually exposed a password field (the PLAN assumption was wrong), but `ExportOptions.password` + the exporter's TODO branch were still there as a latent trap. Both deleted; NOTE comments in both source files audit the decision. A `pdf_exporter_password_honesty_test.dart` runtime-asserts no `/Encrypt` token in exported bytes.*
- ~~**`EditOpType.aiColorize` has no service.** Defined, in `mementoRequired`, no implementation. Any loaded pipeline with this op silently renders wrong. [21]~~ ✅ *Phase I.6: op type removed; legacy pipelines tolerate the stale op string at load time.*
- ~~**`NLM denoise` op has no pass.** `EditOpType.denoiseNlm` is in `shaderPassRequired` but no branch in `_passesFor()` handles it — pipelines with it silently render unchanged. [10]~~ ✅ *Phase I.7: op type removed; see `shader_pass_required_consistency_test.dart` for the guard against recurrence.*
- **`clarity` op has no entry in `editorPassBuilders`.** `ClarityShader` class exists and 7 built-in presets emit `EditOpType.clarity`, but no builder in `pass_builders.dart` wires it in — the op silently renders unchanged. **Surfaced by** Phase I.7's consistency test (entry in `_knownGaps`). [10]
- **`gaussianBlur` op has no shader + no builder.** Classified in `OpRegistry.shaderPassRequired` but `GaussianBlurShader` doesn't exist and `editorPassBuilders` has no entry. [10]
- **`radialBlur` op has no builder.** `RadialBlurShader` class exists at `effect_shaders.dart` but no entry in `editorPassBuilders` calls it. Every pipeline carrying this op silently renders unchanged. [10]
- **`perspective` op has no builder in `editorPassBuilders`.** `PerspectiveWarpShader` exists; may be applied via a geometry pre-transform path. Needs audit to decide whether to (a) add a builder, (b) move it out of `OpRegistry.shaderPassRequired` and document the geometry path, or (c) delete if unreachable. [10]

---

## P1 — Quick wins

One-file fixes with visible impact. Best ROI per hour of work.

### Dead / duplicate code

- ~~**Duplicate super-resolution services.** `SuperResService` works; `SuperResolutionService` is a scaffold that always throws. Calling the wrong one produces a confusing error. [21]~~ ✅ *Phase II.1: scaffold deleted.*
- ~~**`IsolateInterpreterHost` is never used.** Described as the isolate boundary in `ml_runtime.dart`, but neither session wrapper routes through it. Either adopt or delete. [20]~~ ✅ *Phase I.11: deleted the scaffold + its 5 orphan tests. `flutter_litert` / `onnxruntime_v2` already run off-main, and Phase V #8 is the real seam for persistent-worker work.*
- ~~**Bundled `selfie_segmenter` / `face_detection_short` manifest entries are theatre.** Both are listed as `bundled: true`, but no code resolves them — ML Kit bundles its own models. Mark as "UI-only metadata" or remove. [21]~~ ✅ *Phase II.2: `"metadataOnly": true` added to both entries; parse loop skips them.*

### Stale docs / comments

- ~~**StyleTransfer input-size comment drift.** [style_transfer_service.dart:16](../lib/ai/services/style_transfer/style_transfer_service.dart:16) says 256×256; code uses 384. One comment. [21]~~ ✅ *Phase II.4: fixed — 6 stale occurrences updated to 384.*

### One-line behaviour fixes

- ~~**LUT intensity not in `_interpolatingKeys`.** `filter.lut3d.intensity` should scale with preset amount but doesn't; a LUT-backed preset applied at 50% still shows at full LUT strength. [12]~~ ✅ *Phase III.4: `filter.lut3d` tagged `interpolatingKeys: {'intensity'}` on its `OpRegistration`; renderer clamps to `[0, 1]` before the shader. 5 blend tests pin the semantic.*
- **`OpenCvCornerSeed` 10% area floor excludes small documents.** Business cards or distant receipts get rejected. Sliding floor (5% on high-aspect, 10% on square) is a few lines. [30]
- **`approxPolyDP` epsilon fixed at 2%.** Low-contrast pages polygonize to 5–6 points and get rejected. Fallback to 3% → 4% on no-quad recovers many edge cases. [30]
- **Theme hydration runs async after first frame.** Moving `ThemeModeController._hydrate` into `main()` alongside `hydratePersistedLogLevel` removes the one-frame flash of dark on light-mode users. [40]
- ~~**`_refreshRecents` walks every project JSON.** Sidecar `recents.json` index on each `save` turns 50 reads into one. [40] (also [05])~~ ✅ *Phase IV.8 (latent): the home page's `_refreshRecents` calls `ProjectStore.list()` — which now reads the `_index.json` sidecar instead of walking directory entries. The rename's speedup propagates through with no callsite changes.*
- ~~**`customTitle` re-read every save.** Small in-memory cache on `ProjectStore` eliminates the round-trip. [05]~~ ✅ *Phase IV.7: `ProjectStore._titleCache: Map<String, String?>` populated by `load` / `list` / `save` / `setTitle` and invalidated by `delete`. Auto-save short-circuits on warm cache — goes from "decode + jsonDecode full envelope" to one `Map` lookup. `@visibleForTesting int debugTitleCacheMissCount` pins the invariant; 9 cache tests cover warm-skip, cold-then-warm, first-ever-save-no-miss, `load`/`list` warm, `setTitle` updates, explicit title ignores cache, delete invalidates.*
- **`DirtyTracker._mapEquals` is shallow.** `==` on `List` / `Map` values always diverges; HSL and split-toning force unnecessary re-renders. [02]

### UX feedback gaps

- **Missing-shader fallback is silent from the renderer.** First-frame race vs genuinely-broken shader look identical. A subtle "loading" state would distinguish them. [03]
- **Failure listeners fire once per key, forever.** After one GPU OOM, users never hear about shader load failures again. [03]
- ~~**Download prompts don't show estimated time.** Showing "44 MB (~15 s on Wi-Fi)" instead of just "44 MB" would prevent abandonment on large models. [21]~~ ✅ *Phase VIII.A (VIII.8): confirm dialog now renders "44 MB (~15 s on Wi-Fi, ~3 min on 4G)" via new top-level `formatDownloadEstimates(sizeBytes)` helper.*
- ~~**Coaching banner doesn't point to which page.** "2 of 3 pages" could tell the user *which* page needs attention; the pagination strip already knows. [30]~~ ✅ *Phase VIII.B (VIII.14): `DetectionResult.autoFellBackPages` populated by `ManualDocumentDetector`; `coachingNoticeFor` produces "on page N" / "on pages X and Y" / Oxford-comma list for 3+.*
- ~~**Strong presets default to 80% but slider is behind second tap.** Inline Amount slider under the strip is discoverable. [12]~~ ✅ *Phase VIII.B (VIII.3): `InlineAmountSlider` listens to `appliedPreset`; disabled+caption when no preset, enabled with live amount otherwise.*
- **`ExportHistoryEntry` missing-file row has no re-export action.** If the file was swept, the user can only delete. Linking entries back to the source project unlocks "re-export". [40]
- ~~**`FirstRunFlag` keyed off versioned strings.** `OnboardingKeys` central registry would keep versions in one place. [40]~~ ✅ *Phase X.A.2: `OnboardingKeys` class in `lib/core/preferences/first_run_flag.dart` with `editorOnboarding` + `all` list; legacy `FirstRunFlag.editorOnboardingV1` forwarder annotated `@Deprecated`.*
- ~~**`lastOpType` / `nextOpType` are raw op-type strings.** `color.brightness` shows up in the tooltip if a localization pass is missed. [04]~~ ✅ *Phase X.A.1: extracted `opDisplayLabel(type)` in `lib/engine/history/op_display_names.dart`; `editor_page._opLabel` is now a one-line alias; `HistoryTimelineSheet` shares the same helper.*
- ~~**Model Manager "cancel" leaves partial file on disk.** "Cancel & delete" action would be clearer when the user actually wants to bail. [40]~~ ✅ *Phase VIII.A (VIII.7): new "Cancel & Delete" action on the downloading row runs `deletePartialFor(cache, descriptor)` to remove the file at `destinationPathFor`; split-button UI exposes both options side-by-side.*

### UX discoverability

- ~~**Blend-mode picker not exposed on layers.** Engine supports 13 modes; `LayerEditSheet` only shows opacity. A blend-mode chip is cheap. [11]~~ ✅ Shipped (audited Phase VIII.1) — `LayerEditSheet` already iterates `LayerBlendMode.values` end-to-end; widget test `test/features/editor/layer_edit_sheet_test.dart` pins the contract.
- **Custom presets hidden under category pills.** Intentional but surprising. A "Custom" pill would fix it. [12]
- ~~**Router has no deep-link validation.** `/editor` without `extra` renders dead-end scaffold. Redirect to `/` with a snackbar. [01]~~ ✅ *Phase VIII.A (VIII.9): `GoRoute.redirect` on `/editor` sends the user back to `/` and fires a snackbar via a new `rootScaffoldMessengerKey` wired into `MaterialApp.router`.*
- ~~**No "Save to Files" shortcut after export.** iOS users expect one-tap save; today's flow requires Share → pick target. [32]~~ ✅ *Phase VIII.D (VIII.17): `SaveToFiles.save(path)` Dart helper + `SaveToFilesPlugin.swift` (iOS) wrap `UIDocumentPickerViewController(forExporting:)`. Snackbar action on the export page invokes the picker post-export.*
- ~~**Filter chips show labels but not previews.** A `PresetThumbnailCache`-style filter preview would make the strip self-documenting. [31]~~ ✅ *Phase VIII.C (VIII.4): `FilterPreview.colorFilterFor(ScanFilter)` builds a 5×4 matrix approximation; `FilterChipRow(sourcePath: …)` renders each chip with `ColorFiltered` thumbnails of the source image.*
- ~~**`CollageExporter` fixed at `pixelRatio: 3.0`.** Exporter supports the parameter; UI doesn't. A "resolution" picker unlocks 4K+ output. [40]~~ ✅ *Phase VIII.B (VIII.6): `showCollageResolutionPicker` modal sheet returns 3× / 5× / 8× — collage page invokes it before `_export`.*

---

## P2 — Structural improvements

Multi-file or architectural changes. User-visible impact but bigger surgery.

### Registration fragmentation (the biggest theme)

- ~~**Tool registration split across 4 places.** Adding a scalar op requires `EditOpType` + `OpSpecs.all` + shader wrapper + `_passesFor()` branch. Miss one → silent bad render or UI disappearance. A single `registerOp(...)` helper would consolidate. [10]~~ ✅ *Phases III.1 + III.5: `OpRegistration` in `lib/engine/pipeline/op_registry.dart` owns flags/specs/interp-keys; `editorPassBuilders` in `pass_builders.dart` is the single declarative pass order. Adding an op is now two files — a registry entry and a pass builder — with ordering + consistency tests pinning both.*
- ~~**Four classifier sets in `EditOpType` must stay in sync.** `matrixComposable` / `shaderPassRequired` / `mementoRequired` / `presetReplaceable`. A per-op declaration (`registerOp('fx.foo', shaderPass: true, memento: false, …)`) replaces all four. [02]~~ ✅ *Phase III.1: the four sets are now `static final` getters on `OpRegistry` derived from each entry's boolean flags. 17 consistency tests pin the invariant.*
- ~~**Two classifier sets for preset-owned ops.** `PresetApplier._presetOwnedPrefixes` (prefixes) vs `EditOpType.presetReplaceable` (set). Pick one source of truth. [12]~~ ✅ *Phase III.2: prefix list deleted; `ownedByPreset` reads `OpRegistry.presetReplaceable` directly. 6 ownership tests pin the invariant.*
- **Bootstrap bag vs DI container.** `BootstrapResult` has 10 fields and each new AI feature adds one plus a mirror provider. `GetIt` or tagged `ProviderFamily` scales better at 15+. [01]

### Serialization / migration consolidation

- ~~**Two serialization paths co-exist.** `ProjectStore` uses `EditPipeline.fromJson` directly; `PipelineSerializer` has gzip + a migration seam. Drift risk — pick one and migrate. [05]~~ ✅ *Phase IV.2: `ProjectStore.save/load/list` now route envelopes through the shared `encodeCompressedJson`/`decodeCompressedJson` codec (new `lib/core/io/compressed_json.dart`) and hand the inner pipeline map to `PipelineSerializer.decodeFromMap`. One path; migration seams on both the wrapper (`schema`) and the pipeline (`version`) run on every load. Inline `EditPipeline.fromJson` call is gone.*
- ~~**Migration seam present but untested.** `PipelineSerializer._migrate()` is a no-op with no v0→v1 fixture. First real migration has no regression target. [02]~~ ✅ *Phase I.2 + IV.2: `pipeline_roundtrip_test.dart` pins the v0 → v1 path (strip `version`, reload, assert stamp) across both `decodeJsonString` and the new `decodeFromMap`; `project_store_test.dart` pins the wrapper-level v0 → v1 path (strip `schema`, reload, assert pipeline survives).*
- ~~**`PresetRepository` has no `onUpgrade`.** Sqflite version 1 only; a future schema bump crashes. [12]~~ ✅ *Phase I.2 registered the `onUpgrade` handler; Phase IV.3 pinned the seam with 7 synthetic schema tests (fresh v1 open, v1 → v2 bump preserves rows, v1 → v5 big jump, idempotent same-version reopen) via a new `sqflite_common_ffi` dev dep. The handler stays a no-op until a real schema change lands — the tests are the regression target that makes future bumps safe.*

### File-save duplication

- ~~**Four separate `_saveBytes` / `_timestampName` implementations** across scanner exporters. Shared `ExportFileSink` removes ~60 lines. [32]~~ ✅ *Phase IV.1: `writeExportBytes` / `writeExportString` in `lib/core/io/export_file_sink.dart`. All 4 scanner exporters (PDF, DOCX, JPEG-ZIP, text) now route through the shared helper.*
- ~~**Three separate file-save helpers** across collage/scanner/editor exports. Same consolidation. [40]~~ ✅ *Phase IV.1: scanner + collage exporters consolidated (5 of 5 `_saveBytes`-pattern duplicates). The editor's `ExportService.export()` writes to `getTemporaryDirectory()` with epoch-ms naming for share-sheet use — semantically different from the persistent app-docs `_saveBytes` pattern, so left as-is per the Phase IV.1 scope correction.*

### Memory scaling

- ~~**RAM-ring memento capacity fixed at 3 across all devices.** 12 GB Android could hold 6–8 snapshots. `MemoryBudget.maxRamMementos` should scale with RAM. [04]~~ ✅ *Phase V.2: `MemoryBudget.fromRam` returns tiered values — 3 for <3 GB, 5 for <6 GB, 8 for ≥6 GB. `EditorNotifier` passes `MementoStore(ramRingCapacity: budget.maxRamMementos)` into session start.*
- ~~**`ProxyCache` max = 3 is fixed.** Same observation; should scale with `imageCacheMaxBytes / avgProxyBytes`. [05]~~ ✅ *Phase V.2: new `MemoryBudget.maxProxyEntries` mirrors the memento-ring tier (3/5/8); `ProxyManager` constructs `ProxyCache(maxEntries: budget.maxProxyEntries)` instead of the flat default.*
- ~~**`MemoryBudget.probe` uses `.data['physicalRamSize']`.** String-key lookup into a `@visibleForTesting` map. Typed API or pinned plugin version would be safer. [05]~~ ✅ *Phase V.10: `device_info_plus@10.1.2` has no typed RAM accessor, so V.10 shipped the fallback-clause safety net. Lookup extracted into `MemoryBudget.extractRamBytes({platform, data})` — pure, test-injectable — and emits a WARNING log when the expected key is absent from a non-empty data map. Pubspec pinned to `^10.1.2` with an inline comment tying the constraint to the key contract. Silent-regression-on-plugin-rename becomes a noisy regression.*
- ~~**`ImageCachePolicy.purge()` is implemented but never wired.** Dead mitigation for Flutter #178264. Either wire a watchdog or delete. [05]~~ ✅ *Phase V.4: **adopt** chosen. New `ImageCacheWatchdog` polls `nearBudget` every 60 frames via `SchedulerBinding.addPostFrameCallback` and fires `purge` on two consecutive hits. Function-injected closures keep the state machine unit-testable without `PaintingBinding`. `BootstrapResult.cacheWatchdog` carries the instance; `fake_bootstrap` supplies a never-started stub so widget tests don't leak callbacks.*
- ~~**`ModelCache.evictUntilUnder` never called.** Disk growth is unbounded — users who download all models pay 270 MB forever. [20]~~ ✅ *Phase V.3: new `DiskStatsProvider` + `ModelCacheGuard` scaffolding; bootstrap runs the guard unawaited on startup (free-space < 500 MB → `evictUntilUnder(400 MB)`). Model Manager sheet gained a "Free up space" button next to Refresh. Probe is best-effort — macOS/Linux via `df -k`, iOS/Android/Windows fall back to `GuardProbeUnavailable` (no-op) until a platform-channel bridge lands (follow-up below).*
- **Mobile `DiskStatsProvider` needs a platform channel.** Phase V.3's `DefaultDiskStatsProvider` uses `Process.run('df', ['-k', path])` which works on macOS/Linux desktop dev but isn't available on iOS or Android. Wire a `MethodChannel('com.imageeditor/disk_stats')` → `StatFs.getAvailableBytes()` on Android + `URL.resourceValues(forKeys: [.volumeAvailableCapacityKey])` on iOS so the low-disk eviction guard actually fires on the primary target platforms. Follow-up to V.3. [20]

### Per-frame allocation / GC pressure

- **`ShaderRenderer.shouldRepaint` always returns true.** Repaints on every ancestor `markNeedsPaint` bubble, even when no uniforms changed. Content-hash would save repaints on scroll. [03]
- ~~**Intermediate `PictureRecorder` allocations per pass per frame.** 5-pass pipeline = 20 GPU objects/frame. Ping-pong texture pool is the biggest perf win at this layer. [03]~~ ✅ *Phase VI.1: new `ShaderTexturePool` (`lib/engine/rendering/shader_texture_pool.dart`) manages two `ui.Image` slots with a frame-reset ping-pong cursor. `ShaderRenderer` gained an optional `pool` parameter; `EditorSession.texturePool` owns the instance for the session's lifetime and the editor canvas path wires it in through `ImageCanvas(texturePool: session.texturePool)`. Flutter's `dart:ui` is immutable (no "render into existing Image" API), so the pool doesn't literally reuse the same Dart object across passes — what it actually delivers: peak intermediate lifetime bounded to 2 slots regardless of pass count, cross-frame slot persistence so Skia's `GrResourceCache` keeps the backing GPU textures warm and dimension-matched `Picture::toImageSync` calls hit the reuse path, and centralised disposal (install on cursor N disposes the slot-peer from cursor N-2, which the current pass no longer reads). Transient callers — `export_service.dart` (one-shot export render) and `before_after_split.dart` (one-shot cached render) — stay pool-less because one-shot rendering would only add lifetime hazard with no amortisation win. Dimension change on `beginFrame` flushes both slots (covers proxy reload for a new source). +11 pool-contract tests including "peak slot occupancy ≤ 2 across 10 installs", cross-frame eviction, dimension-change flush, and idempotent dispose. **Follow-up**: live `PerfHud` frame-time capture on-device is deferred (requires a physical run).*
- ~~**Matrix composition rebuilds `Float32List` on every tick.** Reusable scratch buffer eliminates per-slider allocations. [02]~~ ✅ *Phase VI.2: `MatrixComposer` split into two public entry points — `compose(pipeline)` keeps the fresh-allocation contract for cold-path callers (preset thumbnail cache retains the matrix long-term; reuse would corrupt cached entries) and new `composeInto(pipeline, out)` writes into a caller-owned 20-element buffer for zero per-call allocation on the editor hot path. Two static `Float32List(20)` scratch buffers (`_workScratch` for the per-op matrix, `_tmpScratch` for the multiply accumulator) live on the class — safe because the composer is const-instantiable and Dart's single-isolate / single-threaded paint model prevents concurrent access; `composeInto` never yields. Refactored the 6 public primitives (`brightness`, `contrast`, `saturation`, `hue`, `exposure`, `channelMixer`) to delegate to private `_fillXxx(value, out)` twins so both the allocating wrappers and the in-place `composeInto` path share one definition. Added `_multiplyInto(a, b, out)` with an aliasing assertion (`identical(out, a) \|\| identical(out, b)` rejected) — the matmul reads every element of `a` and `b` before writing, so an aliased output would corrupt mid-loop; turning that into a test failure instead of a silent wrong-pixel bug. `PassBuildContext` gained a `matrixScratch: Float32List(20)` field; `EditorSession._matrixScratch` owns one per session. The hot path migrates from `ctx.composer.compose(p)` to `ctx.composer.composeInto(p, ctx.matrixScratch)` — a 3-op pipeline (brightness + saturation + hue, typical preset) drops from **7 per-frame `Float32List(20)` allocations → 0**. **Safety invariant** for the reuse (documented on `PassBuildContext.matrixScratch`): the returned buffer is read by `ColorGradingShader._setUniforms` during the same frame's paint, BEFORE the next `_passesFor` overwrites it; `previewController.setPasses` atomically replaces the pass list so any older `ShaderPass` holding the scratch reference is dropped from the scene tree before its stale uniforms could be read. `preset_thumbnail_cache.dart` stays on the fresh-allocation path (the recipe retains the matrix across many frames; reuse would corrupt cached thumbnails). +11 `composeInto`-focused tests: reference-identity, 1000-iteration determinism, cross-pipeline reuse without stale state, empty-after-nonempty-resets-to-identity, byte-identical to `compose()`, length assertion, and `compose()`-returns-fresh-buffer regression. Updated 3 test stub `PassBuildContext` constructions in `passes_for_test.dart`.*
- ✅ *Phase VI.6 (latent, surfaced here): **`PresetThumbnailCache` was per-session with manual `bumpGeneration()` invalidation.** The cache died with every `EditorSession`, so re-opening the same photo rebuilt all 25 built-in recipes from scratch (25 `MatrixComposer.compose` calls + ~50 `Float32List(20)` allocations per open — a low-value tax but pure waste). Worse: any future code path that swapped the source image (e.g., a "Load different photo" action) had to remember to call `bumpGeneration` or the strip would show thumbnails that didn't match the on-screen photo — a silent-correctness footgun with no test guard. Refactored into a process-wide singleton (`PresetThumbnailCache.instance`) keyed by `(previewHash, preset.id)`, where `previewHash` is SHA-256 of the 128×128 thumbnail proxy's raw RGBA bytes via new `hashPreviewImage(ui.Image)` helper. The hash is computed once in `EditorSession.ensureThumbnailProxy` alongside the existing proxy build (~200 μs on a mid-range phone, amortised over 25+ cache lookups per session); `preset_strip.dart` threads `session.previewHash` into `recipeFor`. `bumpGeneration` deleted — preview-hash keying makes invalidation implicit and bug-free (different photo → different hash → different cache slot; same photo → cache hit across sessions). Bounded by a 64-entry LinkedHashMap LRU (move-to-MRU on hit via remove + re-insert; `keys.first` is the eviction victim) so a user cycling through 100 photos doesn't hoard memory — 64 × ~86 bytes ≈ 5.5 KB, trivial. `_RecipeKey` private record-like class with correct `==`/`hashCode` via `Object.hash`. `@visibleForTesting` counters (`debugHits`/`debugMisses`/`debugBuilds`/`debugSize`/`debugReset`) are the testable surface; tests isolate via `setUp(PresetThumbnailCache.instance.debugReset)`. +12 tests: 9 cache-contract (pointer-identity on hit, interleaved-hash state isolation, LRU 65th-insertion eviction + MRU-promotion protection, debugReset clears, identity matrix for empty preset, vignette amount propagates) + 3 `hashPreviewImage` (same bytes → same hash, different content → different hash, same colour + different dimensions → different hash — catches a would-be bug where 128×128 + 64×64 proxies of the same photo incorrectly share a cache slot). [12]*
- ✅ *Phase VI.4 (latent, surfaced here): **`HistogramAnalyzer` pixel loop runs on the UI isolate.** On a 24-MP source, the one-shot auto-enhance tap would block the main thread for ~15–25 ms on mid-range Android during the 256×256 proxy bin pass. Mirroring the Phase V.6 `CurveLutBaker.bakeInIsolate` pattern, `HistogramAnalyzer` gained `analyzeInIsolate(src)` — engine-bound `_downscale` (PictureRecorder → `Picture.toImage`) + `toByteData` still run on the calling isolate because the UI/raster thread is required, but the pure-Dart pixel-binning + percentile math crosses the `compute()` boundary. Top-level pure helper `computeHistogramFromPixels(HistogramComputeArgs)` is shared by both sync `analyze` + isolate `analyzeInIsolate` paths so there's ZERO drift between them (pinned by an equivalence test that runs both on the same image and expects byte-identical histograms + doubles). `_AutoFix.analyze` in `editor_session.dart` swapped to the isolate path. `HistogramComputeArgs` is primitives + `Uint8List` (fast-transfer); `HistogramStats` return crosses via structured cloning (plain data class, List<int> + doubles). One-shot caller (`applyAuto` is user-tap-driven) amortises the ~5–10 ms isolate spawn over a single analysis rather than every frame. Filled a pre-existing test-gap — `HistogramAnalyzer` had zero tests before VI.4. +12 new tests: 7 pure-helper cases (solid-colour histogram shape for mid-grey / black / white / saturated red, 256-row luminance ramp populates all bins, empty-buffer safety, alpha ignored) + 5 analyzer cases (sync doesn't spawn, isolate spawns exactly once, sync ≡ isolate on a procedural 16×16 image, 512×512 exercises downscale path, 64×48 skips downscale). `debugIsolateSpawnCount` + `debugResetIsolateSpawnCount` are the testable hooks. [10]*
- ~~**`LayerPainter` recomputes blend / mask gradients per frame.** Pooling computed paints across frames saves allocation. [11]~~ ✅ *Phase VI.3: new `LayerMask.cacheKey` getter — a stable string signature folding ONLY the fields each gradient branch actually reads (linear: `cx/cy/angle/feather/inverted`; radial: `cx/cy/innerRadius/outerRadius/inverted` — feather and angle are not used by the radial builder and stay out of its key so unrelated mutations don't flush). `LayerPainter._applyGradientMask` refactored to route through a module-private `_MaskGradientCache` — a `LinkedHashMap<String, ui.Shader>` LRU, capacity 16, promote-to-MRU on hit via remove + re-insert. Key = `${mask.cacheKey}@{w}x{h}` with canvas size rounded to whole pixels so sub-pixel layout jitter (300.2 vs 299.8) doesn't force new slots but a real resize does. `MaskShape.none` short-circuits before touching the cache so layers without masks incur zero overhead (pinned by test). Cache is static because `LayerPainter` is reconstructed on every CustomPaint rebuild (the framework passes a new instance and discards the old one once `shouldRepaint` allows), so instance-local state would never survive to a second paint. `ui.Shader` has no explicit dispose — evicted shaders are reclaimed by GC. Pure `_buildGradientShader(mask, size)` helper preserves the pre-VI.3 gradient math byte-for-byte (just lifted into a switch). Hit rate on a 1000-paint stable-mask burst: **999/1000** (1 miss + 999 hits) — the PLAN's "drawing-heavy session recomputes the same gradient every frame" case drops from 1000 `ui.Gradient.linear/radial` allocations + GPU shader instantiations to exactly 1. `@visibleForTesting` counters (`debugGradientCacheHits`, `Misses`, `Size`, `debugResetGradientCache`) are the testable surface. +15 tests: 5 `cacheKey` unit tests + 10 cache-path tests covering first-miss-then-hit, the 1000-paint stable-mask burst, feather-change invalidates, canvas-resize invalidates (and reverting reuses the original entry), sub-pixel size rounds to same slot, `MaskShape.none` skip, LRU capacity = 16 with 17th insertion evicting the oldest, MRU promotion survives eviction, `debugResetGradientCache` zeroes state, layer without a mask skips entirely.*

### Big-file decomposition

- **`editor_session.dart` is 1408 lines** (was 2132 pre-Phase VI, 2316 pre-VII.1, 2305 pre-VII.2, 1830 pre-VII.3, 1656 pre-VII.4). Still mixes pipeline orchestration + history wiring + setScalar/setMapParams + preset application + layer/geometry editing + auto-enhance; the four Phase VII extractions (auto-save, AI, render path, applyXxx absorption) pulled ~908 lines out. [01] — **Phase VII ✅ COMPLETE** (4-item arc shipped): *VII.1 `AutoSaveController`* (104 lines, 11 tests, session -11). *VII.2 `AiCoordinator`* cutout cache + `runInference<E>` (332 lines, 17 tests, session -475). *VII.3 `RenderDriver`* `_passesFor` + LUT bake lifecycle + matrix scratch (249 lines, 11 tests, session -174). *VII.4* — folded the 9 AI `applyXxx` methods + `_commitAdjustmentLayer` helper into `AiCoordinator` via new `CommitAdjustmentLayer` + `DetectFaces` typedef callbacks; session methods become 4-line delegates preserving the public API. AiCoordinator grew 332 → 651 lines. Session -248 in VII.4. **Phase VII exit criterion ("no file under features/editor/ exceeds 800 lines") DID NOT clear** — session at 1408 is still >2× target. The 4-item arc deliberately scoped to what the PLAN enumerated; the residue (layer editing ~210 lines, geometry ~170, preset apply ~150, content-layer mutators ~140, auto-enhance ~60) sums ~730 lines of independent follow-up extractions, each with a clean natural boundary. Tracked as a future Phase VII.5+ or Phase IX opportunity — every extraction target has a named class + test file plan in the PLAN's own language.
- **Service classes are flat — no base class.** Every AI service re-implements `_closed`, `FooException`, `fooFromPath`, dispose-guard. `AbstractAiService` owns 30 lines × 10 services. [21]
- **Two runtime tracks (LiteRT / ORT) share ~40% of structure** (delegate chain, isolate wrap, error typing) without code sharing. Template method would cut drift risk. [20]

### Memory budget coverage

- ✅ *Phase VI.5 (latent, surfaced here): **Scanner post-capture runs warp + filter sequentially across pages.** Native-strategy captures (where `cunning_document_scanner` returns pre-cropped pages) fire `_processAllPages`, which used to `for`-loop over `s.pages` awaiting `processor.process(page)` one at a time. Each `process()` call internally spawns a `compute()` isolate for the decode → warp → filter → encode pipeline, so the sequential loop left 3 of 4 CPU cores idle during an N-page import — an 8-page gallery import took ≈ N×400 ms of wall time when ≈ N/4 × 400 ms was achievable. Refactored to drop already-processed pages first, then dispatch pending pages through new top-level `processPendingPagesParallel` helper wrapping Phase V.7's `runBoundedParallel` with `kPostCaptureProcessConcurrency = 4` — sized to mid-range Android core counts + each compute() isolate's ~70 MB peak footprint (decode + OpenCV state) = ~280 MB in flight, within even the 4 GB device budget. `runBoundedParallel` inherits every pinned behaviour from V.7's tests: cap enforcement, sibling-failure-doesn't-halt-siblings (first error rethrown at end to match `Future.wait`), empty-input short-circuit, concurrency clamped to item count. Commit callback threads through synchronously per-page-completion (not batched), preserving the pre-VI.5 UX where pages populate progressively in the review strip. Helper is top-level so unit tests drive it without standing up `ScannerNotifier` + 7 injected deps (probe, processor, ocr, repository, picker, cornerSeed, Riverpod container). `kPostCaptureProcessConcurrency` exported as the single observable knob. +8 new tests: empty short-circuits, every page processed + committed exactly once, concurrency cap holds + peak reaches cap, single-page with oversized concurrency is safe, worker-return-value propagates through to commit, worker exception bubbles after siblings drain, commit-per-completion ordering proven via a gated dual-worker test (B releases before A → commit order `[b, a]`), and the exported constant equals 4. [31]*
- ~~**`compute()` failure in scanner falls back to main thread.** 3-7 s frozen UI on 12 MP captures. `Isolate.run` with a restart path avoids the freeze. [31]~~ ✅ *Phase X.B.3: extracted `_runOffThread(payload)` in `lib/features/scanner/data/image_processor.dart` wrapping `Isolate.run(() => _processInIsolate(payload))` with a single retry. If both isolate attempts fail, the helper returns `Uint8List(0)` (the same graceful-degrade signal the decoder uses on undecodable input) — the caller leaves the page on its placeholder. Main-thread `_processInIsolate` invocation is gone; no synchronous CPU work on the UI isolate regardless of failure mode. Source-contract test pins the invariant so future refactors don't silently reintroduce the freeze.*
- **Per-page full-res scanner render is not cancellable.** `_processGen` drops stale results but the isolate keeps running wasted work. `Isolate.run` with kill signal. [31]
- **OCR `runOcrIfMissing` runs pages serially.** `Future.wait` halves wall time on multi-page sessions. [32]
- ~~**Beauty services re-run face detection per service.** Session-level `FaceDetectionResult` cache eliminates 3× overhead. [21]~~ ✅ *Phase V.1: new `FaceDetectionCache` (sourcePath → `Future<List<DetectedFace>>`) owned by `EditorSession`. All four `apply*` methods — Portrait Smooth, Eye Brighten, Teeth Whiten, Face Reshape — route detection through `detectFacesCached({detector})` and pass `preloadedFaces` to the service. Services gained an optional `preloadedFaces` parameter (backwards-compatible for standalone callers). Concurrent callers converge on one in-flight detection; failures are not cached (retries fire fresh); empty-list successes ARE cached. Applying all three basic beauty ops on the same source now pays ML Kit once (~700 ms) instead of three times (~2.1 s). +15 tests pin the three-calls-one-detection invariant.*
- ~~**Scanner seeder runs serially per page.** `Future.wait` halves capture-to-crop latency. [30]~~ ✅ *Phase VI.7: different axis from V.9's isolate batching. The `CornerSeeder.seedBatch` default forwarder on the abstract base class migrated from a sequential `for+await` loop to `Future.wait(imagePaths.map(seed))`; `ClassicalCornerSeed` + `OpenCvCornerSeed` swapped from `implements` to `extends` so they inherit the parallel default. `OpenCvCornerSeed.seedBatch`'s two sequential fallback loops (the emergency catch-block that runs when the compute() isolate crashes, and the post-batch null-index loop that dispatches `fallback.seed(path)` for pages OpenCV couldn't resolve) likewise migrated to `Future.wait` with order-preserving index-slotback. Order preservation is guaranteed: `Future.wait` returns results in input iteration order, and the null-fallback path collects pending indexes first then writes each result back into its original slot before returning `out.cast<SeedResult>()`. `CornerSeeder` gained a `const` constructor so `const ClassicalCornerSeed()` + `const OpenCvCornerSeed(...)` stay const-instantiable for the Riverpod provider + test callers. Each `seed` performs `File.readAsBytes + img.decodeImage + Sobel`; the file read is async I/O that yields the isolate (real wall-time overlap), while decode + Sobel serialise on main (no CPU win beyond the I/O). For a typical ≤10-page batch, uncapped parallelism is cheap and matches the "halves capture-to-crop latency" ROI. **Why uncapped (vs VI.5's bounded runBoundedParallel)**: VI.5 workers each spawn a compute() isolate with ~70 MB peak, so bounding matters. VI.7 workers stay on main and the only cost is the file-descriptor pool, which the OS bounds implicitly — on mobile, even a pathological 50-page batch doesn't exceed limits. `seed_batch_test.dart` rewritten: retains the 6 pre-VI.7 contract tests (empty input, exactly-once ordering, fellBack preservation, exception propagation, single-path) + 3 new VI.7 parallelism proofs (gated-completer peak-in-flight proves all seeds start before any completes; slow-leading-seed doesn't block later completion; result order matches input order even when completion order diverges). `scanner_smoke_test.dart` continues to exercise the full OpenCV isolate path end-to-end. [30]*
- ~~**OpenCV seeder FFI round-trip per page.** Batching in one isolate that keeps Mat buffers warm saves per-page overhead. [30]~~ ✅ *Phase V.9: new `CornerSeeder.seedBatch` on the interface. `OpenCvCornerSeed` overrides to push the whole multi-page import through a single `compute()` worker (static-function twins of every pipeline helper because closures can't cross isolates). Null results fall back to `ClassicalCornerSeed.seed` on main, preserving the pre-V.9 contract. `ManualDocumentDetector.capture` swapped the per-path await loop for a single `seedBatch` call — an 8-page gallery import now pays one isolate spawn instead of eight main-isolate blocking pipelines.*
- **`DocxExporter` re-decodes each JPEG** — once for SOI sniff, once for dimensions. One decode + reuse halves work. [32]
- ~~**`StylePredictService` has no result cache.** The 100-d vector depends only on the reference image; sha256-keyed cache eliminates redundant runs. [21]~~ ✅ *Phase V.5: new `StyleVectorCache` under `lib/ai/services/style_transfer/`. Hashes the reference image bytes, stores 100 float32 as 400 bytes at `<AppDocs>/style_vectors/<sha>.bin` via `atomicWriteBytes`. `StylePredictService.predictFromPath(path, {cache})` gained an optional cache parameter; `editor_page` wires it through `styleVectorCacheProvider`. Content-keyed (sha of bytes, not path) so a copied reference file still hits; survives app restarts.*
- ~~**Curve LUT bake runs on UI isolate.** Offloading to worker keeps drag responsive on weak devices. [03]~~ ✅ *Phase V.6: `CurveLutBaker.bakeInIsolate` moves the 1024-Hermite byte-gen behind `compute()` via a new top-level `bakeToneCurveLutBytes` pure helper. `EditorSession` gained a `_PendingCurveBake` single-slot queue so a sustained drag coalesces to ≤ 2 isolate spawns regardless of frame count (one in-flight + one queued) — `compute()`'s ~5–10 ms spawn cost would otherwise beat the 0.5 ms of Hermite math it saved. `decodeImageFromPixels` stays on main (engine-bound).*
- ~~**Shader preload is unbounded parallel.** 23 concurrent `FragmentProgram.fromAsset` reads; a `Pool(4)` is nicer on mid-range Android. [03]~~ ✅ *Phase V.7: new `runBoundedParallel` / `runBoundedParallelSettled` in `lib/core/async/bounded_parallel.dart` (no new dep — 90 lines of Dart). `ShaderRegistry.preload` now uses the settled variant with `concurrency: 4`, so bundle reads wave through instead of storming the asset layer. Per-item failure isolation is the behaviour upgrade: one missing `.frag` no longer short-circuits the other 22 loads (pre-V.7 `Future.wait` did).*
- ~~**ORT spawns fresh isolate per run.** 5-10 ms per inference; persistent ORT worker amortizes. [20]~~ ✅ *Phase V.8: `OrtV2Session.runTyped` switched from `runOnceAsync` (fresh isolate per call) to `runAsync` (persistent isolate per session, reused across calls). `close()` still drives `_session.release()` which internally `killAllIsolates()` — persistent worker is torn down at session end. Added `debugRunCount` counter for observability.*
- **`OrtV2Session` unit tests need a minimal ONNX fixture.** Phase V.8's shim lives behind a private constructor that requires a real `.onnx` file to instantiate, so the V.8 runtime-behaviour test (persistent isolate reused across 10 calls) couldn't be written. A ~1 KB identity-op ONNX file under `test/fixtures/` unlocks this + any future `OrtRuntime` tests. Follow-up to V.8. [20]
- **NNAPI / CoreML disabled for LiteRT.** Delegates are in the preferred chain but `_buildOptionsFor` has `break;` for both. Android NNAPI-capable devices pay 2-3× inference cost. [20]
- ~~**`ProjectStore.list` reads every JSON then discards.** 50 projects = 50 full decodes just to render the recents strip. Sidecar index. [05]~~ ✅ *Phase IV.8: new `<root>/_index.json` sidecar + in-memory `_indexShadow` on `ProjectStore`. `save` / `setTitle` / `delete` mutate the shadow + rewrite the sidecar; `list()` reads one file instead of 50. Cold-start rebuild falls back to the directory walk, then persists the sidecar so next session is fast. `debugIndexRebuildCount` pins "warm reads don't walk." Title cache (IV.7) warms as a free side effect.*

### Orthogonal model-management gaps

- ~~**Bootstrap silently degrades on manifest-load failure.** Empty manifest → all downloadable AI silently off. A visible non-fatal banner would surface. [01]~~ ✅ *Phase I.10: `BootstrapDegradation` record + `detectManifestDegradation` helper; `manifestDegradationProvider` exposes it; Model Manager sheet renders a `_DegradationBanner` with the human-readable cause. Classifies two reasons (`manifestLoadFailed`, `manifestEmpty`). 4 pure-function + 2 widget tests.*
- **Download-required is an enum, not a helper.** UI layer has to look up size, wire downloader itself. `factory.prepare(kind, onProgress)` centralizes. [20]
- **Shader preload is fire-and-forget.** First drag can race the preload and drop one frame; awaiting with a timeout is more predictable. [01]
- **Delegate leak path is paper-thin.** Options/delegate cleanup is per-attempt; pre-attempt failures can still leak. Scope-guard (`withOptions`) hardens. [20]
- **Manifest size estimates drift from `content-length`.** 5% tolerance papers over it. Pin to real content-length when hashes are pinned. [20]
- **ORT bundled-load hard-rejected.** Mirrors LiteRT's temp-file copy in ~30 lines. [20]

### Behaviour: classifier / heuristic tuning

- ~~**Sky mask heuristic silently accepts blue walls.** Upper-bound on coverage + "this doesn't look like a sky" coaching. [21]~~ ✅ *Phase VIII.B (VIII.10): `SkyReplaceService(maxCoverageRatio: 0.60)` + `MaskStats.coverageRatio` getter; throws typed exception with the recommended message above the threshold.*
- ~~**`DocumentClassifier` doesn't consider image blur.** Blurry document captures mis-classify as `photo`. Laplacian variance in `ImageStats`. [31]~~ ✅ *Phase VIII.C (VIII.11): `ImageStats.sharpness` (Laplacian variance / 250 clamped) computed alongside colour-richness; classifier demotes high-chroma low-sharpness to `unknown` instead of `photo`.*
- **`ClassicalCornerSeed.fellBack` is a single-threshold heuristic.** Smoothed distribution catches near-boundary cases. [30]
- **`estimateRotationDegrees` can't detect 180°.** Out-of-scope per comment; at minimum, surface the limitation in the review page. [31]

### State model hardening

- **`_snapshotForUndo` snapshots mutable `ScanSession`.** In-place mutation would corrupt the undo stack. Immutable classes harden. [32]
- **Two "layer invisible" concepts — `ContentLayer.visible` + `EditOperation.enabled`.** Kept in sync by the session but one inconsistent update breaks the sync. [11]
- **`reshapeParams` / `skyPresetName` stored on every `AdjustmentLayer`.** Meaningless for 7 of 9 kinds. Sealed hierarchy enforces "right kind carries its params." [11]
- **Parameters map is untyped.** `Map<String, dynamic>` means every op reader re-validates at read time. Typo silently returns identity. Sealed hierarchy or param-schema registry would catch at construction. [02]
- **`FaceReshape` warp not reproducible from params.** Depends on detector output; reload with slightly different contours produces different pixels. Parametric-promise softened here. [21]
- ~~**`DrawingStroke.hardness` blur can exceed stroke width.** Clamp blur radius relative to stroke width. [11]~~ ✅ *Phase X.A.5: `kMaxHardnessBlur = 40.0` top-level constant in `layer_painter.dart`; `(softness * width * 0.5)` clamped to the cap so 100 px soft strokes don't stall low-end GPUs at 50 px blur.*
- **Compare-hold fully invalidates dirty cache.** Releasing re-renders from scratch — jarring for pipelines with expensive AI ops. Key caches by `(opId, enabled)` or snapshot "disabled view." [02]
- **`drop()` returns `Future<void>` but callers don't await.** Orphaned memento files on session close + app kill; bounded by `clear()`'s recursive delete but only if it ran. [04]
- ~~**`historyLimit` = 128 silently evicts oldest.** No user signal when the earliest edit becomes unrevertable. Indicator or configurable cap. [04]~~ ✅ *Phase X.B.1: `HistoryManager.droppedCount` is a cumulative counter incremented in `_enforceHistoryLimit`; `HistoryState.droppedCount` surfaces it through the bloc; `_HistoryCapBanner` in `HistoryTimelineSheet` reads "N earliest edit(s) dropped to keep history under the 128-entry cap". `clear()` resets the counter.*
- ~~**Memento disk-budget eviction is LRU-by-insertion.** 40 MB super-res + 2 MB drawing treated identically. Size-aware eviction. [04]~~ ✅ *Phase X.B.2: `pickDiskEvictionOrder(disk)` is a pure helper that returns disk mementos largest-first with oldest as tiebreaker; `_enforceDiskBudget` consumes that order so one 50 MB super-res goes before 20 × 2 MB drawings. Tests cover pure sort semantics + end-to-end I/O path (path_provider stubbed).*
- **Exporters throw on missing image.** `processedImagePath` may have been swept; per-page fallback to `rawImagePath` across all exporters. [32]
- **`PdfExporter._ocrOverlay` assumes source-pixel bounds.** If ML Kit ever returns logical pixels, overlays mis-scale. No defensive check. [32]
- **Capability probe fails open on `MissingPluginException`.** Missing Android channel → user hits `ScannerUnavailableException` on first tap instead of seeing disabled tile. Retry with banner. [30]
- **Permission pre-check covers Native only.** Manual + Auto gallery picks fall through to generic "Capture failed" on permanent denial; same "Open Settings" CTA would apply. [30]
- ~~**`_isFullRect` tolerance is frame-independent.** 0.005-per-side "did-I-move" ambiguity triggers unnecessary warp. Tighten or make content-aware. [31]~~ ✅ *Phase VIII.A (VIII.20): tightened `kFullRectTolerance` to 0.005 + migrated check to inclusive `<=` so a drag of exactly the threshold still skips the warp. Extracted as `isNearIdentityRect` for direct test coverage.*
- **B&W threshold-offset range mismatch.** Code is ±30 C-value; UI slider is ±1. Scale factor needs a test. [31]

### Packaging / build

- ~~**`_perspectiveWarpDart` compiled in every release build.** 150 lines of dead code on end-user devices. `@visibleForTesting` or build-flag guard. [31]~~ ✅ *Phase II.3: renamed to `perspectiveWarpDartFallback` (`@visibleForTesting`); `_perspectiveWarp` now short-circuits to the native path in `kReleaseMode`. Tree-shaker can eliminate the ~150-line fallback + `_sampleBilinear` from release binaries. 4 new direct tests added.*
- **`tool/bake_luts.dart` is Dart-only.** No community `.cube` support; if user-LUT import ships later, parser + on-device bake is a chunk of work. [12]
- ~~**Built-in LUT paths are string literals.** Scattered across `BuiltInPresets` + pubspec + `tool/bake_luts.dart`. `LutAssets` constants prevent typos. [12]~~ ✅ *Phase X.A.4: `LutAssets` class in `lib/engine/presets/lut_assets.dart` exposes `root` + per-LUT `static const` paths; every built-in preset migrated off raw strings.*
- **`tool/bake_luts` pinned to one format.** 1089×33 PNG only; no alternative format for future model size needs. [12]
- **Shader wrappers and `.frag` files drift independently.** Uniform added to frag requires manual wrapper update; no compiler catch. Generate wrapper or add runtime assertion. [03]
- **Import discipline unenforced.** Nothing prevents `engine/ → features/` imports. `import_lint` or `dependency_validator` locks it. [01]

### Minor UX tuning

- **`Drop at identity` is all-or-nothing on multi-param ops.** Vignette at amount=0 but feather=0.6 survives as a no-op shader pass. Dropping on "effect-strength param at identity" would keep the chain shorter. [10]
- ~~**Snap-to-identity band fixed at 2%.** On narrow ranges (gamma 0.1-4) that's 0.078; on wide ranges (hue ±180°) it's 7.2°. Per-spec tuning would be nice. [10]~~ ✅ *Phase VIII.B (VIII.15): `OpSpec.snapBand` defaults to 0.02; gamma overrides to 0.05, hue to 0.01. `SliderRow` + `_SliderWithIdentityTick` thread the per-spec value.*
- **`CurvesSheet` entry is Light-tab only.** R/G/B curves could also live under Color. Re-visit once per-channel authoring ships. [10]
- ~~**Native-path bypasses crop page entirely.** No way to re-crop a native scan; Review page could expose "Re-crop this page" that opens Crop with `Corners.inset()`. [30]~~ ✅ *Phase VIII.B (VIII.5): `ScannerNotifier.prepareForRecrop` resets corners to `Corners.inset()` and clears the processed output without re-processing; review menu shows the action for all strategies.*
- ~~**Magic-color `scale: 220` hardcoded.** A "Magic Color intensity" slider (180-240) gives user control. [31]~~ ✅ *Phase VIII.B (VIII.19): `ScanPage.magicScale` per-page field threaded through the isolate payload; `PageTunePanel` exposes an Intensity slider when filter is magic-color.*
- ~~**DOCX visible OCR text has no toggle.** Users wanting image-only have no option. "Include OCR as editable paragraphs" checkbox. [32]~~ ✅ *Phase VIII.A (VIII.18) — audit: `ExportOptions.includeOcr` (defaulting to `true`) was already wired end-to-end through the export-sheet toggle and both DOCX/PDF exporters. Added `docx_exporter_ocr_toggle_test.dart` pinning the off-toggle behaviour.*
- **No "revert to prior look" after Preset Apply.** Only undo. Snapshot-before-preset banner that survives subsequent edits. [12]
- **Layer reorder via drag only.** "Send to front/back" context action for large stacks. [11]
- ~~**`OcrService` Latin-only.** Chinese/Japanese/Korean/Devanagari recognizers via separate ML Kit instances. Auto-detect or picker. [32]~~ ✅ *Phase VIII.D (VIII.13): `OcrScript` enum with explicit picker on the export sheet (the PLAN-sanctioned interim per the auto-detect risk note); `OcrService` caches one recognizer per script.*
- ~~**Scanner undo/redo stacks in-memory only.** Resume from History loses buffered steps. Serialize truncated last-N. [32]~~ ✅ *Phase VIII.D (VIII.16): `ScanRepository.save(session, undoStack: …)` truncates to last `kPersistedUndoDepth` (5) entries; `loadWithUndo` returns a `(session, undoStack)` record.*
- **Mask rendering supports only `none/linear/radial`.** Brush-painted and AI-mask scaffolding doesn't exist. [11]
- **No `CollageRepository`.** Re-open past collages not supported. [40]
- ~~**No per-cell zoom/pan in collage.** `BoxFit.cover` only — portrait in landscape cell crops top/bottom with no user control. Single most useful collage improvement. [40]~~ ✅ *Phase VIII.C (VIII.2): `CellTransform(scale, tx, ty)` per cell, persisted on `CollageState.cellTransforms` parallel to `imageHistory`; `_CollageCellWidget` wraps in `Transform` + `GestureDetector(onScaleStart/Update)`.*
- ~~**Only MediaPipe bg removal is always-available offline.** Wiring bundled `u2netp` as a fourth strategy gives non-portrait offline coverage. [21]~~ ✅ *Phase VIII.D (VIII.12, partial): `BgRemovalStrategyKind.generalOffline` + `U2NetBgRemoval` strategy + factory wiring + UI picker subtitle/icon all shipped. The `u2netp.tflite` binary is not yet bundled in the repo, so the strategy throws a typed "model not bundled" exception when invoked — flipping it on requires dropping the file into `assets/models/bundled/`.*

### Persistence keying

- **`sha256(sourcePath)` is absolute-path sensitive.** iOS container UUID changes across reinstalls shift the key and hide the prior project. Content-hash keying survives path changes. [05]
- ~~**Home rename does load → save round-trip.** Loads full pipeline just to rewrite the title. Crash between corrupts. `ProjectStore.setTitle(path, title)` is safer. [40]~~ ✅ *Phase IV.6: new `ProjectStore.setTitle(sourcePath, title) -> Future<bool>` rewrites only the `customTitle` field. Pipeline sub-map is byte-identical across rename (pinned by dedicated test); works even on pipelines too new for the current `EditPipeline.fromJson` to parse. `home_page.dart` `_renameRecent` migrated — 10 new tests cover the invariant + edge cases (empty clears, missing file, atomic crash, gzipped envelope, legacy-JSON bridge).*

### Architectural hygiene

- ~~**`ApplyPresetEvent` is used for layer additions too.** Naming mismatch; logs read like "preset applied" for "Add text layer." Rename to `ApplyPipelineEvent`. [11]~~ ✅ *Phase II.7: renamed to `ApplyPipelineEvent` across all 3 production files + 4 guide docs + CLAUDE.md. Zero `ApplyPresetEvent` references remain in `lib/`.*
- **Two corner taxonomies.** `SeedResult.fellBack` and `corners == Corners.inset()` mean the same thing — they can drift. Make `fellBack` a computed property. [30]
- **HSL / split-toning / curves bypass `OpSpec`.** Bespoke panels for 3 ops today; fine, but any new multi-op would copy the pattern from scratch. [10]
- **Fast-path `_valueFor` drifts from `OpSpecs.all`.** New scalars silently use slow generic path. Assertion or refactor to one typed reader. [10]
- ~~**`_BoolPrefController` instantiated per pref.** Generic `PrefController<T>` consolidates future toggles. [40]~~ ✅ *Phase X.A.3: generic `PrefController<T>` + `BoolPrefController` shorthand in `lib/core/preferences/pref_controller.dart`; settings page migrated off the private controller.*
- ~~**`_passesFor()` branch order is implicit.** 300-line chain — new ops guess placement. Declarative pass-order table + ordering test. [03]~~ ✅ *Phase III.5: `editorPassBuilders` in `lib/features/editor/presentation/notifiers/pass_builders.dart` is the single-screen declarative list. 17 ordering tests in `passes_for_test.dart` pin canonical pipelines + cross-op folds.*
- **`PresetStrength` is side-table metadata, not on `Preset`.** Custom presets always default to `standard`. Either auto-infer strength from op magnitudes or add a picker. [12]
- **`_onSetAll` relies on identity comparison for release.** Current behaviour correct but invariant is implicit. [04]
- **Filter chain has implicit ordering.** Declarative `List<FilterStep>` with stamped identities. [31]
- **`PresetStrip` opens its own `PresetRepository`.** Two editor pages open two sqflite connections. `presetRepositoryProvider` shares one. [12]
- ~~**Optics tab invisible.** Enum value defined, zero specs; tab hidden. Remove from enum or ship stub specs. [10]~~ ✅ *Phase II.5: `OpCategory.optics` removed. ADR at `docs/decisions/optics-tab.md`.*

---

## P3 — Polish

Small, internal, or test-only. Roll up into P1/P2 work when you're in the neighbourhood.

- ~~Shader registry preload is parallel-unbounded → `Pool(4)`. [03]~~ ✅ *Phase V.7: `ShaderRegistry.preload` now uses `runBoundedParallelSettled` with `concurrency: 4`; per-item failure isolation is the behaviour upgrade.*
- `_valueFor` fast path is an opt-in lookup table. [10]
- ~~`lastOpType` raw strings in tooltips. [04]~~ ✅ *Phase X.A.1: see `opDisplayLabel` above.*
- No conflict detection between auto-save + future explicit save. [05]

### Cross-chapter duplicates (same concern, multiple chapters)

These aren't separate items — they're the same improvement flagged from two angles. Address once:

- ~~**"Reads every JSON then filters"** — [05] `ProjectStore.list` + [40] `_refreshRecents`. One sidecar index fixes both.~~ ✅ *Phase IV.8 shipped the sidecar for `ProjectStore.list`; `_refreshRecents` in the home page inherits the speedup with zero callsite changes (still calls `list()`).*
- ~~**"Fixed-at-3 capacity across all devices"** — [04] `maxRamMementos` + [05] `ProxyCache max`. One RAM-scaled policy.~~ ✅ *Phase V.2: `MemoryBudget.fromRam` returns tiered values — 3 for <3 GB, 5 for <6 GB, 8 for ≥6 GB — and `ProxyCache max` mirrors the same tier.*
- ~~**"Three separate file-save helpers"** — [32] 4 scanner exporters + [40] collage + editor-export. One `ExportFileSink`.~~ ✅ *Phase IV.1: consolidated across 5 exporters; editor temp-file path kept separate per scope correction.*
- ~~**"Migration seam / schema versioning"** — [02] `PipelineSerializer._migrate` untested + [05] `ProjectStore` silent drop + [32] `ScanRepository` missing + [12] `PresetRepository` no `onUpgrade`. One persistence-migration pattern across all four stores.~~ ✅ *All four seams landed (Phase I.2) and pinned (Phase IV.2 `ProjectStore`, Phase IV.3 `PresetRepository`). Remaining Phase IV items on this theme: IV.5 routes `ScanRepository.save` through the atomic-write primitive (the migrator is already in place).*
- ~~**"Classifier sets that must stay in sync"** — [02] `EditOpType` four sets + [12] `_presetOwnedPrefixes` vs `presetReplaceable`. One `registerOp` helper.~~ ✅ *Phase III.1 + III.2: the four `EditOpType` sets derive from `OpRegistry`; `PresetApplier.ownedByPreset` reads the same registry flag. One source of truth across both chapters.*

---

## Test gap backlog

All `[test-gap]` candidates consolidated. These are worth scheduling a dedicated "testing debt" pass once P0/P1 items settle.

### Engine-layer gaps

- ~~No test for the `bootstrapResultProvider` throw contract. [01]~~ ✅ *Phase IX.B.1: `bootstrap_result_provider_test.dart` pins the UnimplementedError + "must be overridden" message + propagation through dependent providers (memoryBudget).*
- ~~No test for `reorderLayers` vs mixed non-layer ops. [02]~~ ✅ *Phase IX.A.3: extended `pipeline_layer_reorder_test.dart` with 4 edge cases — all-non-layer pipeline no-op, adjacent layers without interleaved non-layers, non-layer ops at both ends, mixed layer types (text + sticker + drawing).*
- ~~No test asserts `presetReplaceable` excludes every AI op. [02]~~ ✅ *Phase IX.A.2: `preset_ai_exclusion_test.dart` walks every `mementoRequired` op and asserts `presetReplaceable == false`; generated test catches accidentally-replaceable AI ops.*
- ~~No golden test for the color chain composition. [03]~~ ✅ *Phase IX.D.1: `color_chain_golden_test.dart` scaffold in place + skip-gated (`kSkipGoldens = true`) pending Impeller/Skia version pin in CI. Flip the flag + run `--update-goldens` on the pinned image to activate.*
- ~~`_passesFor()` has no direct test. [03]~~ ✅ *Phase III.5: `passes_for_test.dart` drives `editorPassBuilders` directly with a stub `PassBuildContext`, asserting asset-key sequences for canonical pipelines.*
- ~~No concurrency test for `MementoStore.store` under rapid AI ops. [04]~~ ✅ *Phase IX.B.4: 5 tests in `memento_store_test.dart` covering Future.wait-parallel stores, unique-id guarantee, drop+store interleave, payload preservation.*
- ~~Memento fallback "undo via re-render" is asserted only in comments. [04]~~ ✅ *Phase IX.B.5: `memento_missing_fallback_test.dart` drives HistoryManager with dangling `afterMementoId` — undo/redo both succeed without reading the evicted memento.*
- ~~No integration test for disk-full auto-save path. [05]~~ ✅ *Phase IX.C.4: extended `auto_save_controller_test.dart` with 4 disk-full tests using a `_DiskFullStore` that throws `FileSystemException` with `OSError('ENOSPC', 28)`. Covers single failure, recovery when disk frees up, disposed-after-fail, repeated-failure no-leak.*

### Editor-layer gaps

- ~~No widget test for snap-to-identity. [10]~~ ✅ *Phase IX.A.6: extended `slider_row_test.dart` with 4 haptic-observation tests (first-entry fires once, 10-tick dwell stays at one, exit-then-reenter fires again, no-dwell pass-through still fires once). Mocks `SystemChannels.platform` to count `HapticFeedback.vibrate` invocations.*
- ~~No regression test for the dock's empty-category filter. [10]~~ ✅ *Phase IX.A.4: `dock_category_filter_test.dart` pins that every current `OpCategory` has at least one spec and the filter predicate excludes any empty category.*
- ~~No golden tests for per-shader visual output. [10]~~ ✅ *Phase IX.D.2: `per_shader_goldens_test.dart` scaffold enumerates all 23 shaders + skip-gated pending the Impeller pin. `kAllShaderKeys` list catches "new shader added without golden" at review time.*
- ~~No test for `AdjustmentKind` enum order stability. [11]~~ ✅ *Phase IX.A.1: `adjustment_kind_order_test.dart` pins the 9-value enum order + labels + `fromName` round-trip + fallback on unknown.*
- ~~No test asserts `_interpolatingKeys` stays in sync with `OpSpecs.all`. [12]~~ ✅ *Phase III.1: `_interpolatingKeys` moved onto each `OpRegistration` in `OpRegistry`; consistency test pins that every declared key matches an existing spec `paramKey`.*

### AI-layer gaps

- ~~No end-to-end test for `bootstrap()`'s AI wiring. [20]~~ ✅ *Phase IX.C.2: `bootstrap_ai_wiring_test.dart` drives the full provider graph with a fake `BootstrapResult`; asserts registry resolves manifest entries, factory.availability reports correct state per strategy (ready/downloadRequired/unknownModel), degradation signal propagates.*
- ~~No integration test for "AI op → memento captured → undo restores pre-op pixels". [21]~~ ✅ *Phase IX.C.3: `ai_memento_undo_roundtrip_test.dart` pins the happy path — store pre-op bytes via MementoStore, execute AI op, undo, verify memento bytes come back byte-for-byte. Covers multi-op chain + history-limit eviction too.*

### Scanner-layer gaps

- ~~No test for gallery-pick → undecodable-file chain. [30]~~ ✅ *Phase IX.B.3: `undecodable_pick_test.dart` covers garbage bytes, empty file, preview+full graceful degrade + control-path valid JPEG. Also patched `_processInIsolate` to catch the `RangeError` the `image` package throws on empty buffers (pre-IX.B.3 bug — empty file would crash the isolate).*
- ~~No test for `permanentlyDenied` → `requiresSettings` flag. [30]~~ ✅ *Phase IX.B.2: `permission_requires_settings_test.dart` covers every `PermissionStatus` variant + message wording + toString.*
- ~~No end-to-end test for `_processGen` stale-result guard. [31]~~ ✅ *Phase IV.4: the `_processGen` pattern is now the shared `GenerationGuard<K>` helper (`lib/core/async/generation_guard.dart`); 15 dedicated guard tests pin the semantics directly (rapid same-key, single-slot bake, decode-vs-cache, forget-while-in-flight, clear-drops-all). An end-to-end scanner-layer test is still worth adding in Phase IX when the notifier mocking infra lands — the helper-level coverage is the baseline.*
- ~~Exporters (`PdfExporter`, `DocxExporter`, `TextExporter`, `JpegZipExporter`) are untested. [32]~~ ✅ *Phase IX.C.1: `exporters_e2e_test.dart` covers PDF (header + OCR inclusion + OCR-skip), Text (page separators, OCR-skip, UTF-8 round-trip, no-OCR fallback message), JpegZip (sequential naming, valid JPEG content, empty throws, 10+ page pad-left). DOCX already covered by VIII.18's `docx_exporter_ocr_toggle_test.dart`; PDF password-absence by Phase I.8's `pdf_exporter_password_honesty_test.dart`.*

### Other-surfaces gaps

- Collage has zero test coverage. [40]
- ~~`PerfHud`'s `kReleaseMode` guard is untested. [40]~~ ✅ *Phase IX.A.5: `perf_hud_test.dart` pins the `enabled: false` short-circuit and the zero-samples early-exit; the `kReleaseMode` branch is compile-time-folded so the disabled-flag path stands in as the faithful proxy (same `SizedBox.shrink()` branch).*

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

### ~~Package C — Op registration consolidation (P2, 3-5 days)~~ ✅ *Phase III complete.*
~~Addresses: four classifier sets in `EditOpType`, `OpSpecs` registration split, `_passesFor` branch order, `PresetApplier._presetOwnedPrefixes` duplication, `NLM denoise` missing pass.~~
~~Files: `lib/engine/pipeline/edit_op_type.dart`, `lib/engine/pipeline/op_spec.dart`, `lib/features/editor/presentation/notifiers/editor_session.dart` (the `_passesFor` extraction), `lib/engine/presets/preset_applier.dart`.~~
~~Impact: adding a new op becomes a single-entry change; several dormant bugs get fixed en route.~~
Landed via **Phase III** (6 items, `docs/PLAN.md`): `OpRegistry` + `OpRegistration` own flags/specs/interp-keys; `editorPassBuilders` owns the pass order; `PresetApplier.ownedByPreset` reads the registry. +48 tests across `registry_consistency_test`, `preset_applier_ownership_test`, `preset_intensity_test`, `passes_for_test`. `NLM denoise` was cleaned up in Phase I.7 (delete path). Adding a new op is now one entry in `OpRegistry._entries` + one builder in `pass_builders.dart`.

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
