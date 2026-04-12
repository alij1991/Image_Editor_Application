# Image Editor

A professional, non-destructive mobile image editor built with Flutter. Designed for iOS and Android with GPU-accelerated real-time previews and a Rust-powered full-resolution export pipeline.

## Architecture

```
lib/
  engine/        Pipeline, history, rendering, shaders, layers, masks, color math
  ai/            ML runtimes (LiteRT, ONNX), model management, inference services
  features/      Clean Architecture per feature (editor, gallery, export, settings)
  plugins/       Discoverable plugin system (color, blur, AI, crop, draw, text, etc.)
  core/          Logging, memory, routing, theme, utilities, native bridge
  di/            Riverpod providers + Bloc registration

shaders/         GLSL fragment shaders (24 shaders for real-time preview)
native/          Rust workspace via flutter_rust_bridge (full-res export)
assets/          Models (bundled + remote), LUTs, presets, stickers, overlays
test/            Unit, widget, golden, and integration tests
```

### Key Design Decisions

- **Parametric pipeline**: Every edit is stored as parameters (not pixels). Serialized to JSON for persistence and cross-session editing.
- **Dual-path rendering**: GPU fragment shaders for 60 fps preview; Rust + SIMD for full-resolution export.
- **Color-matrix composition**: All multiplicative color ops fold into a single 5x4 matrix = one shader pass.
- **Command + Memento history**: Parametric ops use Command pattern; destructive AI ops (inpainting, super-res) use Memento with disk-spill.
- **Proxy editing**: Images decoded at screen resolution for interactive editing; full-res only at export time.

## Features

### Color & Tone
Brightness, contrast, exposure, saturation, hue, temperature, tint, highlights, shadows, whites, blacks, vibrance, clarity, dehaze, levels, gamma, tone curves (master + per-channel RGB), HSL per-channel (8 bands), split toning

### Filters & Effects
95+ filter presets, film emulation LUTs, vignette, grain, chromatic aberration, glitch, pixelate, halftone, sharpen, light leaks, dust, bokeh overlays

### Blur & Denoise
Gaussian, motion, radial, tilt-shift blur; bilateral denoise (preview), NLM denoise (export)

### Geometry
Crop, rotate (90 + free), flip H/V, straighten, perspective/keystone correction

### Creative
Drawing/brush, text overlays (Google Fonts), stickers, emoji, collage (20+ templates + freestyle)

### Layers & Masks
Adjustment layers with sub-pipelines, blend modes (native + shader), masks (binary, alpha, gradient, brush, AI segmentation)

### AI Features
| Feature | Model | Size | Strategy |
|---|---|---|---|
| Background removal | MediaPipe Selfie Segmenter | ~0.5 MB | Bundled |
| Background removal | MODNet / RMBG-1.4 | ~7-44 MB | Download on demand |
| Inpainting | LaMa (ONNX) | ~208 MB | Download on demand |
| Super-resolution | Real-ESRGAN x4 | ~17 MB | Download on demand |
| Super-resolution | ESPCN 3x (fallback) | ~0.1 MB | Bundled |
| Style transfer | Magenta (predict + transfer) | ~19 MB | Bundled (int8) |
| Face beautification | MediaPipe Face Mesh | ~2.5 MB | Bundled |
| Sky replacement | DeepLabV3-MobileNetV2 | ~2.3 MB | Bundled |
| Colorization | LAB colorizer | ~15 MB | Download on demand |

### Export
JPEG, PNG, WebP, HEIF; quality slider; resize options; EXIF preservation; AI upscale 2x/4x; gallery save; share

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.24+ (iOS & Android) |
| Language | Dart 3.4+, Rust, GLSL |
| State management | Riverpod (UI) + Bloc (history subsystem) |
| Native backend | flutter_rust_bridge 2.x + Rust (image, imageproc, rayon, SIMD) |
| ML runtimes | flutter_litert (TFLite), onnxruntime_v2 (ONNX), ML Kit |
| GPU shaders | 24 custom GLSL fragment shaders via Flutter's FragmentProgram API |
| Persistence | sqflite (projects, mementos, models, presets) |
| Serialization | freezed + json_serializable |
| Code generation | build_runner (freezed, riverpod_generator, json_serializable) |

## Performance Targets

| Metric | Target |
|---|---|
| Color pipeline (1080p) | < 5 ms/frame |
| Slider drag frame rate | 60 fps sustained |
| Impeller frame drops | < 1.5% |
| 20 MP JPEG export | < 2 seconds |
| MediaPipe selfie segmentation | 8-15 ms |
| Face mesh inference | 5-10 ms |
| Sky segmentation | 30-60 ms |

## Quick Start

See [INSTALL.md](INSTALL.md) for detailed setup instructions.

```bash
# Clone
git clone <repository-url>
cd image_editor

# Install Flutter dependencies
flutter pub get

# Run code generation
dart run build_runner build --delete-conflicting-outputs

# Run tests
flutter test

# Build
flutter build apk --debug     # Android
flutter build ios --debug      # iOS (macOS only)
```

## Project Status

Currently in active development. See [CHANGELOG.md](CHANGELOG.md) for version history.

| Phase | Status |
|---|---|
| Phase 0: Bootstrap & toolchain | Complete |
| Phase 1: Engine core (pipeline, history, memory) | Complete |
| Phase 2: GPU shader subsystem | Complete |
| Phase 3: Riverpod/Bloc wiring & editor scaffold | Complete |
| Phase 4: Full color adjustment suite | Complete |
| Phase 5: Filter presets, LUTs, effects | Complete |
| Phase 6: Geometry (crop, rotate, perspective) | Complete |
| Phase 7: Drawing, text, stickers, emoji | Complete |
| Phase 8: Layers, masks, blend modes | Complete |
| Phase 9a: AI runtime foundation | Complete |
| Phase 9b: Background removal | Complete |
| Phase 9c: Inpainting (LaMa) | Complete |
| Phase 9d: Super-resolution | Complete |
| Phase 9e: Style transfer | Complete |
| Phase 9f: Face beautification | Complete |
| Phase 9g: Sky replacement | Complete |
| Phase 9h-i: Colorization, AI masks | Planned |
| Phase 10: Rust export backend | Planned |
| Phase 11: Collage, export UI, share | Planned |
| Phase 12: Persistence, gallery, polish | Planned |

## Testing

```bash
# Run all tests
flutter test

# Run AI module tests (250+ tests)
flutter test test/ai/ test/engine/adjustment_layer_test.dart

# Run specific audit
flutter test test/ai/phase9g_comprehensive_audit_test.dart

# Static analysis
flutter analyze
```

## License

Proprietary. All rights reserved.
