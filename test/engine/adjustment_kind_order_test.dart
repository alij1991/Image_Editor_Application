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
  test('AdjustmentKind.values has the 11 expected members in order', () {
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
}
