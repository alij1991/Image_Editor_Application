# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Phase 9g: Sky replacement feature
  - SkyMaskBuilder: Heuristic sky detection from RGBA pixels (blueness + brightness + top-bias scoring)
  - SkyPalette: Deterministic gradient sky generators (2-stop, 3-stop, 3-stop-with-noise variants)
  - RgbaCompositor: Per-pixel alpha blending for sky overlay composition
  - SkyReplaceService: Orchestrates mask detection, palette generation, and composition pipeline
  - SkyPreset enum: clearBlue, sunset, night, dramatic with persistence support
  - AdjustmentLayer skyReplace kind with skyPresetName field
  - SkyPickerSheet UI with preset selection and live preview
  - Comprehensive audit test suite (33 tests across 5 dimensions)

- Phase 9f: Face beautification
  - FaceReshapeService: Warp-based face sculpting via detected contours
  - Face mesh contour detection integration with ML Kit
  - Slim face and enlarge eyes anchor builders
  - AdjustmentLayer faceReshape kind with reshapeParams

- Phase 9e: Style transfer
  - Magenta two-model pipeline (predict + transfer)
  - Pre-computed style bottleneck vectors for built-in styles
  - Intensity slider blend with original

- Phase 9d: Super-resolution
  - Real-ESRGAN x4 TFLite inference
  - ESPCN 3x bundled fallback
  - Tile splitter (256px + 32px overlap) and feathered tile merger

- Phase 9c: Inpainting
  - LaMa ONNX inference via image_magic_eraser
  - Polygon selection UI
  - Resumable 208 MB model download with SHA-256 verification

- Phase 9b: Background removal
  - MediaPipe selfie segmentation (bundled)
  - U2NetP background removal
  - RMBG-1.4 int8 support (downloadable)
  - MODNet support (downloadable)
  - Guided-filter mask refinement

- Phase 9a: AI runtime foundation
  - LiteRT and ONNX runtime abstractions
  - GPU/NNAPI/CoreML/CPU delegate selection
  - Model manifest, downloader, cache, and registry
  - Resumable downloads with progress tracking

- Phase 8: Layers, masks, blend modes
  - Sealed layer hierarchy (Adjustment, Raster, Text, Sticker, Drawing, Shape)
  - ContentLayer system with layer stack management
  - Blend modes (native + shader)
  - Mask system (binary, alpha, gradient, brush, AI)

- Phase 7: Drawing, text, stickers, emoji, overlays

- Phase 6: Geometry (crop, rotate, flip, straighten, perspective)

- Phase 5: Filter presets, LUTs, effects shaders

- Phase 4: Full color adjustment feature suite

- Phase 3: Riverpod + Bloc wiring and editor scaffold

- Phase 2: GPU shader subsystem and real-time color grading
  - 24 GLSL fragment shaders
  - Shader registry and renderer
  - Color-matrix composition

- Phase 1: Engine core
  - EditPipeline and EditOperation parametric system
  - History manager with Command + Memento pattern
  - Proxy editing with memory budget management
  - Worker pool isolate architecture

- Phase 0: Project bootstrap
  - Flutter project scaffolding (iOS + Android)
  - Full dependency set
  - Directory skeleton with stub classes
  - Asset manifests

## [0.1.0] - 2026-04-11

### Added
- Initial project structure and architecture
- Blueprint-driven implementation through Phase 9g
- 250+ unit and integration tests
- 24 custom GLSL fragment shaders
- 125 Dart source files
