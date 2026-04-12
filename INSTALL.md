# Installation & Setup Guide

Complete setup instructions for building and running the Image Editor project.

## Prerequisites

### Required Software

| Tool | Minimum Version | Purpose |
|---|---|---|
| Flutter SDK | 3.24.0+ | Framework |
| Dart SDK | 3.4.0+ | Language (bundled with Flutter) |
| Android Studio | 2024.1+ | Android toolchain, emulator |
| Xcode | 15.0+ | iOS toolchain (macOS only) |
| Rust toolchain | 1.75+ | Native export backend |
| Git | 2.30+ | Version control |

### Platform-Specific Requirements

#### Android Development
- Android SDK (API level 21+ minimum, 34+ recommended)
- Android NDK (required for Rust cross-compilation)
- Java 17 (bundled with Android Studio)
- An Android emulator or physical device

#### iOS Development (macOS only)
- macOS 13.0+ (Ventura)
- Xcode 15.0+ with iOS 15+ SDK
- CocoaPods (`sudo gem install cocoapods`)
- An iOS simulator or physical device with developer signing

#### Rust Toolchain
- Install via [rustup](https://rustup.rs/):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```
- Add Android cross-compilation targets:
  ```bash
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
  ```
- Add iOS cross-compilation targets (macOS only):
  ```bash
  rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim
  ```

## Setup Steps

### 1. Clone the Repository

```bash
git clone <repository-url>
cd image_editor
```

### 2. Verify Flutter Installation

```bash
flutter doctor -v
```

Ensure all checkmarks pass for your target platform(s). Resolve any issues before proceeding.

### 3. Install Flutter Dependencies

```bash
flutter pub get
```

### 4. Run Code Generation

The project uses `freezed`, `json_serializable`, and `riverpod_generator` which require build_runner:

```bash
dart run build_runner build --delete-conflicting-outputs
```

To watch for changes during development:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

### 5. Set Up Rust Bridge (when native/ directory exists)

```bash
# Install the flutter_rust_bridge codegen tool
dart pub global activate flutter_rust_bridge_codegen

# Generate Dart bindings from Rust code
flutter_rust_bridge_codegen generate
```

### 6. Verify the Build

```bash
# Android
flutter build apk --debug

# iOS (macOS only)
flutter build ios --debug --no-codesign
```

### 7. Run Tests

```bash
# All tests
flutter test

# Static analysis
flutter analyze
```

## Running the App

### Android Emulator

```bash
# List available emulators
flutter emulators

# Launch an emulator
flutter emulators --launch <emulator_id>

# Run the app
flutter run
```

### iOS Simulator (macOS only)

```bash
# Open simulator
open -a Simulator

# Run the app
flutter run
```

### Physical Device

1. Enable Developer Mode on your device
2. Connect via USB
3. Verify device is detected: `flutter devices`
4. Run: `flutter run`

## AI Model Setup

### Bundled Models (ship with app)

These models are included in `assets/models/bundled/` and require no additional setup:

| Model | File | Size |
|---|---|---|
| MediaPipe Selfie Segmenter | `selfie_segmenter.tflite` | ~0.5 MB |
| Face Detection (short) | `face_detection_short.tflite` | ~0.2 MB |
| Face Mesh | `face_mesh.tflite` | ~2.5 MB |
| DeepLabV3 Sky (MobileNetV2) | `deeplabv3_sky_mobilenetv2.tflite` | ~2.3 MB |
| U2NetP | `u2netp.tflite` | ~4.7 MB |
| ESPCN 3x (SR fallback) | `espcn_3x.tflite` | ~0.1 MB |
| Magenta Style Transfer (int8) | `magenta_style_transfer_int8.tflite` | ~8 MB |

### Downloadable Models (fetched on demand)

These are downloaded at first use via the in-app model manager:

| Model | Size | Feature |
|---|---|---|
| LaMa (ONNX) | ~208 MB | Inpainting |
| MODNet | ~7 MB | Background removal |
| Real-ESRGAN x4 | ~17 MB | Super-resolution |
| Magenta Style Predict | ~11 MB | Custom style transfer |
| RMBG 1.4 (int8) | ~44 MB | Background removal |
| Colorization (SIGGRAPH) | ~15 MB | Auto-colorization |

The app shows download size and Wi-Fi status before downloading. Downloads are resumable and SHA-256 verified.

## Project Structure

```
image_editor/
  lib/                     Dart source code
    engine/                UI-free pipeline, rendering, history
    ai/                    ML runtimes, model management, inference
    features/              Per-feature Clean Architecture modules
    plugins/               Discoverable plugin system
    core/                  Cross-cutting utilities
    di/                    Dependency injection
  shaders/                 GLSL fragment shaders (24 files)
  native/                  Rust workspace (flutter_rust_bridge)
  assets/                  Models, LUTs, presets, stickers, overlays
  test/                    Unit & widget tests (250+)
  android/                 Android platform project
  ios/                     iOS platform project
```

## Environment Variables

No environment variables are required for basic development. The app runs entirely on-device.

## Troubleshooting

### Common Issues

**`flutter pub get` fails with dependency conflicts**
```bash
flutter clean
flutter pub cache repair
flutter pub get
```

**`build_runner` fails or hangs**
```bash
dart run build_runner clean
dart run build_runner build --delete-conflicting-outputs
```

**Android build fails with NDK errors (Rust)**
- Ensure `ANDROID_NDK_HOME` is set
- Verify NDK is installed via Android Studio > SDK Manager > SDK Tools

**iOS build fails with CocoaPods errors**
```bash
cd ios
pod deintegrate
pod install --repo-update
cd ..
```

**Shader compilation errors**
- Ensure Impeller is enabled (default on Flutter 3.24+)
- Check `shaders/` directory is listed in `pubspec.yaml` under `flutter: shaders:`

**Tests fail with golden file mismatches**
```bash
# Update golden files
flutter test --update-goldens
```

### Getting Help

1. Check `flutter doctor -v` for toolchain issues
2. Run `flutter analyze` for code-level diagnostics
3. Check the [Flutter docs](https://docs.flutter.dev/) for platform-specific guidance
