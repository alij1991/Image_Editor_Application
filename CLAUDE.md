# Flutter Image Editor

## Build & Run
```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs  # *.freezed.dart, *.g.dart
flutter run
flutter analyze
flutter test                                              # 515+ tests
```

## Architecture

```
lib/
├── core/                 — logging, theme, routing, prefs, memory budgets, platform HAL
├── di/providers.dart     — Riverpod providers (DI + state)
├── ai/
│   ├── runtime/          — LiteRT (TFLite) and ORT (ONNX) wrappers
│   ├── services/         — bg_removal, face_detect, portrait_beauty, sky_replace,
│   │                       style_transfer, inpaint, super_resolution
│   └── manifest.json     — single source of truth for model URLs / sha256
├── engine/
│   ├── pipeline/         — EditPipeline (parametric), EditOperation, OpSpec, ToneCurveSet
│   ├── history/          — HistoryBloc + MementoStore (RAM ring + disk-spill, 200 MB)
│   ├── layers/           — ContentLayer (text/sticker/drawing/raster/shape/adjustment)
│   ├── presets/          — Preset, PresetApplier (reset|merge), LutAssetCache
│   ├── color/            — ToneCurve (Hermite), CurveLutBaker (256x4 RGBA)
│   └── rendering/        — ShaderRegistry, ShaderRenderer, shader wrappers
├── features/
│   ├── editor/           — main image-editor route + session + tool panels
│   ├── scanner/          — document scanner (capture, crop, filter, OCR, export)
│   └── collage/          — multi-image collage canvas
└── shaders/*.frag        — GLSL fragment shaders for the color/effect chain
```

## Pipeline & State Model
- **Parametric** — every edit is an `EditOperation` (`type` + `parameters` map). The pipeline is the source of truth; pixels are derived.
- **Categories drive UI** — `OpCategory` enum (Light, Color, Effects, Detail, Geometry, Layers, AI) maps to dock tabs.
- **Render** — `_passesFor()` in `editor_session.dart` walks the committed pipeline and emits a `List<ShaderPass>` consumed by `ShaderRenderer`.
- **History** — `HistoryBloc` (Bloc) emits `HistoryState`; `MementoStore` persists destructive ops (AI rasters) keyed by content hash, evicts oldest when over budget.
- **Compare hold** — `setAllOpsEnabledTransient(false)` overlays a `_transientPipeline` on the session without writing history.

## Key Patterns
- **New shader**: `.frag` → Dart wrapper in `engine/rendering/shaders/` → call site in `_passesFor()`.
- **New AI feature**: service in `ai/services/` → `AdjustmentKind` in `content_layer.dart` → handler in `editor_page.dart` → session `apply*()` method that caches via `_cacheCutoutImage(layerId, image)`.
- **New scalar slider**: add `OpSpec` in `op_spec.dart` (drives label, min, max, identity, group); `LightroomPanel` renders it automatically.
- **Models**: bundled (asset → temp via `rootBundle.load()`) or downloaded (`OrtRuntime`/`LiteRtRuntime`). `assets/models/manifest.json` is the contract.
- **ONNX models**: `OrtRuntime`, CPU-only (CoreML delegate disabled — caused OOM in field testing).
- **TFLite models**: `LiteRtRuntime`, CoreML delegate enabled on iOS.
- **AI services**: dispose-guard pattern — check `_disposed` before AND after async inference.

## Tone Curves (per-channel)
- `ToneCurveSet` (lib/engine/pipeline/tone_curve_set.dart) groups Master/R/G/B point lists with a stable `cacheKey`.
- `pipeline.toneCurves` reads all four channels; `pipeline.toneCurvePoints` is a master-only convenience wrapper.
- `EditorSession.setToneCurveChannel(channel, points)` merges into the existing op; identity collapses drop the op.
- `CurvesSheet` switches channels via colour-coded chips; `CurveLutBaker` bakes a 256×4 RGBA texture sampled by `shaders/curves.frag`.

## Scanner Section
- **Strategies** — `DetectorStrategy.{native, manual, auto}`. Native uses `cunning_document_scanner` (VisionKit on iOS, ML Kit on Android). Manual = pick + crop. Auto = pick + Sobel-seeded corners + crop.
- **Pipeline** — capture → corners → `ScanImageProcessor.process()` (perspective warp via `opencv_dart` + filter, isolate) → review/filter swap → export (PDF/DOCX/text/JPEG ZIP). Pure-Dart bilinear warp remains as the fallback when the OpenCV native lib can't load.
- **Deskew** — `estimateDeskewDegrees()` uses Canny + probabilistic Hough through `opencv_dart`; works on text-less pages. Falls back to the OCR-block-baseline heuristic when Hough yields fewer than 8 lines.
- **Auto-detect coaching** — `ClassicalCornerSeed` returns a `SeedResult` with a `fellBack` flag (decode failure, no edges, sparse edges, or coverage > 95% of the frame). The crop page surfaces a `_CoachingBanner` summarising how many pages need manual nudging.
- **Capability probe** — Android calls a `com.imageeditor/play_services` method channel handled by `MainActivity` so `GoogleApiAvailability.isGooglePlayServicesAvailable` flows into the strategy picker (fail-open via `MissingPluginException`).
- **OCR** — `ocr_service.dart` wraps Google ML Kit; PDF embeds invisible text layer for searchability.
- **Known gaps** — no shadow removal yet, no MobileSAM-backed quad fit yet, PDF password is a TODO.

## Conventions
- Presets commit via `ApplyPresetEvent` for atomic multi-op writes.
- Every op has an `enabled` flag — before/after toggle uses `setAllOpsEnabledTransient`.
- Logger format: `13:42:33.591 D Component msg key=val` (`AppLogger`); default Info in debug, Warning in release. Hydrate persisted level from `main()`.
- Auto-save debounces commits to `ProjectStore` after 600 ms, keyed by `sha256(sourcePath)`.
- Worktrees live under `.claude/worktrees/<name>/` and run their own branch (`claude/<name>`). The repo's `.gitignore` excludes `.claude/`.

## Common Issues
- CocoaPods needs `export LANG=en_US.UTF-8` in `~/.zshrc`.
- Models re-download in debug — iOS assigns a new container UUID per deploy.
- Generated files missing → run `build_runner`.
- Bundled TFLite: `LiteRtRuntime` copies asset to a temp file via `rootBundle.load()` because the LiteRT C API takes a path.
- `share_plus` 10.x — use `Share.shareXFiles([XFile(...)], text: ...)`. No `ShareParams` / `SharePlus.instance` API.
- `image` 4.x doesn't encode WebP; export keeps it in the enum for forward compat but doesn't offer it in the UI.

## Tests
- 515+ tests, all engine-level (pipeline, presets, history, memento, tone curves, etc.). Widget tests cover home + a few editor surfaces.
- **Gap**: scanner has zero tests; AI services aren't mocked; no integration smoke for export round-trips.

## Status snapshot
Editor (Light/Color/Effects/Detail/Geometry/Layers/Presets): working.
AI: bg removal + face detect + portrait beauty (eye/teeth/smooth) — real models. Sky replace — heuristic. Style transfer / inpaint / super-res — service scaffolds awaiting bundled model files.
Scanner: native + manual + auto cropping all work cross-platform; processing/OCR/export functional; auto detection is a Sobel heuristic and there is no shadow removal — these are the next overhaul targets.
