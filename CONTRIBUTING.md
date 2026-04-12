# Contributing

Development guidelines for the Image Editor project.

## Code Standards

### Dart

- Follow [Effective Dart](https://dart.dev/effective-dart) guidelines
- Run `flutter analyze` before committing (zero warnings required)
- Use `freezed` for immutable data classes
- Use `riverpod_annotation` for providers where possible
- Use `json_serializable` for all JSON-serializable types

### Architecture Rules

1. **`engine/` must not import `package:flutter/widgets.dart`** — only `dart:ui` is allowed. This keeps the engine testable without a widget harness.
2. **`features/` uses Clean Architecture** — presentation/domain/data per feature. Shared engine types are the glue.
3. **`plugins/` are registered at startup** via `plugin_host.dart`. Each plugin is self-contained.
4. **`ai/` isolate lifecycle** is tied to the model manager. Interpreters are reused (creation is expensive).
5. **Isolates cannot use `dart:ui`** — return raw `Uint8List` + dimensions; the main isolate wraps into `ui.Image`.

### Shaders

- Uniform layout: `vec2 u_size`, `sampler2D u_texture` first, then op-specific params
- Dart wrappers must declare uniform index constants beside each shader
- Every shader must have both a preview path (GLSL) and an export path (Rust)

### Testing

- Every new feature needs unit tests
- Golden tests for shaders (perceptual-diff tolerance, platform-scoped)
- AI services need inference timing assertions
- Use `closeTo()` for floating-point comparisons

## Development Workflow

### Running Code Generation

```bash
# One-shot build
dart run build_runner build --delete-conflicting-outputs

# Watch mode (during development)
dart run build_runner watch --delete-conflicting-outputs
```

### Running Tests

```bash
# All tests
flutter test

# Specific module
flutter test test/ai/
flutter test test/engine/

# With coverage
flutter test --coverage
```

### Pre-Commit Checklist

1. `flutter analyze` — zero issues
2. `flutter test` — all tests pass
3. `flutter build apk --debug` — builds successfully
4. No secrets in committed files (.env, keys, credentials)

## Commit Messages

Use conventional commit format:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, `style`

Scopes: `engine`, `ai`, `shader`, `ui`, `plugin`, `build`, `test`

Examples:
```
feat(ai): add sky replacement pipeline with heuristic mask detection
fix(engine): correct floating-point precision in mask stats computation
test(ai): add comprehensive Phase 9g audit covering all five dimensions
docs: add installation guide and contributing guidelines
```

## File Naming Conventions

| Type | Convention | Example |
|---|---|---|
| Dart source | `snake_case.dart` | `sky_replace_service.dart` |
| Test files | `*_test.dart` | `sky_mask_builder_test.dart` |
| Shaders | `snake_case.frag` / `.glsl` | `color_grading.frag` |
| Assets | `snake_case` | `kodak_portra_400.png` |

## Performance Guidelines

- Slider interactions must stay at 60 fps (< 16 ms main thread, < 5 ms raster)
- Color pipeline: < 5 ms/frame on 1080p proxy
- Never allocate `ui.Image` without going through `ui_image_disposer.dart`
- Use `TransferableTypedData` for cross-isolate image transfers
- Proxy images at screen resolution; full-res only at export
