import 'package:freezed_annotation/freezed_annotation.dart';

part 'mask_data.freezed.dart';
part 'mask_data.g.dart';

/// Describes a mask attached to an [EditOperation] so the op only applies
/// inside (or outside) a region of the image.
///
/// The actual mask pixels are stored out-of-band:
/// - [MaskKind.fullImage] has no pixels; the op applies everywhere.
/// - [MaskKind.radialGradient] and [MaskKind.linearGradient] are procedural
///   — the gradient parameters live in [parameters].
/// - [MaskKind.brush] and [MaskKind.ai] point at a [maskAssetId] that
///   the [MaskTexture] cache resolves to a [ui.Image].
@freezed
class MaskData with _$MaskData {
  const factory MaskData({
    required MaskKind kind,
    @Default(false) bool inverted,
    @Default(0.0) double feather,
    @Default({}) Map<String, dynamic> parameters,
    String? maskAssetId,
  }) = _MaskData;

  factory MaskData.fromJson(Map<String, dynamic> json) =>
      _$MaskDataFromJson(json);
}

enum MaskKind {
  fullImage,
  radialGradient,
  linearGradient,
  brush,
  ai,
}
