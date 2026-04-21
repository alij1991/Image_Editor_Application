# Flutter Image Editor — Engineering Guide

This guide documents every feature of the image editor in detail, engineering-first. Read chapters in any order; Phase 1 (Foundations) chapters are referenced by everything else and are the recommended starting point.

Each chapter follows the template in [`_conventions.md`](guide/_conventions.md). Where a chapter identifies a limitation or rough edge, it gets logged into [`IMPROVEMENTS.md`](IMPROVEMENTS.md) for a follow-up pass.

## Status legend

- ✅ written
- 🚧 in progress
- ⬜ not yet written

---

## Phase 1 — Foundations

Everything else depends on these. Read here first.

- ✅ [01 — Architecture Overview](guide/01-architecture-overview.md) — feature modules, engine, AI, shaders, DI; how a pixel gets from disk to screen; where each subsystem lives
- ✅ [02 — Parametric Pipeline](guide/02-parametric-pipeline.md) — `EditPipeline`, `EditOperation`, op types, matrix composition, dirty tracking, serialization
- ✅ [03 — Rendering Chain & Tone Curves](guide/03-rendering-chain.md) — `_passesFor()`, `ShaderRegistry`, `ShaderRenderer`, the 5×4 matrix fast path, `ToneCurveSet` + `CurveLutBaker` + 256×4 LUTs, `ImageCanvasRenderBox`
- ✅ [04 — History & Memento Store](guide/04-history-and-memento.md) — `HistoryBloc`, states, events, RAM ring + disk-spill, budget enforcement, compare-hold
- ✅ [05 — Persistence & Memory](guide/05-persistence-and-memory.md) — `ProjectStore` auto-save (debounce + SHA256 keying), `ProxyManager` LRU viewport cache, `MemoryBudget` device-aware sizing

## Phase 2 — Editor Tools

- ✅ [10 — Editor Tool Surface](guide/10-editor-tools.md) — Light, Color, Effects, Detail, Optics, Geometry; `OpSpec` registry, `LightroomPanel`, HSL panel, split-toning panel, curves sheet, per-op shader notes
- ✅ [11 — Layers & Masks](guide/11-layers-and-masks.md) — text / sticker / drawing / raster / adjustment layers, `LayerStackPanel`, blend modes, procedural + raster masks
- ✅ [12 — Presets & LUTs](guide/12-presets-and-luts.md) — `Preset`, `PresetApplier` (reset vs merge), built-ins, `LutAssetCache`, 3D LUT sampling, user-saved presets

## Phase 3 — AI Features

- ✅ [20 — AI Runtime & Models](guide/20-ai-runtime-and-models.md) — `OrtRuntime`, `LiteRtRuntime`, delegates, manifest format, bundled vs downloaded, dispose-guard pattern, Model Manager UI
- ✅ [21 — AI Services](guide/21-ai-services.md) — one section each: background removal, face detect + portrait beauty, sky replace, style transfer, inpaint, super-resolution

## Phase 4 — Scanner

- ✅ [30 — Capture & Detection](guide/30-scanner-capture.md) — strategy picker (native/manual/auto), capability probe, corner seeders (OpenCV → Sobel → inset), coaching banner
- ✅ [31 — Processing & Filters](guide/31-scanner-processing.md) — perspective warp, Canny+Hough deskew, auto-rotate, B&W adaptive threshold, Retinex magic-color, document classifier, per-page tune
- ✅ [32 — OCR & Export](guide/32-scanner-export.md) — `OcrEngine` interface + ML Kit impl, searchable PDF text layer, multi-page extension, PDF / DOCX / text / JPEG-ZIP exporters

## Phase 5 — Remaining Surfaces

- ✅ [40 — Collage, Home & Settings](guide/40-other-surfaces.md) — collage templates + canvas + exporter, home feature picker + routing + recent projects, settings (theme, logging, model manager, perf HUD)

## Phase 6 — Improvement Register

- ✅ [`IMPROVEMENTS.md`](IMPROVEMENTS.md) — 152 candidates rolled up, ranked P0–P3 × theme, with a starter batch and 7 work packages.

## Phase 7 — Polish & Implementation Plan

- ✅ Cross-links between chapters verified (43 inter-chapter links across 14 files; all resolve).
- ✅ `file:line` pointers spot-checked against HEAD (6 heavily-referenced files verified — sizes and target symbols match documentation).
- ✅ [`PLAN.md`](PLAN.md) — **the execution doc**. 10 phases with explicit ordering, per-phase test plans, and exit criteria. Items within each phase are sorted by importance (most-harmful / highest-leverage first). Includes dependency graph, effort estimates, and single/two/three-track schedules.

---

**Total: 12 chapters** + `IMPROVEMENTS.md` (register) + `PLAN.md` (sequenced execution plan). The documentation phase ends here — work from `PLAN.md` onward.
