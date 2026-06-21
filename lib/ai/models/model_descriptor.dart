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

  /// XVI.101 — true when the descriptor can usefully appear in a
  /// picker / model-manager UI. Returns `false` for "dormant"
  /// entries: not bundled AND no URL. These exist in the manifest
  /// as placeholder slots for models we intend to ship once a
  /// working export / host URL appears (see `photo_wct2_fp16` in
  /// `assets/models/manifest.json` for an example — PhotoWCT2's TF
  /// upstream uses data-dependent SVD slicing that won't trace to
  /// ONNX cleanly, so the slot exists but has no working binary).
  /// Showing those rows just produces a "Model descriptor has no
  /// URL" dead-end when the user taps Download.
  ///
  /// XVI.120 — a downloadable (non-bundled) entry with a placeholder or
  /// empty sha256 is ALSO hidden: the downloader now refuses to fetch a
  /// model it can't verify (the post-download integrity gate is
  /// mandatory), so offering it would only ever fail. Bundled entries
  /// are unaffected — Flutter content-addresses bundled assets, so a
  /// placeholder sha there is fine (e.g. magenta / depth bundled tflite).
  bool get pickerVisible =>
      bundled ||
      (url != null &&
          url!.isNotEmpty &&
          sha256.isNotEmpty &&
          !sha256.startsWith('PLACEHOLDER'));
}
