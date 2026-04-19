import '../layers/content_layer.dart';
import 'edit_op_type.dart';
import 'edit_operation.dart';
import 'edit_pipeline.dart';
import 'geometry_state.dart';
import 'op_spec.dart';
import 'tone_curve_set.dart';

/// Convenience readers for extracting parameter values from an
/// [EditPipeline] without writing repeated `firstWhere` boilerplate in
/// every widget that needs to display a slider's current value.
///
/// Each reader returns the op's "identity" value when the op is absent or
/// disabled:
///   - 0.0 for most adjustments (brightness, contrast, ...)
///   - 1.0 for gamma and whites
///   - neutral (0.5, 0.5, 0.5) for split toning colors
extension PipelineReaders on EditPipeline {
  // --- Light ---
  double get brightnessValue => _enabledDouble(EditOpType.brightness, 'value');
  double get contrastValue => _enabledDouble(EditOpType.contrast, 'value');
  double get exposureValue => _enabledDouble(EditOpType.exposure, 'value');
  double get highlightsValue => _enabledDouble(EditOpType.highlights, 'value');
  double get shadowsValue => _enabledDouble(EditOpType.shadows, 'value');
  double get whitesValue => _enabledDouble(EditOpType.whites, 'value');
  double get blacksValue => _enabledDouble(EditOpType.blacks, 'value');

  // --- Color ---
  double get temperatureValue =>
      _enabledDouble(EditOpType.temperature, 'value');
  double get tintValue => _enabledDouble(EditOpType.tint, 'value');
  double get saturationValue =>
      _enabledDouble(EditOpType.saturation, 'value');
  double get vibranceValue => _enabledDouble(EditOpType.vibrance, 'value');
  double get hueValue => _enabledDouble(EditOpType.hue, 'value');

  // --- Effects / Detail ---
  double get clarityValue => _enabledDouble(EditOpType.clarity, 'value');
  double get dehazeValue => _enabledDouble(EditOpType.dehaze, 'value');

  // --- Levels ---
  double get levelsBlack =>
      _enabledDouble(EditOpType.levels, 'black', 0.0);
  double get levelsWhite =>
      _enabledDouble(EditOpType.levels, 'white', 1.0);
  double get levelsGamma =>
      _enabledDouble(EditOpType.gamma, 'value', 1.0);

  // --- Tone curve ---
  /// Strength of the simplified s-curve adjustment ([-1,1]).
  double get toneCurveStrength =>
      _enabledDouble(EditOpType.toneCurve, 'sStrength');

  /// All four tone curves authored against the first enabled
  /// toneCurve op. Returns null when no op exists or every channel is
  /// at the identity diagonal — callers should treat that as "no LUT
  /// needed". Per-channel keys are nullable independently so the
  /// session can skip baking rows that didn't change.
  ToneCurveSet? get toneCurves {
    for (final op in operations) {
      if (!op.enabled || op.type != EditOpType.toneCurve) continue;
      final master = _parseChannelPoints(op.parameters['points']);
      final red = _parseChannelPoints(op.parameters['red']);
      final green = _parseChannelPoints(op.parameters['green']);
      final blue = _parseChannelPoints(op.parameters['blue']);
      if (master == null && red == null && green == null && blue == null) {
        return null;
      }
      return ToneCurveSet(master: master, red: red, green: green, blue: blue);
    }
    return null;
  }

  /// Master tone curve control points — a thin wrapper over
  /// [toneCurves] retained because widgets (and tests) read this
  /// directly. Returns null when the master channel is identity even
  /// if R/G/B carry custom shapes.
  List<List<double>>? get toneCurvePoints => toneCurves?.master;

  // --- Split toning ---
  double get splitBalance =>
      _enabledDouble(EditOpType.splitToning, 'balance');
  List<double> get splitHighlightColor =>
      _enabledList(EditOpType.splitToning, 'hiColor', const [0.5, 0.5, 0.5]);
  List<double> get splitShadowColor =>
      _enabledList(EditOpType.splitToning, 'loColor', const [0.5, 0.5, 0.5]);

  // --- HSL ---
  List<double> get hslHueDelta =>
      _enabledList(EditOpType.hsl, 'hue', _zeros8);
  List<double> get hslSatDelta =>
      _enabledList(EditOpType.hsl, 'sat', _zeros8);
  List<double> get hslLumDelta =>
      _enabledList(EditOpType.hsl, 'lum', _zeros8);

  // --- Internal helpers ---

  /// Parse a single channel's points list out of the toneCurve op
  /// parameters. Returns null when the value is missing, malformed,
  /// has fewer than two valid points, or traces the identity diagonal
  /// (so the caller can skip the bake for that row).
  List<List<double>>? _parseChannelPoints(Object? raw) {
    if (raw is! List) return null;
    final out = <List<double>>[];
    for (final pair in raw) {
      if (pair is! List || pair.length < 2) continue;
      final x = pair[0];
      final y = pair[1];
      if (x is! num || y is! num) continue;
      out.add([x.toDouble(), y.toDouble()]);
    }
    if (out.length < 2) return null;
    final isIdentity = out.every((p) => (p[1] - p[0]).abs() < 1e-4);
    if (isIdentity) return null;
    return out;
  }

  double _enabledDouble(
    String type,
    String key, [
    double fallback = 0.0,
  ]) {
    for (final op in operations) {
      if (op.type == type && op.enabled) {
        return op.doubleParam(key, fallback);
      }
    }
    return fallback;
  }

  List<double> _enabledList(
    String type,
    String key,
    List<double> fallback,
  ) {
    for (final op in operations) {
      if (op.type == type && op.enabled) {
        final raw = op.parameters[key];
        if (raw is List) {
          return raw
              .whereType<num>()
              .map((e) => e.toDouble())
              .toList(growable: false);
        }
      }
    }
    return fallback;
  }

  /// True if the op of [type] is present and enabled.
  bool hasEnabledOp(String type) {
    for (final op in operations) {
      if (op.type == type && op.enabled) return true;
    }
    return false;
  }

  /// Find the first enabled op of the given [type], or null.
  EditOperation? findOp(String type) {
    for (final op in operations) {
      if (op.type == type && op.enabled) return op;
    }
    return null;
  }

  /// Generic scalar reader: returns the named parameter from the first
  /// enabled op of [type], or [fallback] if absent. Used by widgets that
  /// need to display the current value of a sub-parameter (e.g. vignette
  /// feather, denoise sigma).
  double readParam(String type, String key, [double fallback = 0.0]) {
    final op = findOp(type);
    if (op == null) return fallback;
    return op.doubleParam(key, fallback);
  }

  /// Typed [ContentLayer] list derived from the layer.* ops in the
  /// pipeline, in insertion order. Disabled ops still appear (their
  /// `visible` flag is false) so the layer stack panel can show them
  /// as hidden rather than missing.
  List<ContentLayer> get contentLayers {
    final list = <ContentLayer>[];
    for (final op in operations) {
      final layer = contentLayerFromOp(op);
      if (layer != null) list.add(layer);
    }
    return List.unmodifiable(list);
  }

  /// Current [GeometryState] derived from the enabled rotate / flip /
  /// straighten / crop ops in the pipeline. Used by the canvas to
  /// transform the image before the color shader chain runs.
  GeometryState get geometryState {
    int steps = 0;
    double straighten = 0;
    bool flipH = false;
    bool flipV = false;
    double? cropAspect;
    CropRect? cropRect;
    for (final op in operations) {
      if (!op.enabled) continue;
      switch (op.type) {
        case EditOpType.rotate:
          steps = op.intParam('steps');
          break;
        case EditOpType.straighten:
          straighten = op.doubleParam('value');
          break;
        case EditOpType.flip:
          flipH = op.boolParam('h');
          flipV = op.boolParam('v');
          break;
        case EditOpType.crop:
          final raw = op.parameters['aspectRatio'];
          if (raw is num) cropAspect = raw.toDouble();
          // The crop op may carry a normalized rect alongside (or
          // instead of) the aspect ratio. Aspect-only ops are still
          // valid — the canvas just shows full image until the user
          // confirms a rect from the overlay.
          final parsed = CropRect.fromParams(op.parameters);
          if (parsed != null) cropRect = parsed;
          break;
      }
    }
    return GeometryState(
      rotationSteps: steps,
      straightenDegrees: straighten,
      flipH: flipH,
      flipV: flipV,
      cropAspectRatio: cropAspect,
      cropRect: cropRect,
    );
  }

  /// The set of [OpCategory]s that currently contain at least one
  /// enabled op whose value differs from identity. Used by the tool
  /// dock's category tabs to show an "edit dot" indicator.
  Set<OpCategory> get activeCategories {
    final result = <OpCategory>{};
    for (final op in operations) {
      if (!op.enabled) continue;
      // Geometry ops don't appear in OpSpecs (flip/rotate are not
      // scalars) — mark the category active if the op exists.
      if (op.type == EditOpType.rotate ||
          op.type == EditOpType.flip ||
          op.type == EditOpType.crop) {
        result.add(OpCategory.geometry);
        continue;
      }
      // For everything else, consult the registry and check identity.
      for (final spec in OpSpecs.all) {
        if (spec.type != op.type) continue;
        final raw = op.parameters[spec.paramKey];
        final value = raw is num ? raw.toDouble() : spec.identity;
        if (!spec.isIdentity(value)) {
          result.add(spec.category);
          break;
        }
      }
    }
    return result;
  }
}

const List<double> _zeros8 = [0, 0, 0, 0, 0, 0, 0, 0];
