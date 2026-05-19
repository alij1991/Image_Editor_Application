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

  group('AdjustmentKindX.destructiveRaster', () {
    const destructive = <AdjustmentKind>{
      // XVI.66a single-button AI ops — all emit opaque cutouts.
      AdjustmentKind.aiDenoise,
      AdjustmentKind.aiSharpen,
      AdjustmentKind.aiFaceRestore,
      // Remove-object follow-up — LaMa + MI-GAN both composite
      // an inpainted region INTO a full-frame opaque output.
      AdjustmentKind.inpaint,
      // Both share the "full-frame opaque replacement" shape:
      AdjustmentKind.superResolution,
      AdjustmentKind.styleTransfer,
    };

    test('each known destructive kind is flagged', () {
      for (final k in destructive) {
        expect(k.destructiveRaster, isTrue,
            reason: '${k.name} produces a full-frame opaque cutout '
                'and must feed the shader chain as source — adding to '
                'destructive must NOT regress.');
      }
    });

    test('every other kind stays on the overlay paint path', () {
      // Pins the legacy overlay-on-top behaviour for the
      // alpha-cutout kinds (backgroundRemoval, composeSubject, the
      // beauty layers, hair-clothes-recolour) plus the two
      // borderline opaque-output kinds (faceReshape / skyReplace)
      // we intentionally left untouched. Flipping any of these
      // must be a deliberate code change that updates this test.
      for (final k in AdjustmentKind.values) {
        if (destructive.contains(k)) continue;
        expect(k.destructiveRaster, isFalse,
            reason: '${k.name} should stay on the overlay paint path '
                '(legacy behaviour); flip its flag deliberately.');
      }
    });
  });
}
