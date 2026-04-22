import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';

/// IX.A.2 — presets only replace parametric colour / geometry / effect
/// ops. AI ops produce destructive rasters stored via Memento, so
/// "applying a preset" must NOT wipe them (otherwise the user loses
/// their background-removal cutout just because they tapped a
/// lightroom recipe). This test walks every registered AI op type
/// and asserts `presetReplaceable == false` for all of them.
///
/// A generated test — adding a new AI op to `OpRegistry` that
/// accidentally ships with `presetReplaceable: true` fails here.
void main() {
  /// Every op type whose reversal requires a Memento snapshot.
  /// `mementoRequired` is the registry's categorisation of AI-style
  /// destructive ops (plus `drawing`, which is intentionally excluded
  /// from preset replacement for the same reason — multi-stroke
  /// sessions shouldn't disappear under a preset tap).
  final destructiveTypes = OpRegistry.mementoRequired;

  test('every memento-required (AI or drawing) op is non-preset-replaceable',
      () {
    expect(destructiveTypes, isNotEmpty,
        reason: 'sanity — at least one AI op must exist');

    for (final type in destructiveTypes) {
      final entry = OpRegistry.byType[type];
      expect(entry, isNotNull, reason: 'missing registry entry for $type');
      expect(entry!.presetReplaceable, isFalse,
          reason: 'op "$type" is memento-required but ALSO marked '
              'presetReplaceable — that would erase the user\'s '
              'destructive work on preset apply. Remove '
              'presetReplaceable: true from this entry.');
    }
  });

  test('OpRegistry.presetReplaceable set excludes every memento-required type',
      () {
    final overlap = OpRegistry.presetReplaceable.intersection(destructiveTypes);
    expect(overlap, isEmpty,
        reason: 'presetReplaceable must not intersect mementoRequired — '
            'overlap: $overlap');
  });

  test('spot-check: AI ops are enumerated + all absent from presetReplaceable',
      () {
    const aiOps = <String>[
      EditOpType.aiBackgroundRemoval,
      EditOpType.aiInpaint,
      EditOpType.aiSuperResolution,
      EditOpType.aiStyleTransfer,
      EditOpType.aiFaceBeautify,
      EditOpType.aiSkyReplace,
    ];
    for (final op in aiOps) {
      expect(OpRegistry.presetReplaceable, isNot(contains(op)),
          reason: '$op must not be preset-replaceable');
      expect(OpRegistry.mementoRequired, contains(op),
          reason: '$op must be memento-required so undo restores '
              'the pre-op pixels');
    }
  });
}
