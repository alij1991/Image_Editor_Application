import 'package:freezed_annotation/freezed_annotation.dart';

part 'model_descriptor.freezed.dart';
part 'model_descriptor.g.dart';

/// Which inference runtime executes this model. Picked in
/// `ai/runtime/delegate_selector.dart` based on the file type and
/// device capabilities.
enum ModelRuntime {
  /// Google ML Kit — in-process, no manual loading. Used for
  /// MediaPipe Selfie Segmentation and face detection.
  @JsonValue('mlkit')
  mlkit,

  /// TFLite via `flutter_litert`'s `IsolateInterpreter`.
  @JsonValue('litert')
  litert,

  /// ONNX Runtime via `onnxruntime_v2`.
  @JsonValue('onnx')
  onnx,
}

/// Metadata for a single on-device ML model.
///
/// Entries originate from `assets/models/manifest.json` (the bundled
/// manifest), and downloaded models also get a row in the sqflite
/// cache (`ModelCache`) so we can resume interrupted downloads and
/// evict under low-disk conditions.
@freezed
class ModelDescriptor with _$ModelDescriptor {
  const ModelDescriptor._();

  @JsonSerializable(explicitToJson: true)
  const factory ModelDescriptor({
    required String id,
    required String version,
    required ModelRuntime runtime,
    required int sizeBytes,
    required String sha256,
    required bool bundled,

    /// Flutter asset path when [bundled] is true. Null for downloadable
    /// models.
    String? assetPath,

    /// Source URL when [bundled] is false. Null for bundled models.
    String? url,

    /// User-facing human-readable description of what the model does.
    @Default('') String purpose,
  }) = _ModelDescriptor;

  factory ModelDescriptor.fromJson(Map<String, dynamic> json) =>
      _$ModelDescriptorFromJson(json);

  /// Size rendered in MB with one decimal for UI chips.
  String get sizeDisplay {
    final mb = sizeBytes / (1024 * 1024);
    if (mb >= 1) return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
    final kb = sizeBytes / 1024;
    return '${kb.toStringAsFixed(0)} KB';
  }
}
