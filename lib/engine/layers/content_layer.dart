import 'dart:ui' as ui;

import '../pipeline/edit_op_type.dart';
import '../pipeline/edit_operation.dart';
import 'layer_blend_mode.dart';
import 'layer_mask.dart';

/// A content layer that sits ABOVE the color shader chain — text,
/// stickers, drawings, or overlays the user has placed on the image.
///
/// Content layers are stored in the [EditPipeline] as [EditOperation]s
/// with one of the `layer.*` op types. Parsing them into typed classes
/// happens in [PipelineReaders.contentLayers].
///
/// Each layer type shares a common transform block:
/// - [id]      — stable identifier (matches the underlying op id)
/// - [visible] — hidden layers are skipped by the painter
/// - [opacity] — 0..1 blend factor against the background
/// - [x] / [y] — normalized position (0..1) within the canvas rect
/// - [rotation] — radians around the layer's center
/// - [scale]   — 1.0 = native size, >1 larger, <1 smaller
sealed class ContentLayer {
  const ContentLayer({
    required this.id,
    this.visible = true,
    this.opacity = 1.0,
    this.x = 0.5,
    this.y = 0.5,
    this.rotation = 0.0,
    this.scale = 1.0,
    this.blendMode = LayerBlendMode.normal,
    this.mask = LayerMask.none,
  });

  final String id;
  final bool visible;
  final double opacity;
  final double x;
  final double y;
  final double rotation;
  final double scale;

  /// How this layer composites with the pixels beneath it. Default
  /// [LayerBlendMode.normal] means alpha-over (Flutter's srcOver).
  final LayerBlendMode blendMode;

  /// Procedural mask that restricts where the layer is visible.
  /// Default [LayerMask.none] = full coverage.
  final LayerMask mask;

  /// User-facing short label for the layer stack panel.
  String get displayLabel;

  /// One of the [LayerKind] values — matches the op type prefix.
  LayerKind get kind;

  /// Serialize the layer to the parameters map of an [EditOperation].
  Map<String, dynamic> toParams();

  /// Common transform/blend/mask fields that every [ContentLayer]
  /// subtype serializes. Subclass-specific fields go alongside.
  Map<String, dynamic> commonParams() => {
        'visible': visible,
        'opacity': opacity,
        'x': x,
        'y': y,
        'rotation': rotation,
        'scale': scale,
        if (blendMode != LayerBlendMode.normal) 'blendMode': blendMode.name,
        if (!mask.isIdentity) 'mask': mask.toJson(),
      };
}

enum LayerKind { text, sticker, drawing, adjustment }

/// Horizontal alignment for multi-line [TextLayer] content.
enum TextAlignment { left, center, right }

/// Drop-shadow styling for a [TextLayer]. Disabled = no shadow.
/// `null` color means "auto" — the renderer picks black at 60%
/// alpha so the shadow contrasts with light text on a dark image
/// without the user picking a color.
class TextShadow {
  const TextShadow({
    this.enabled = false,
    this.colorArgb,
    this.dx = 2,
    this.dy = 2,
    this.blur = 4,
  });

  final bool enabled;
  final int? colorArgb;
  final double dx;
  final double dy;
  final double blur;

  TextShadow copyWith({
    bool? enabled,
    Object? colorArgb = _sentinel,
    double? dx,
    double? dy,
    double? blur,
  }) =>
      TextShadow(
        enabled: enabled ?? this.enabled,
        colorArgb: identical(colorArgb, _sentinel)
            ? this.colorArgb
            : colorArgb as int?,
        dx: dx ?? this.dx,
        dy: dy ?? this.dy,
        blur: blur ?? this.blur,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        if (colorArgb != null) 'color': colorArgb,
        'dx': dx,
        'dy': dy,
        'blur': blur,
      };

  static TextShadow fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TextShadow();
    return TextShadow(
      enabled: (json['enabled'] as bool?) ?? false,
      colorArgb: (json['color'] as num?)?.toInt(),
      dx: (json['dx'] as num?)?.toDouble() ?? 2,
      dy: (json['dy'] as num?)?.toDouble() ?? 2,
      blur: (json['blur'] as num?)?.toDouble() ?? 4,
    );
  }

  /// Default shadow used when [enabled] is true but [colorArgb] is
  /// null — black at 60% alpha. Reads well over typical photos
  /// without forcing the user into a color picker for the common
  /// case.
  static const int kAutoColorArgb = 0x99000000;
}

class TextLayer extends ContentLayer {
  const TextLayer({
    required super.id,
    required this.text,
    required this.fontSize,
    required this.colorArgb,
    this.fontFamily,
    this.bold = false,
    this.italic = false,
    this.alignment = TextAlignment.center,
    this.shadow = const TextShadow(),
    super.visible,
    super.opacity,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.blendMode,
    super.mask,
  });

  final String text;
  final double fontSize;
  final int colorArgb;
  final String? fontFamily;
  final bool bold;
  final bool italic;
  final TextAlignment alignment;
  final TextShadow shadow;

  @override
  String get displayLabel =>
      text.length > 18 ? '${text.substring(0, 18)}…' : text;

  @override
  LayerKind get kind => LayerKind.text;

  TextLayer copyWith({
    String? text,
    double? fontSize,
    int? colorArgb,
    Object? fontFamily = _sentinel,
    bool? bold,
    bool? italic,
    TextAlignment? alignment,
    TextShadow? shadow,
    bool? visible,
    double? opacity,
    double? x,
    double? y,
    double? rotation,
    double? scale,
    LayerBlendMode? blendMode,
    LayerMask? mask,
  }) {
    return TextLayer(
      id: id,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      colorArgb: colorArgb ?? this.colorArgb,
      fontFamily: identical(fontFamily, _sentinel)
          ? this.fontFamily
          : fontFamily as String?,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      alignment: alignment ?? this.alignment,
      shadow: shadow ?? this.shadow,
      visible: visible ?? this.visible,
      opacity: opacity ?? this.opacity,
      x: x ?? this.x,
      y: y ?? this.y,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      blendMode: blendMode ?? this.blendMode,
      mask: mask ?? this.mask,
    );
  }

  @override
  Map<String, dynamic> toParams() => {
        'text': text,
        'fontSize': fontSize,
        'colorArgb': colorArgb,
        if (fontFamily != null) 'fontFamily': fontFamily,
        'bold': bold,
        'italic': italic,
        if (alignment != TextAlignment.center) 'align': alignment.name,
        if (shadow.enabled) 'shadow': shadow.toJson(),
        ...commonParams(),
      };

  static TextLayer fromOp(EditOperation op) {
    final p = op.parameters;
    final alignName = p['align'] as String?;
    final align = TextAlignment.values.firstWhere(
      (a) => a.name == alignName,
      orElse: () => TextAlignment.center,
    );
    return TextLayer(
      id: op.id,
      text: (p['text'] as String?) ?? '',
      fontSize: (p['fontSize'] as num?)?.toDouble() ?? 48.0,
      colorArgb: (p['colorArgb'] as num?)?.toInt() ?? 0xFFFFFFFF,
      fontFamily: p['fontFamily'] as String?,
      bold: (p['bold'] as bool?) ?? false,
      italic: (p['italic'] as bool?) ?? false,
      alignment: align,
      shadow:
          TextShadow.fromJson(p['shadow'] as Map<String, dynamic>?),
      visible: op.enabled && ((p['visible'] as bool?) ?? true),
      opacity: (p['opacity'] as num?)?.toDouble() ?? 1.0,
      x: (p['x'] as num?)?.toDouble() ?? 0.5,
      y: (p['y'] as num?)?.toDouble() ?? 0.5,
      rotation: (p['rotation'] as num?)?.toDouble() ?? 0.0,
      scale: (p['scale'] as num?)?.toDouble() ?? 1.0,
      blendMode: LayerBlendModeX.fromName(p['blendMode'] as String?),
      mask: LayerMask.fromJson(p['mask'] as Map<String, dynamic>?),
    );
  }
}

class StickerLayer extends ContentLayer {
  const StickerLayer({
    required super.id,
    required this.character,
    required this.fontSize,
    super.visible,
    super.opacity,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.blendMode,
    super.mask,
  });

  final String character;
  final double fontSize;

  @override
  String get displayLabel => 'Sticker $character';

  @override
  LayerKind get kind => LayerKind.sticker;

  StickerLayer copyWith({
    String? character,
    double? fontSize,
    bool? visible,
    double? opacity,
    double? x,
    double? y,
    double? rotation,
    double? scale,
    LayerBlendMode? blendMode,
    LayerMask? mask,
  }) {
    return StickerLayer(
      id: id,
      character: character ?? this.character,
      fontSize: fontSize ?? this.fontSize,
      visible: visible ?? this.visible,
      opacity: opacity ?? this.opacity,
      x: x ?? this.x,
      y: y ?? this.y,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      blendMode: blendMode ?? this.blendMode,
      mask: mask ?? this.mask,
    );
  }

  @override
  Map<String, dynamic> toParams() => {
        'character': character,
        'fontSize': fontSize,
        ...commonParams(),
      };

  static StickerLayer fromOp(EditOperation op) {
    final p = op.parameters;
    return StickerLayer(
      id: op.id,
      character: (p['character'] as String?) ?? '★',
      fontSize: (p['fontSize'] as num?)?.toDouble() ?? 80.0,
      visible: op.enabled && ((p['visible'] as bool?) ?? true),
      opacity: (p['opacity'] as num?)?.toDouble() ?? 1.0,
      x: (p['x'] as num?)?.toDouble() ?? 0.5,
      y: (p['y'] as num?)?.toDouble() ?? 0.5,
      rotation: (p['rotation'] as num?)?.toDouble() ?? 0.0,
      scale: (p['scale'] as num?)?.toDouble() ?? 1.0,
      blendMode: LayerBlendModeX.fromName(p['blendMode'] as String?),
      mask: LayerMask.fromJson(p['mask'] as Map<String, dynamic>?),
    );
  }
}

/// One of the brush flavours the draw-mode overlay exposes. Each
/// kind chooses a different stroke render shape (pen = solid line,
/// marker = wider semi-transparent line, spray = scattered dots
/// along the path).
enum DrawingBrushType {
  pen,
  marker,
  spray,
}

/// A single paint stroke within a [DrawingLayer].
class DrawingStroke {
  const DrawingStroke({
    required this.points,
    required this.colorArgb,
    required this.width,
    this.opacity = 1.0,
    this.hardness = 1.0,
    this.brushType = DrawingBrushType.pen,
  });

  /// Normalized (0..1) point sequence inside the layer's canvas rect.
  final List<StrokePoint> points;
  final int colorArgb;
  final double width;

  /// Stroke opacity in [0..1]. Multiplies the colour's alpha at
  /// paint time so even a fully opaque colour can be laid down
  /// translucently for layered effects.
  final double opacity;

  /// Edge hardness in [0..1]. 1.0 = the historical sharp stroke;
  /// values below 1 widen the soft falloff. The renderer turns
  /// `(1 - hardness)` into a MaskFilter blur radius proportional
  /// to the stroke width — fast and looks reasonable across
  /// brush sizes.
  final double hardness;

  final DrawingBrushType brushType;

  Map<String, dynamic> toJson() => {
        'color': colorArgb,
        'width': width,
        if (opacity != 1.0) 'opacity': opacity,
        if (hardness != 1.0) 'hardness': hardness,
        if (brushType != DrawingBrushType.pen) 'brush': brushType.name,
        'pts': [
          for (final p in points) [p.x, p.y],
        ],
      };

  static DrawingStroke fromJson(Map<String, dynamic> json) {
    final rawPts = (json['pts'] as List?) ?? const [];
    final points = <StrokePoint>[];
    for (final raw in rawPts) {
      if (raw is List && raw.length >= 2) {
        final x = (raw[0] as num).toDouble();
        final y = (raw[1] as num).toDouble();
        points.add(StrokePoint(x, y));
      }
    }
    final brushName = json['brush'] as String?;
    final brush = DrawingBrushType.values.firstWhere(
      (b) => b.name == brushName,
      orElse: () => DrawingBrushType.pen,
    );
    return DrawingStroke(
      points: points,
      colorArgb: (json['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
      width: (json['width'] as num?)?.toDouble() ?? 4.0,
      opacity:
          ((json['opacity'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
      hardness:
          ((json['hardness'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
      brushType: brush,
    );
  }
}

class StrokePoint {
  const StrokePoint(this.x, this.y);
  final double x;
  final double y;
}

class DrawingLayer extends ContentLayer {
  const DrawingLayer({
    required super.id,
    required this.strokes,
    super.visible,
    super.opacity,
    super.blendMode,
    super.mask,
  }) : super(x: 0.5, y: 0.5, rotation: 0, scale: 1);

  /// Completed strokes in paint order.
  final List<DrawingStroke> strokes;

  @override
  String get displayLabel =>
      'Drawing (${strokes.length} stroke${strokes.length == 1 ? '' : 's'})';

  @override
  LayerKind get kind => LayerKind.drawing;

  DrawingLayer copyWith({
    List<DrawingStroke>? strokes,
    bool? visible,
    double? opacity,
    LayerBlendMode? blendMode,
    LayerMask? mask,
  }) {
    return DrawingLayer(
      id: id,
      strokes: strokes ?? this.strokes,
      visible: visible ?? this.visible,
      opacity: opacity ?? this.opacity,
      blendMode: blendMode ?? this.blendMode,
      mask: mask ?? this.mask,
    );
  }

  @override
  Map<String, dynamic> toParams() => {
        'strokes': [for (final s in strokes) s.toJson()],
        ...commonParams(),
      };

  static DrawingLayer fromOp(EditOperation op) {
    final rawStrokes = (op.parameters['strokes'] as List?) ?? const [];
    final strokes = <DrawingStroke>[];
    for (final raw in rawStrokes) {
      if (raw is Map<String, dynamic>) {
        strokes.add(DrawingStroke.fromJson(raw));
      }
    }
    return DrawingLayer(
      id: op.id,
      strokes: strokes,
      visible: op.enabled &&
          ((op.parameters['visible'] as bool?) ?? true),
      opacity: (op.parameters['opacity'] as num?)?.toDouble() ?? 1.0,
      blendMode:
          LayerBlendModeX.fromName(op.parameters['blendMode'] as String?),
      mask:
          LayerMask.fromJson(op.parameters['mask'] as Map<String, dynamic>?),
    );
  }
}

/// Maps [ContentLayer.kind] to the op type identifier.
String opTypeForLayerKind(LayerKind kind) {
  switch (kind) {
    case LayerKind.text:
      return EditOpType.text;
    case LayerKind.sticker:
      return EditOpType.sticker;
    case LayerKind.drawing:
      return EditOpType.drawing;
    case LayerKind.adjustment:
      return EditOpType.adjustmentLayer;
  }
}

/// Parse an [EditOperation] into a typed [ContentLayer] if it's a
/// layer op, otherwise null.
ContentLayer? contentLayerFromOp(EditOperation op) {
  switch (op.type) {
    case EditOpType.text:
      return TextLayer.fromOp(op);
    case EditOpType.sticker:
      return StickerLayer.fromOp(op);
    case EditOpType.drawing:
      return DrawingLayer.fromOp(op);
    case EditOpType.adjustmentLayer:
      return AdjustmentLayer.fromOp(op);
  }
  return null;
}

/// A layer whose visible region is defined by an AI-generated raster
/// mask (Phase 9b: background removal). Future phases extend this
/// with a sub-pipeline of color adjustments applied through the same
/// mask (full "adjustment layer" semantics).
///
/// The [cutoutImage] is a volatile in-memory field — it's NOT
/// serialized to the pipeline JSON. The editor session holds the
/// actual pixels via a `Map<layerId, ui.Image>` cache and fills
/// [cutoutImage] in during `rebuildPreview`. On session reload, the
/// cutout is lost (Phase 12 adds MementoStore persistence).
///
/// For now, only one `kind` of adjustment is supported:
///   [AdjustmentKind.backgroundRemoval] — paints the cutoutImage on
///   top of the canvas, replacing the background with transparency.
class AdjustmentLayer extends ContentLayer {
  const AdjustmentLayer({
    required super.id,
    required this.adjustmentKind,
    this.cutoutImage,
    this.reshapeParams,
    this.skyPresetName,
    super.visible,
    super.opacity,
    super.blendMode,
    super.mask,
  }) : super(x: 0.5, y: 0.5, rotation: 0, scale: 1);

  /// Which kind of adjustment this layer represents. Phase 9b ships
  /// only [AdjustmentKind.backgroundRemoval]; future phases add
  /// selective color adjustments (brightness through mask, etc.).
  final AdjustmentKind adjustmentKind;

  /// Volatile in-memory cutout bitmap. Null when the session has no
  /// cached pixels (e.g. session reloaded from persisted pipeline in
  /// a future phase). Painters must handle null by skipping the
  /// layer.
  final ui.Image? cutoutImage;

  /// Parameters for [AdjustmentKind.faceReshape] — only read when
  /// `adjustmentKind == faceReshape`. Keyed by a small string
  /// namespace (`slim`, `eyes`, etc.) so future strengths can be
  /// added without breaking the schema. Persisted to the pipeline
  /// JSON so reload + Rust export can re-run the warp at full
  /// resolution. Null for every other kind.
  final Map<String, double>? reshapeParams;

  /// The name of the sky preset used for
  /// [AdjustmentKind.skyReplace]. Stored as a plain `String` rather
  /// than a typed enum so the engine layer stays independent of
  /// the `ai/` package — the session + service resolve the name
  /// back to a [SkyPreset] when applying. Null for every other
  /// kind.
  final String? skyPresetName;

  @override
  String get displayLabel {
    switch (adjustmentKind) {
      case AdjustmentKind.backgroundRemoval:
        return 'Background removed';
      case AdjustmentKind.portraitSmooth:
        return 'Portrait smoothed';
      case AdjustmentKind.eyeBrighten:
        return 'Eyes brightened';
      case AdjustmentKind.teethWhiten:
        return 'Teeth whitened';
      case AdjustmentKind.faceReshape:
        return 'Face sculpted';
      case AdjustmentKind.skyReplace:
        return 'Sky replaced';
      case AdjustmentKind.inpaint:
        return 'Object removed';
      case AdjustmentKind.superResolution:
        return 'Enhanced (4×)';
      case AdjustmentKind.styleTransfer:
        return 'Style applied';
      case AdjustmentKind.hairClothesRecolour:
        return 'Recoloured';
      case AdjustmentKind.composeOnBackground:
        return 'Recomposed';
    }
  }

  @override
  LayerKind get kind => LayerKind.adjustment;

  AdjustmentLayer copyWith({
    AdjustmentKind? adjustmentKind,
    Object? cutoutImage = _sentinel,
    Object? reshapeParams = _sentinel,
    Object? skyPresetName = _sentinel,
    bool? visible,
    double? opacity,
    LayerBlendMode? blendMode,
    LayerMask? mask,
  }) {
    return AdjustmentLayer(
      id: id,
      adjustmentKind: adjustmentKind ?? this.adjustmentKind,
      cutoutImage: identical(cutoutImage, _sentinel)
          ? this.cutoutImage
          : cutoutImage as ui.Image?,
      reshapeParams: identical(reshapeParams, _sentinel)
          ? this.reshapeParams
          : reshapeParams as Map<String, double>?,
      skyPresetName: identical(skyPresetName, _sentinel)
          ? this.skyPresetName
          : skyPresetName as String?,
      visible: visible ?? this.visible,
      opacity: opacity ?? this.opacity,
      blendMode: blendMode ?? this.blendMode,
      mask: mask ?? this.mask,
    );
  }

  @override
  Map<String, dynamic> toParams() => {
        'adjustmentKind': adjustmentKind.name,
        if (reshapeParams != null) 'reshapeParams': reshapeParams,
        if (skyPresetName != null) 'skyPresetName': skyPresetName,
        ...commonParams(),
      };

  static AdjustmentLayer fromOp(EditOperation op) {
    final p = op.parameters;
    Map<String, double>? reshape;
    final rawReshape = p['reshapeParams'];
    if (rawReshape is Map) {
      reshape = <String, double>{};
      for (final entry in rawReshape.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is num) {
          reshape[key] = value.toDouble();
        }
      }
      if (reshape.isEmpty) reshape = null;
    }
    final rawSky = p['skyPresetName'];
    final skyName = rawSky is String && rawSky.isNotEmpty ? rawSky : null;
    return AdjustmentLayer(
      id: op.id,
      adjustmentKind:
          AdjustmentKindX.fromName(p['adjustmentKind'] as String?),
      reshapeParams: reshape,
      skyPresetName: skyName,
      visible: op.enabled && ((p['visible'] as bool?) ?? true),
      opacity: (p['opacity'] as num?)?.toDouble() ?? 1.0,
      blendMode:
          LayerBlendModeX.fromName(p['blendMode'] as String?),
      mask: LayerMask.fromJson(p['mask'] as Map<String, dynamic>?),
    );
  }
}

/// What kind of effect an [AdjustmentLayer] produces.
///
/// Order matters for persisted-pipeline analytics so new values
/// are always appended to the end of the enum, never inserted in
/// the middle. Test `AdjustmentKind enum has the expected values
/// in order` locks the expected sequence.
enum AdjustmentKind {
  /// Subject cutout — replaces background with transparency.
  backgroundRemoval,

  /// Portrait skin-smoothing — detects faces, builds a feathered
  /// face-region mask, and blends a blurred copy of the source
  /// inside that mask while preserving eyes and mouth areas.
  portraitSmooth,

  /// Brightens the eye area inside soft circles at the detected
  /// left/right eye landmarks.
  eyeBrighten,

  /// Whitens the mouth/teeth area by desaturating + brightening
  /// inside a soft circle centered on the mouth landmarks.
  teethWhiten,

  /// Sculpts the face via contour-driven image warp — slim face +
  /// enlarge eyes. Result is a full-frame reshaped image rather
  /// than a mask-confined op, so [reshapeParams] on the layer
  /// records the strengths used (for future re-application on
  /// reload + Rust export).
  faceReshape,

  /// Replaces the sky region with a procedurally-generated
  /// gradient matching a user-selected preset. [skyPresetName]
  /// on the layer records which preset was picked so reload +
  /// export can reproduce the effect.
  skyReplace,

  /// LaMa object removal — user paints a mask over unwanted
  /// areas and the model fills them in with plausible content.
  inpaint,

  /// 4× super-resolution via Real-ESRGAN — enhances detail and
  /// upscales the image.
  superResolution,

  /// Magenta arbitrary-style transfer — applies an artistic
  /// style (Monet, Starry Night, etc.) to the image.
  styleTransfer,

  /// Phase XV.2 — recolour hair / clothes / accessories via
  /// MediaPipe selfie-multiclass segmentation + LAB a*b* shift. The
  /// layer stores the chosen class index (0..5) and target sRGB
  /// colour so reload / export can reproduce the effect.
  hairClothesRecolour,

  /// Phase XV.3 — subject extracted via bg-removal strategy, colour-
  /// transferred (Reinhard LAB) to match a user-picked new
  /// background, and alpha-composited. The stored raster is the
  /// finished composite.
  composeOnBackground,
}

extension AdjustmentKindX on AdjustmentKind {
  String get label {
    switch (this) {
      case AdjustmentKind.backgroundRemoval:
        return 'Background removal';
      case AdjustmentKind.portraitSmooth:
        return 'Portrait smooth';
      case AdjustmentKind.eyeBrighten:
        return 'Eye brighten';
      case AdjustmentKind.teethWhiten:
        return 'Teeth whiten';
      case AdjustmentKind.faceReshape:
        return 'Face reshape';
      case AdjustmentKind.skyReplace:
        return 'Sky replace';
      case AdjustmentKind.inpaint:
        return 'Object removal';
      case AdjustmentKind.superResolution:
        return 'Enhance (4×)';
      case AdjustmentKind.styleTransfer:
        return 'Style transfer';
      case AdjustmentKind.hairClothesRecolour:
        return 'Recolour';
      case AdjustmentKind.composeOnBackground:
        return 'Compose on background';
    }
  }

  static AdjustmentKind fromName(String? name) {
    if (name == null) return AdjustmentKind.backgroundRemoval;
    for (final k in AdjustmentKind.values) {
      if (k.name == name) return k;
    }
    return AdjustmentKind.backgroundRemoval;
  }
}

const Object _sentinel = Object();
