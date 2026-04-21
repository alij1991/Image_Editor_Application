import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';
import 'package:image_editor/engine/presets/preset_applier.dart';

/// Consistency tests for the Phase III.2 `ownedByPreset` migration.
///
/// `PresetApplier.ownedByPreset(op)` previously relied on a hand-
/// maintained prefix list (`color.`, `fx.`, `filter.`, `blur.`,
/// `noise.`) that could drift from the registry's
/// `presetReplaceable` flag. This file pins the one-source invariant:
/// every registered op either IS `presetReplaceable` AND owned, or
/// ISN'T AND preserved. No gray area.
///
/// If a new op is added and the flag is set wrong, both the
/// `matches OpRegistry.presetReplaceable` test and the per-op audit
/// will fail.
void main() {
  group('PresetApplier.ownedByPreset', () {
    test('matches OpRegistry.presetReplaceable bit-for-bit', () {
      // For every registered op, a fabricated operation returns the
      // same owned/not-owned answer as the flag on its registration.
      // This is the "derived, not declared" invariant.
      final mismatches = <String>[];
      for (final entry in OpRegistry.all) {
        final op = EditOperation.create(
          type: entry.type,
          parameters: const {},
        );
        final owned = PresetApplier.ownedByPreset(op);
        if (owned != entry.presetReplaceable) {
          mismatches.add(
            '${entry.type}: ownedByPreset=$owned, '
            'presetReplaceable=${entry.presetReplaceable}',
          );
        }
      }
      expect(mismatches, isEmpty,
          reason: 'ownedByPreset drifted from the registry flag. '
              'ownedByPreset reads OpRegistry.presetReplaceable; if '
              'these don\'t agree, the contains() path is broken.');
    });

    test('every color / fx / filter / blur / noise op is owned', () {
      // Historical invariant from the old prefix list. If a future
      // op under one of these namespaces lands without
      // presetReplaceable: true, this test surfaces it.
      const ownedNamespaces = ['color.', 'fx.', 'filter.', 'blur.', 'noise.'];
      for (final entry in OpRegistry.all) {
        final startsWithOwned = ownedNamespaces.any(entry.type.startsWith);
        if (!startsWithOwned) continue;
        final op = EditOperation.create(
          type: entry.type,
          parameters: const {},
        );
        expect(
          PresetApplier.ownedByPreset(op),
          isTrue,
          reason: '${entry.type} falls under a preset-owned namespace '
              'but is not flagged presetReplaceable. If that\'s '
              'intentional, document it in the registry NOTE.',
        );
      }
    });

    test('no geometry / layer / AI op is owned', () {
      const nonOwnedNamespaces = ['geom.', 'layer.', 'ai.'];
      for (final entry in OpRegistry.all) {
        final startsWithNonOwned =
            nonOwnedNamespaces.any(entry.type.startsWith);
        if (!startsWithNonOwned) continue;
        final op = EditOperation.create(
          type: entry.type,
          parameters: const {},
        );
        expect(
          PresetApplier.ownedByPreset(op),
          isFalse,
          reason: '${entry.type} is geometry/layer/AI — presets must '
              'preserve these across apply (destructive / structural '
              'state that the user placed manually).',
        );
      }
    });

    test('unknown op-type strings are not owned (safe preservation)', () {
      // Removed op types (Phase I.6 aiColorize, Phase I.7 denoiseNlm,
      // or any future deletion) return false — preserved across preset
      // apply rather than silently wiped. The renderer already skips
      // unknown types, so the observable behaviour is unchanged.
      for (final legacy in ['ai.colorize', 'noise.nonLocalMeans', 'not.real']) {
        final op = EditOperation.create(
          type: legacy,
          parameters: const {},
        );
        expect(PresetApplier.ownedByPreset(op), isFalse);
      }
    });

    test('specific known-owned samples return true', () {
      // Pinned sanity checks for the common cases, so a broken
      // dependency (e.g. OpRegistry not loaded) is caught in isolation
      // rather than via the derivation test.
      for (final t in [
        EditOpType.brightness,
        EditOpType.saturation,
        EditOpType.vignette,
        EditOpType.lut3d,
        EditOpType.gaussianBlur,
        EditOpType.denoiseBilateral,
      ]) {
        final op = EditOperation.create(type: t, parameters: const {});
        expect(PresetApplier.ownedByPreset(op), isTrue, reason: t);
      }
    });

    test('specific known-preserved samples return false', () {
      for (final t in [
        EditOpType.crop,
        EditOpType.rotate,
        EditOpType.perspective,
        EditOpType.drawing,
        EditOpType.text,
        EditOpType.adjustmentLayer,
        EditOpType.aiBackgroundRemoval,
        EditOpType.aiInpaint,
      ]) {
        final op = EditOperation.create(type: t, parameters: const {});
        expect(PresetApplier.ownedByPreset(op), isFalse, reason: t);
      }
    });
  });
}
