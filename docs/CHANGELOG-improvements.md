# Improvements Changelog

Historical record of shipped improvements from the [Improvements Register](IMPROVEMENTS.md). This file mirrors the strike-through entries in that register, grouped by the phase that landed them. Each entry is a one-line fix summary lifted from the register's `*Phase X.Y: …*` annotation. Chapter tags in `[NN]` link back to the engineering guide.

---

## Phase I — P0 foundations

- **No write-ahead for pipeline JSON.** `atomicWriteString` + `atomicWriteBytes` in `lib/core/io/atomic_file.dart` (tmp + flush + rename + test-only `debugHookBeforeRename`); adopted by `ScanRepository`, `CollageRepository`, and `ProjectStore`. [05]
- **Migration seam present but untested.** Registered the seams in Phase I.2 — later pinned by `pipeline_roundtrip_test.dart` (v0 → v1 pipeline path) and `project_store_test.dart` (wrapper-level). [02]
- **`PresetRepository` has no `onUpgrade`.** Registered the `onUpgrade` handler in Phase I.2 (no-op until a real schema change lands). [12]
- **Placeholder sha256 disables download verification (LaMa 208 MB, RMBG 44 MB).** Pinned via HuggingFace `X-Linked-ETag` — real 64-char hashes + accurate byte sizes. [20]
- **`colorization_siggraph` URL is `https://example.com/`.** Op type removed, manifest entry deleted, legacy round-trip test added. [20]
- **`EditOpType.aiColorize` has no service.** Op type removed; legacy pipelines tolerate the stale op string at load time. [21]
- **`NLM denoise` op has no pass.** `denoiseNlm` constant + its `presetReplaceable` membership deleted; `shader_pass_required_consistency_test.dart` guards against recurrence. [10]
- **PDF password is silently ignored.** `ExportOptions.password` + the exporter's TODO branch deleted; `pdf_exporter_password_honesty_test.dart` runtime-asserts no `/Encrypt` token. [32]
- **`AdjustmentLayer.cutoutImage` lost on session reload.** New `CutoutStore` (PNG-keyed by `(sourcePath, layerId)`, 200 MB disk budget); `EditorSession.start` hydrates on open. [11]
- **Bootstrap silently degrades on manifest-load failure.** New `BootstrapDegradation` record + `manifestDegradationProvider`; Model Manager sheet renders a banner with the cause. [01]
- **`IsolateInterpreterHost` is never used.** Scaffold + 5 orphan tests deleted — `flutter_litert` / `onnxruntime_v2` already run off-main. [20]

## Phase II — Quick cleanups

- **Delete `SuperResolutionService` scaffold.** Scaffold + its test deleted; guide cleaned up. [21]
- **Bundled `selfie_segmenter` / `face_detection_short` manifest theatre.** `"metadataOnly": true` added to both entries; parse loop skips them. [21]
- **`_perspectiveWarpDart` compiled in every release build.** Renamed to `perspectiveWarpDartFallback` (`@visibleForTesting`); `_perspectiveWarp` short-circuits to the native path in `kReleaseMode`. [31]
- **StyleTransfer input-size comment drift.** 6 stale 256 occurrences updated to 384. [21]
- **Optics tab invisible.** `OpCategory.optics` removed. ADR at `docs/decisions/optics-tab.md`. [10]
- **Rename `ApplyPresetEvent`.** Renamed to `ApplyPipelineEvent` across all 3 production files + 4 guide docs + CLAUDE.md. [11]

## Phase III — Op registration consolidation

- **Tool registration split across 4 places.** `OpRegistration` in `lib/engine/pipeline/op_registry.dart` owns flags/specs/interp-keys; adding an op is now two files — a registry entry and a pass builder. [10]
- **Four classifier sets in `EditOpType`.** The four sets are now `static final` getters on `OpRegistry` derived from each entry's boolean flags; 17 consistency tests. [02]
- **Two classifier sets for preset-owned ops.** Prefix list deleted; `ownedByPreset` reads `OpRegistry.presetReplaceable` directly. [12]
- **LUT intensity not in `_interpolatingKeys`.** Tagged `interpolatingKeys: {'intensity'}` on `filter.lut3d` `OpRegistration`; renderer clamps to `[0, 1]`. [12]
- **`_passesFor()` branch order is implicit.** `editorPassBuilders` in `lib/features/editor/presentation/notifiers/pass_builders.dart` is the single declarative list; 17 ordering tests. [03]

## Phase IV — Persistence & consolidation

- **Four separate `_saveBytes` / `_timestampName` implementations.** `writeExportBytes` / `writeExportString` in `lib/core/io/export_file_sink.dart`; all 4 scanner exporters + collage consolidated (5 total). Editor temp-file path kept separate per scope correction. [32, 40]
- **Two serialization paths co-exist.** `ProjectStore.save/load/list` now route envelopes through the shared `encodeCompressedJson`/`decodeCompressedJson` codec; migration seams on both wrapper and pipeline run on every load. [05]
- **`PresetRepository` has no `onUpgrade` (pinning).** 7 synthetic schema tests via `sqflite_common_ffi` dev dep pin fresh v1 open, v1 → v2 bump preserves rows, v1 → v5 big jump, idempotent same-version reopen. [12]
- **No end-to-end test for `_processGen` stale-result guard.** Extracted into shared `GenerationGuard<K>` helper (`lib/core/async/generation_guard.dart`); 15 dedicated tests. [31]
- **Home rename does load → save round-trip.** New `ProjectStore.setTitle(sourcePath, title)` rewrites only the `customTitle` field; 10 tests cover the invariant + edge cases. [40]
- **`customTitle` re-read every save.** `ProjectStore._titleCache` populated by `load` / `list` / `save` / `setTitle`, invalidated by `delete`; 9 cache tests. [05]
- **`ProjectStore.list` reads every JSON then discards.** New `<root>/_index.json` sidecar + in-memory shadow; cold-start rebuilds via directory walk then persists. [05]
- **Placeholder sha256 (modnet + real_esrgan_x4).** Pinned via HuggingFace `X-Linked-ETag`; `test/ai/manifest_integrity_test.dart` enforces "every downloadable has a pinned sha256 or lives in a named, justified allow-list." [20]

## Phase V — Memory & runtime scaling

- **Beauty services re-run face detection per service.** New `FaceDetectionCache` (sourcePath → `Future<List<DetectedFace>>`) owned by `EditorSession`; 3× → 1× ML Kit call. [21]
- **RAM-ring memento capacity fixed at 3.** `MemoryBudget.fromRam` returns tiered values — 3 for <3 GB, 5 for <6 GB, 8 for ≥6 GB. `ProxyCache` max mirrors the same tier. [04, 05]
- **`ModelCache.evictUntilUnder` never called.** New `DiskStatsProvider` + `ModelCacheGuard`; bootstrap runs guard unawaited (free-space < 500 MB → `evictUntilUnder(400 MB)`). [20]
- **`ImageCachePolicy.purge()` is implemented but never wired.** New `ImageCacheWatchdog` polls `nearBudget` every 60 frames; fires `purge` on two consecutive hits. [05]
- **`StylePredictService` has no result cache.** New `StyleVectorCache` stores 100 float32 as 400 bytes at `<AppDocs>/style_vectors/<sha>.bin`; content-keyed, survives app restarts. [21]
- **Curve LUT bake runs on UI isolate.** `CurveLutBaker.bakeInIsolate` moves 1024-Hermite byte-gen behind `compute()`; `EditorSession` single-slot queue coalesces sustained drags. [03]
- **Shader preload is unbounded parallel.** New `runBoundedParallel` / `runBoundedParallelSettled` in `lib/core/async/bounded_parallel.dart`; `ShaderRegistry.preload` uses settled variant with `concurrency: 4`. [03]
- **ORT spawns fresh isolate per run.** `OrtV2Session.runTyped` switched to `runAsync` (persistent isolate per session). [20]
- **OpenCV seeder FFI round-trip per page.** New `CornerSeeder.seedBatch`; `OpenCvCornerSeed` pushes multi-page imports through a single `compute()` worker. [30]
- **`MemoryBudget.probe` uses `.data['physicalRamSize']`.** Extracted into `MemoryBudget.extractRamBytes({platform, data})` — pure, test-injectable — emits WARNING log when key is absent. Pubspec pinned to `device_info_plus ^10.1.2`. [05]

## Phase VI — Per-frame allocation

- **Intermediate `PictureRecorder` allocations per pass per frame.** New `ShaderTexturePool` with two `ui.Image` slots + frame-reset ping-pong cursor; peak intermediate lifetime bounded to 2 slots regardless of pass count. [03]
- **Matrix composition rebuilds `Float32List` on every tick.** `MatrixComposer.composeInto(pipeline, out)` writes into caller-owned 20-element buffer; 3-op pipeline drops from 7 per-frame allocations → 0. [02]
- **`LayerPainter` recomputes blend / mask gradients per frame.** New `LayerMask.cacheKey` + module-private `_MaskGradientCache` LRU (capacity 16); 1000-paint stable-mask burst: 999/1000 hit rate. [11]
- **`HistogramAnalyzer` pixel loop runs on the UI isolate.** `analyzeInIsolate(src)` mirrors Phase V.6; pure pixel-binning + percentile math crosses `compute()` boundary. [10]
- **Scanner post-capture runs warp + filter sequentially across pages.** New `processPendingPagesParallel` wrapping `runBoundedParallel` with `kPostCaptureProcessConcurrency = 4`. [31]
- **`PresetThumbnailCache` per-session with manual invalidation.** Refactored to process-wide singleton keyed by `(previewHash, preset.id)`; 64-entry LRU, invalidation implicit via preview-hash keying. [12]
- **Scanner seeder runs serially per page.** `CornerSeeder.seedBatch` default forwarder migrated to `Future.wait(imagePaths.map(seed))`; order preservation guaranteed. [30]

## Phase VII — editor_session.dart decomposition

- **`editor_session.dart` is 2132 lines.** Four-item arc extracted `AutoSaveController` (VII.1), `AiCoordinator` (VII.2), `RenderDriver` (VII.3), and folded 9 AI `applyXxx` methods into `AiCoordinator` (VII.4). Session dropped to 1408 lines; exit criterion (<800) did not clear, residue tracked for Phase IX. [01]

## Phase VIII — UX polish

- **Blend-mode picker not exposed on layers.** Audited — `LayerEditSheet` already iterates `LayerBlendMode.values`; widget test pins the contract. [11]
- **Download prompts don't show estimated time.** Confirm dialog renders "44 MB (~15 s on Wi-Fi, ~3 min on 4G)" via new `formatDownloadEstimates(sizeBytes)` helper. [21]
- **Model Manager "cancel" leaves partial file on disk.** New "Cancel & Delete" action runs `deletePartialFor(cache, descriptor)`; split-button UI exposes both options. [40]
- **Router has no deep-link validation.** `GoRoute.redirect` on `/editor` sends user back to `/` and fires snackbar via new `rootScaffoldMessengerKey`. [01]
- **`_isFullRect` tolerance is frame-independent.** Tightened `kFullRectTolerance` to 0.005 + migrated check to inclusive `<=`; extracted as `isNearIdentityRect`. [31]
- **DOCX visible OCR text has no toggle.** Audit: `ExportOptions.includeOcr` already wired end-to-end; added `docx_exporter_ocr_toggle_test.dart`. [32]
- **Strong presets default to 80% but slider is behind second tap.** `InlineAmountSlider` listens to `appliedPreset`; disabled + caption when no preset, enabled with live amount otherwise. [12]
- **Native-path bypasses crop page entirely.** `ScannerNotifier.prepareForRecrop` resets corners to `Corners.inset()` and clears processed output; review menu shows action for all strategies. [30]
- **`CollageExporter` fixed at `pixelRatio: 3.0`.** New `showCollageResolutionPicker` modal sheet returns 3× / 5× / 8×. [40]
- **Sky mask heuristic silently accepts blue walls.** `SkyReplaceService(maxCoverageRatio: 0.60)` + `MaskStats.coverageRatio` getter; throws typed exception above threshold. [21]
- **Coaching banner doesn't point to which page.** `DetectionResult.autoFellBackPages` populated; `coachingNoticeFor` produces "on page N" / Oxford-comma list for 3+. [30]
- **Snap-to-identity band fixed at 2%.** `OpSpec.snapBand` defaults to 0.02; gamma overrides to 0.05, hue to 0.01. [10]
- **Magic-color `scale: 220` hardcoded.** `ScanPage.magicScale` per-page field threaded through isolate payload; `PageTunePanel` exposes Intensity slider. [31]
- **Filter chips show labels but not previews.** `FilterPreview.colorFilterFor(ScanFilter)` builds 5×4 matrix approximation; `FilterChipRow` renders `ColorFiltered` thumbnails. [31]
- **`DocumentClassifier` doesn't consider image blur.** `ImageStats.sharpness` (Laplacian variance / 250 clamped); classifier demotes high-chroma low-sharpness to `unknown`. [31]
- **No per-cell zoom/pan in collage.** `CellTransform(scale, tx, ty)` per cell, persisted parallel to `imageHistory`; `_CollageCellWidget` wraps in `Transform` + `GestureDetector`. [40]
- **No "Save to Files" shortcut after export.** `SaveToFiles.save(path)` Dart helper + `SaveToFilesPlugin.swift` (iOS) wrap `UIDocumentPickerViewController(forExporting:)`. [32]
- **`OcrService` Latin-only.** `OcrScript` enum with explicit picker on export sheet; `OcrService` caches one recognizer per script. [32]
- **Only MediaPipe bg removal is always-available offline.** `BgRemovalStrategyKind.generalOffline` + `U2NetBgRemoval` + factory wiring shipped; `u2netp.tflite` binary not yet bundled (strategy throws typed "model not bundled" when invoked). [21]
- **Scanner undo/redo stacks in-memory only.** `ScanRepository.save(session, undoStack: …)` truncates to last `kPersistedUndoDepth` (5) entries; `loadWithUndo` returns `(session, undoStack)` record. [32]

## Phase IX — Test gaps & goldens

- **No test for `AdjustmentKind` enum order stability.** `adjustment_kind_order_test.dart` pins 9-value enum order + labels + `fromName` round-trip. [11]
- **No test asserts `presetReplaceable` excludes every AI op.** `preset_ai_exclusion_test.dart` walks every `mementoRequired` op. [02]
- **No test for `reorderLayers` vs mixed non-layer ops.** Extended `pipeline_layer_reorder_test.dart` with 4 edge cases. [02]
- **No regression test for the dock's empty-category filter.** `dock_category_filter_test.dart` pins every current `OpCategory` has at least one spec. [10]
- **`PerfHud`'s `kReleaseMode` guard is untested.** `perf_hud_test.dart` pins `enabled: false` short-circuit; `kReleaseMode` branch is compile-time-folded. [40]
- **No widget test for snap-to-identity.** Extended `slider_row_test.dart` with 4 haptic-observation tests. [10]
- **No test for the `bootstrapResultProvider` throw contract.** `bootstrap_result_provider_test.dart` pins the UnimplementedError + propagation through dependent providers. [01]
- **No test for `permanentlyDenied` → `requiresSettings` flag.** `permission_requires_settings_test.dart` covers every `PermissionStatus` variant. [30]
- **No test for gallery-pick → undecodable-file chain.** `undecodable_pick_test.dart` covers garbage bytes, empty file, graceful degrade; patched `_processInIsolate` to catch `RangeError` on empty buffers. [30]
- **No concurrency test for `MementoStore.store` under rapid AI ops.** 5 tests in `memento_store_test.dart` covering Future.wait-parallel stores + unique-id guarantee. [04]
- **Memento fallback "undo via re-render" asserted only in comments.** `memento_missing_fallback_test.dart` drives HistoryManager with dangling `afterMementoId`. [04]
- **Exporters (`PdfExporter`, `TextExporter`, `JpegZipExporter`) untested.** `exporters_e2e_test.dart` covers PDF, Text, JpegZip (sequential naming, empty throws, pad-left). [32]
- **No end-to-end test for `bootstrap()`'s AI wiring.** `bootstrap_ai_wiring_test.dart` drives full provider graph with fake `BootstrapResult`. [20]
- **No integration test for "AI op → memento captured → undo restores pre-op pixels".** `ai_memento_undo_roundtrip_test.dart` pins happy path + multi-op chain + history-limit eviction. [21]
- **No integration test for disk-full auto-save path.** Extended `auto_save_controller_test.dart` with 4 disk-full tests using `_DiskFullStore` throwing `FileSystemException(ENOSPC, 28)`. [05]
- **No golden test for the color chain composition.** `color_chain_golden_test.dart` scaffold in place + skip-gated pending Impeller/Skia version pin. [03]
- **No golden tests for per-shader visual output.** `per_shader_goldens_test.dart` scaffold enumerates all 23 shaders + skip-gated. [10]

## Phase X — Polish & residuals

### X.A — editor & engine polish
- **`lastOpType` / `nextOpType` are raw op-type strings.** Extracted `opDisplayLabel(type)` in `lib/engine/history/op_display_names.dart`; `editor_page._opLabel` is now a one-line alias; `HistoryTimelineSheet` shares the same helper (no drift). [04]
- **`FirstRunFlag` keyed off versioned strings.** `OnboardingKeys` class in `lib/core/preferences/first_run_flag.dart` registers keys; `FirstRunFlag.editorOnboardingV1` kept as deprecated forwarder. [40]
- **`_BoolPrefController` instantiated per pref.** Generic `PrefController<T>` + `BoolPrefController` shorthand in `lib/core/preferences/pref_controller.dart`; settings page migrated off the private controller. [40]
- **Built-in LUT paths are string literals.** `LutAssets` class in `lib/engine/presets/lut_assets.dart` exposes `root` + per-LUT `static const` paths; every built-in preset migrated off raw strings. [12]
- **`DrawingStroke.hardness` blur can exceed stroke width.** `kMaxHardnessBlur = 40.0` top-level constant; `layer_painter` clamps `(softness * width * 0.5)` to the cap so 100 px soft strokes don't stall low-end GPUs at 50 px blur. [11]

### X.B — engine & scanner residuals
- **`historyLimit` = 128 silently evicts oldest.** `HistoryManager.droppedCount` cumulative counter; `_HistoryCapBanner` reads "N earliest edit(s) dropped to keep history under the 128-entry cap". [04]
- **Memento disk-budget eviction is LRU-by-insertion.** `pickDiskEvictionOrder(disk)` returns disk mementos largest-first with oldest as tiebreaker; one 50 MB super-res goes before 20 × 2 MB drawings. [04]
- **`compute()` failure in scanner falls back to main thread.** `_runOffThread(payload)` wraps `Isolate.run` with single retry; both failures return `Uint8List(0)` — no synchronous CPU work on UI isolate. [31]

## Phase XI — Audit + deferred perf / feature residuals

### XI.0 — Audit
- **Cross-check 86 ✅ annotations against HEAD.** 3 parallel audit agents verified Phase I–IV, V–VII, VIII–X; every file, class, function, and constant exists; behaviour matches. Critical checks green: curve LUT race guard, shader pool peer-dispose, matrix-composer zero-alloc, goldens skip-gated, `u2netp.tflite` typed-exception stub.
- **`project_store_test.dart` two dead tests.** Phase IV.8 `_index.json` sidecar broke `files.first as File` — the corruption landed on the sidecar instead of the project JSON. Both tests now use the `singleProjectFile()` helper introduced for this exact problem. [05]

### XI.A — Perf wins
- **`DirtyTracker._mapEquals` shallow compare.** New `_deepEquals` recurses into `List` / `Map`; HSL (8-element float lists), split-toning (`[r,g,b]` + balance), and tone-curve (nested `List<List<double>>`) rebuilds with identical values no longer force a false dirty. 4 new tests. [03]
