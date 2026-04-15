# Flutter Image Editor

## Build & Run
```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs  # *.freezed.dart, *.g.dart
flutter run
flutter analyze
```

## Architecture
- `lib/ai/` — ML models, runtimes (LiteRT/ORT), services (bg_removal, inpaint, style_transfer, etc.)
- `lib/engine/` — Pipeline (EditOperation → ShaderPass chain), history (BLoC), layers, presets
- `lib/features/editor/` — Editor page, session, widgets. **editor_page.dart** has all AI handlers + _AiMenu
- `lib/features/editor/presentation/notifiers/editor_session.dart` — All `apply*()` methods for AI features
- `lib/di/providers.dart` — Riverpod providers (runtimes, registry, factory)
- `shaders/*.frag` — GLSL fragment shaders for color/effects pipeline
- `assets/models/manifest.json` — Single source of truth for all ML models

## Key Patterns
- **New AI feature**: service in `ai/services/` → `AdjustmentKind` in content_layer.dart → handler in editor_page.dart → session method in editor_session.dart
- **New shader**: `.frag` file → Dart wrapper in `engine/rendering/shaders/` → add to `_passesFor()` in editor_session.dart
- **Models**: bundled (asset→temp file copy) or downloaded (OrtRuntime/LiteRtRuntime). Manifest is truth.
- **ONNX models**: use OrtRuntime, CPU-only (CoreML disabled to avoid OOM)
- **TFLite models**: use LiteRtRuntime, CoreML delegate enabled

## Conventions
- AI services follow dispose-guard pattern: check `_disposed` before AND after async inference
- Cache AI results via `_cacheCutoutImage(layerId, uiImage)` in editor_session
- Presets use `ApplyPresetEvent` for atomic multi-op commits
- All ops have `enabled` flag — before/after toggle uses `setAllOpsEnabledTransient`

## Common Issues
- CocoaPods: needs `export LANG=en_US.UTF-8` in ~/.zshrc
- Models re-download in debug: iOS assigns new container UUID each deploy
- Generated files missing: run build_runner
- Bundled TFLite: LiteRtRuntime copies asset to temp file via rootBundle.load()
