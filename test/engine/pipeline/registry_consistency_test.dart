import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';
import 'package:image_editor/engine/pipeline/op_spec.dart';

/// Consistency tests for the Phase III.1 [OpRegistry].
///
/// The whole point of the registry is that each op is declared in
/// exactly one place, with its flags + specs + interpolating keys all
/// on one `OpRegistration`. These tests pin the "you can't accidentally
/// forget a place" invariant the helper was built to provide.
///
/// If a new op is added without a matching entry in
/// `OpRegistry._entries`, one of these tests will fail.
void main() {
  // -------------------------------------------------------------------
  // Every op-type constant on EditOpType must have exactly one
  // registration. If a new constant is added to `edit_op_type.dart`
  // but not registered, `byType` lookup returns null and the classifier
  // sets silently omit it — which is the exact regression Phase III.1
  // set out to prevent.
  // -------------------------------------------------------------------
  // Hand-maintained mirror of every public op-type constant on
  // `EditOpType`. Dart doesn't expose `dart:mirrors` in production, so
  // we can't reflect over the class. Keep this list in sync whenever
  // an op is added or removed — any future additions that land
  // unregistered will fail the first test in this group.
  const allOpTypes = <String>[
    // color (matrix)
    EditOpType.brightness,
    EditOpType.contrast,
    EditOpType.saturation,
    EditOpType.hue,
    EditOpType.exposure,
    EditOpType.temperature,
    EditOpType.tint,
    EditOpType.channelMixer,
    // color (non-matrix)
    EditOpType.highlights,
    EditOpType.shadows,
    EditOpType.whites,
    EditOpType.blacks,
    EditOpType.vibrance,
    EditOpType.clarity,
    EditOpType.texture,
    EditOpType.dehaze,
    EditOpType.levels,
    EditOpType.gamma,
    EditOpType.toneCurve,
    EditOpType.hsl,
    EditOpType.splitToning,
    // filters / presets
    EditOpType.lut3d,
    EditOpType.matrixPreset,
    // effects
    EditOpType.vignette,
    EditOpType.grain,
    EditOpType.chromaticAberration,
    EditOpType.glitch,
    EditOpType.pixelate,
    EditOpType.halftone,
    EditOpType.sharpen,
    // blurs
    EditOpType.gaussianBlur,
    EditOpType.motionBlur,
    EditOpType.radialBlur,
    EditOpType.tiltShift,
    // noise
    EditOpType.denoiseBilateral,
    // geometry
    EditOpType.crop,
    EditOpType.rotate,
    EditOpType.flip,
    EditOpType.straighten,
    EditOpType.perspective,
    // layers
    EditOpType.drawing,
    EditOpType.text,
    EditOpType.sticker,
    EditOpType.shape,
    EditOpType.raster,
    EditOpType.adjustmentLayer,
    // ai
    EditOpType.aiBackgroundRemoval,
    EditOpType.aiInpaint,
    EditOpType.aiSuperResolution,
    EditOpType.aiStyleTransfer,
    EditOpType.aiFaceBeautify,
    EditOpType.aiSkyReplace,
  ];

  group('OpRegistry coverage', () {
    test('every EditOpType constant has exactly one registration', () {
      final missing = <String>[];
      for (final t in allOpTypes) {
        if (OpRegistry.forType(t) == null) missing.add(t);
      }
      expect(missing, isEmpty, reason: 'unregistered op types: $missing');
    });

    test('no duplicate registrations', () {
      final seen = <String>{};
      final duplicates = <String>[];
      for (final e in OpRegistry.all) {
        if (!seen.add(e.type)) duplicates.add(e.type);
      }
      expect(duplicates, isEmpty);
    });

    test('no orphan registrations (every entry maps to a constant)', () {
      final knownConstants = allOpTypes.toSet();
      final orphans =
          OpRegistry.all.where((e) => !knownConstants.contains(e.type)).toList();
      expect(
        orphans.map((e) => e.type).toList(),
        isEmpty,
        reason: 'registry entries not matching any EditOpType constant. '
            'Either add the constant or remove the registry entry.',
      );
    });
  });

  group('OpRegistry classifier derivation', () {
    test('matrixComposable set matches entries with matrixComposable: true', () {
      final expected = {
        for (final e in OpRegistry.all)
          if (e.matrixComposable) e.type,
      };
      expect(OpRegistry.matrixComposable, equals(expected));
    });

    test('mementoRequired set matches entries with memento: true', () {
      final expected = {
        for (final e in OpRegistry.all)
          if (e.memento) e.type,
      };
      expect(OpRegistry.mementoRequired, equals(expected));
    });

    test('presetReplaceable set matches entries with presetReplaceable: true',
        () {
      final expected = {
        for (final e in OpRegistry.all)
          if (e.presetReplaceable) e.type,
      };
      expect(OpRegistry.presetReplaceable, equals(expected));
    });

    test('shaderPassRequired set matches entries with shaderPass: true', () {
      final expected = {
        for (final e in OpRegistry.all)
          if (e.shaderPass) e.type,
      };
      expect(OpRegistry.shaderPassRequired, equals(expected));
    });

    test('AI ops are all memento-required and none preset-replaceable', () {
      const aiOps = {
        EditOpType.aiBackgroundRemoval,
        EditOpType.aiInpaint,
        EditOpType.aiSuperResolution,
        EditOpType.aiStyleTransfer,
        EditOpType.aiFaceBeautify,
        EditOpType.aiSkyReplace,
      };
      for (final t in aiOps) {
        expect(OpRegistry.mementoRequired.contains(t), isTrue,
            reason: '$t should require memento');
        expect(OpRegistry.presetReplaceable.contains(t), isFalse,
            reason: '$t must not be preset-replaceable — AI results are '
                'destructive and survive preset application');
      }
    });

    test('layer + geometry ops are never preset-replaceable', () {
      const layerOps = {
        EditOpType.drawing,
        EditOpType.text,
        EditOpType.sticker,
        EditOpType.shape,
        EditOpType.raster,
        EditOpType.adjustmentLayer,
      };
      const geometryOps = {
        EditOpType.crop,
        EditOpType.rotate,
        EditOpType.flip,
        EditOpType.straighten,
        EditOpType.perspective,
      };
      for (final t in {...layerOps, ...geometryOps}) {
        expect(OpRegistry.presetReplaceable.contains(t), isFalse,
            reason: '$t must not be preset-replaceable — geometry / layer '
                'state is orthogonal to a filter preset');
      }
    });
  });

  group('OpRegistry spec / interpolating-keys derivation', () {
    test('OpSpecs.all matches flattened registry specs', () {
      final expected = [
        for (final e in OpRegistry.all) ...e.specs,
      ];
      expect(OpSpecs.all, equals(expected));
    });

    test('every spec.type matches its registration.type', () {
      final mismatches = <String>[];
      for (final e in OpRegistry.all) {
        for (final s in e.specs) {
          if (s.type != e.type) {
            mismatches.add('entry ${e.type} has spec with type ${s.type}');
          }
        }
      }
      expect(mismatches, isEmpty);
    });

    test('every spec reachable via byType / paramsForType', () {
      for (final e in OpRegistry.all) {
        if (e.specs.isEmpty) continue;
        final params = OpSpecs.paramsForType(e.type);
        expect(params.length, e.specs.length,
            reason: 'paramsForType(${e.type}) returned ${params.length} '
                'specs but registry has ${e.specs.length}');
      }
    });

    test('interpolating keys are a subset of the entry\'s param keys', () {
      // An interpolating key that doesn't match any spec's paramKey is
      // dead — `blend()` iterates the op's parameters and looks up each
      // key. Flag the inconsistency so the registry and the spec stay
      // aligned.
      //
      // Entries with no specs are allowed to declare interpolating keys
      // (presets emit those ops with parameters that don't live in
      // OpSpec — e.g. a future scalar op that ships presets before a
      // slider). Today no such case exists, so the test is strict.
      final orphans = <String>[];
      for (final e in OpRegistry.all) {
        if (e.interpolatingKeys.isEmpty) continue;
        if (e.specs.isEmpty) continue;
        final paramKeys = e.specs.map((s) => s.paramKey).toSet();
        for (final k in e.interpolatingKeys) {
          if (!paramKeys.contains(k)) {
            orphans.add('${e.type}: interpolatingKey "$k" not in specs '
                '(${paramKeys.join(",")})');
          }
        }
      }
      expect(orphans, isEmpty);
    });

    test('interpolatingKeysFor returns empty for unregistered type', () {
      expect(
        OpRegistry.interpolatingKeysFor('not.a.real.op'),
        isEmpty,
      );
    });

    test(
        'every single-scalar op has "value" in its effective interpolating '
        'keys', () {
      // Phase III.3 contract: a single-spec op whose paramKey is
      // `'value'` (the scalar convention) must interpolate its value
      // with preset amount — otherwise the preset Amount slider
      // silently does nothing for that op.
      //
      // The default in `OpRegistration.effectiveInterpolatingKeys`
      // enforces this for any op that doesn't declare an explicit
      // set. This test pins the invariant so the default doesn't
      // regress (e.g. someone lands a scalar op with explicit
      // `interpolatingKeys: const {}` which would silently disable
      // it).
      final misses = <String>[];
      for (final e in OpRegistry.all) {
        if (e.specs.length != 1) continue;
        if (e.specs.single.paramKey != 'value') continue;
        if (!e.effectiveInterpolatingKeys.contains('value')) {
          misses.add(e.type);
        }
      }
      expect(misses, isEmpty,
          reason: 'scalar ops missing "value" in effective interpolating '
              'keys — preset Amount slider would silently do nothing: '
              '$misses');
    });

    test(
        'effective keys == declared keys for entries with explicit '
        'declarations', () {
      // If a registration declared interpolating keys explicitly,
      // the effective set must match it exactly — the default only
      // fires when the declared set is empty.
      for (final e in OpRegistry.all) {
        if (e.interpolatingKeys.isEmpty) continue;
        expect(e.effectiveInterpolatingKeys, equals(e.interpolatingKeys),
            reason: '${e.type}: effective keys drifted from declared');
      }
    });

    test(
        'effective keys default applies only to single-scalar '
        'paramKey=="value" ops', () {
      // Guard the default rule: it fires exactly when
      // (declared.isEmpty && specs.length == 1 && specs.single.paramKey == 'value').
      // Any other shape (multi-spec, non-"value" paramKey, or
      // no-spec) with an empty declaration stays empty.
      for (final e in OpRegistry.all) {
        if (e.interpolatingKeys.isNotEmpty) continue;
        final isScalarValue = e.specs.length == 1 &&
            e.specs.single.paramKey == 'value';
        if (isScalarValue) {
          expect(e.effectiveInterpolatingKeys, equals({'value'}),
              reason: '${e.type}: scalar default did not fire');
        } else {
          expect(e.effectiveInterpolatingKeys, isEmpty,
              reason: '${e.type}: default fired on a non-scalar op — '
                  'declare interpolatingKeys explicitly if interpolation '
                  'is intended');
        }
      }
    });
  });

  group('OpRegistry removed-op guards', () {
    // Mirrors of the delete-path guards in
    // shader_pass_required_consistency_test.dart but at the registry
    // level. When an op is deleted, the registry must not carry a
    // stale entry either.

    test('denoiseNlm has no registration (Phase I.7)', () {
      expect(OpRegistry.forType('noise.nonLocalMeans'), isNull);
    });

    test('aiColorize has no registration (Phase I.6)', () {
      expect(OpRegistry.forType('ai.colorize'), isNull);
    });

    test('unknown op strings return null (safe fallback)', () {
      expect(OpRegistry.forType('not.a.real.op'), isNull);
      expect(OpRegistry.forType(''), isNull);
    });
  });
}
