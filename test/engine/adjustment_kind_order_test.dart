import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/layers/content_layer.dart';

/// IX.A.1 — `AdjustmentKind` enum order is a stable part of the
/// persisted pipeline: layer JSON stores `kind: "backgroundRemoval"`
/// as a name, and `fromName` looks the value up by that string. Any
/// reorder breaks serialisation for in-flight sessions, and removing
/// a value silently routes users who saved a pipeline with that op
/// to the fallback (`backgroundRemoval`) — a surprising mis-render
/// instead of a clear error.
///
/// Pins both the member ordinal AND the name so accidental churn
/// fails the suite. When legitimate new entries land, extend this
/// list at the END (ordinals after `styleTransfer` are free) and
/// update the expected list here.
void main() {
  test('AdjustmentKind.values has the 15 expected members in order', () {
    // Phase XVI.50 appended `aiDenoise`. Phase XVI.55 appended
    // `aiSharpen`. Phase XVI.56 appended `aiFaceRestore`.
    expect(
      AdjustmentKind.values.map((k) => k.name).toList(),
      const [
        'backgroundRemoval',
        'portraitSmooth',
        'eyeBrighten',
        'teethWhiten',
        'faceReshape',
        'skyReplace',
        'inpaint',
        'superResolution',
        'styleTransfer',
        'hairClothesRecolour',
        'composeOnBackground',
        'composeSubject',
        'aiDenoise',
        'aiSharpen',
        'aiFaceRestore',
      ],
      reason: 'Adding a new entry is fine — appending to the tail. '
          'Reordering or renaming breaks persisted pipelines.',
    );
  });

  test('every value has a human-readable label', () {
    for (final k in AdjustmentKind.values) {
      expect(k.label, isNotEmpty, reason: 'missing label for ${k.name}');
    }
  });

  test('fromName round-trips every .name', () {
    for (final k in AdjustmentKind.values) {
      expect(AdjustmentKindX.fromName(k.name), k);
    }
  });

  test('fromName falls back to backgroundRemoval on null / unknown', () {
    expect(AdjustmentKindX.fromName(null), AdjustmentKind.backgroundRemoval);
    expect(AdjustmentKindX.fromName(''), AdjustmentKind.backgroundRemoval);
    expect(AdjustmentKindX.fromName('not-a-kind'),
        AdjustmentKind.backgroundRemoval);
  });

  group('AdjustmentKindX.destructiveRaster (XVI.66c.fix)', () {
    test('the 3 XVI.66a single-button AI ops are destructive', () {
      // These produce a full-frame OPAQUE cutout — without routing
      // them as the shader source, subsequent preset / filter
      // sliders are visually no-ops because the cutout occludes
      // the shader's effect.
      expect(AdjustmentKind.aiDenoise.destructiveRaster, isTrue);
      expect(AdjustmentKind.aiSharpen.destructiveRaster, isTrue);
      expect(AdjustmentKind.aiFaceRestore.destructiveRaster, isTrue);
    });

    test('every other kind is non-destructive (overlay-on-top)', () {
      // Keeping the older opaque-output kinds (inpaint, superRes,
      // styleTransfer, etc.) on the on-top paint path is the
      // conservative scope of the XVI.66c.fix — if we ever widen
      // the marker, this test fails loudly and forces a deliberate
      // decision.
      for (final k in AdjustmentKind.values) {
        if (k == AdjustmentKind.aiDenoise ||
            k == AdjustmentKind.aiSharpen ||
            k == AdjustmentKind.aiFaceRestore) {
          continue;
        }
        expect(k.destructiveRaster, isFalse,
            reason: '${k.name} should stay on the overlay paint path '
                '(legacy behaviour); flip its flag deliberately.');
      }
    });
  });
}
