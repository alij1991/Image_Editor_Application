import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/op_registry.dart';

/// Consistency tests for the `shaderPassRequired` classifier.
///
/// Every op the registry marks as needing a dedicated shader pass MUST
/// have a render-path implementation. Without this check, an op can be
/// defined + classified + absent from `_passesFor()` and the user just
/// sees nothing happen (what Phase I.7 found for `denoiseNlm` and —
/// still outstanding — for `clarity`, `gaussianBlur`, `radialBlur`,
/// `perspective`).
///
/// Two sources of truth are reconciled:
///
///   1. [_handledByPassesFor]: ops that `_passesFor()` in
///      `editor_session.dart` actually dispatches to a shader. Hand-
///      maintained — update whenever you add or remove a pass. Treated
///      as the canonical "what we really render" list.
///   2. [OpRegistry.shaderPassRequired]: the classifier the engine
///      reads to decide whether an op can be matrix-folded. Derived
///      from each `OpRegistration`'s `shaderPass: true` flag (post
///      Phase III.1).
///
/// The invariant:
/// `shaderPassRequired ⊆ _handledByPassesFor ∪ _knownGaps`.
///
/// Any new op added to `shaderPassRequired` MUST land in exactly one of
/// those sets. The `_knownGaps` side is deliberately lossy — a gap
/// means the op renders unchanged today, so each entry there should be
/// tracked as a separate improvement item (see IMPROVEMENTS.md).
void main() {
  // Ops that `_passesFor()` dispatches as of Phase I.7. If you add or
  // remove a branch in `editor_session.dart::_passesFor`, mirror it
  // here.
  const handled = <String>{
    EditOpType.highlights,
    EditOpType.shadows,
    EditOpType.whites,
    EditOpType.blacks,
    EditOpType.vibrance,
    EditOpType.texture,
    EditOpType.dehaze,
    EditOpType.levels,
    EditOpType.gamma,
    EditOpType.toneCurve,
    EditOpType.hsl,
    EditOpType.splitToning,
    EditOpType.colorGrading,
    EditOpType.lut3d,
    EditOpType.denoiseBilateral,
    EditOpType.sharpen,
    EditOpType.tiltShift,
    EditOpType.motionBlur,
    EditOpType.vignette,
    EditOpType.chromaticAberration,
    EditOpType.pixelate,
    EditOpType.halftone,
    EditOpType.glitch,
    EditOpType.grain,
    // XVI.45 — Guided Upright dispatches to PerspectiveWarpShader via
    // _guidedUprightPass at the head of editorPassBuilders.
    EditOpType.guidedUpright,
    // XVI.46 — Lens distortion dispatches to LensDistortionShader via
    // _lensDistortionPass right after the guided-upright pass.
    EditOpType.lensDistortion,
    // XVI.40 — Lens blur dispatches to LensBlurShader via
    // _lensBlurPass after the motion-blur pass; gated on a cached
    // depth map (silent fallback when the bundled depth model is
    // missing or the bake is in flight).
    EditOpType.lensBlur,
  };

  // Ops that `shaderPassRequired` lists but `_passesFor()` does NOT
  // dispatch. Each is a known silent-broken bug with its own follow-up
  // item. Kept here intentionally so this test stays green while the
  // improvements land one at a time.
  //
  //   - clarity:      ClarityShader class exists; 7 built-in presets
  //                   currently emit this op but render nothing.
  //   - gaussianBlur: no shader class yet; preset-replaceable but dead.
  //   - radialBlur:   RadialBlurShader exists; no dispatch.
  //   - perspective:  PerspectiveWarpShader exists; geometry warp path
  //                   may live outside _passesFor() — needs audit.
  //
  // When any of the above is wired up, move it from `_knownGaps` into
  // `_handledByPassesFor` in the same PR so this test keeps its
  // meaning.
  const knownGaps = <String>{
    EditOpType.clarity,
    EditOpType.gaussianBlur,
    EditOpType.radialBlur,
    EditOpType.perspective,
  };

  group('OpRegistry shaderPassRequired consistency', () {
    test('every shaderPassRequired op is handled or explicitly gapped', () {
      final missing = <String>[];
      for (final op in OpRegistry.shaderPassRequired) {
        if (!handled.contains(op) && !knownGaps.contains(op)) {
          missing.add(op);
        }
      }
      expect(
        missing,
        isEmpty,
        reason:
            'Ops in shaderPassRequired must either be dispatched by '
            '_passesFor() (add to `handled`) or explicitly flagged as a '
            'known gap (add to `knownGaps` with a tracked follow-up). '
            'Silently leaving them classified but unrendered is the bug '
            'that produced Phase I.7.\nOffending: $missing',
      );
    });

    test('handled set has no ops missing from shaderPassRequired', () {
      // Reverse direction: catches an op that `_passesFor()` dispatches
      // but that isn't in `shaderPassRequired`. Such an op would be
      // misclassified as matrix-foldable and its dedicated pass would
      // collide with the fold path.
      final orphans = handled.difference(OpRegistry.shaderPassRequired);
      expect(
        orphans,
        isEmpty,
        reason:
            'These ops are dispatched by _passesFor() but missing from '
            'shaderPassRequired: $orphans',
      );
    });

    test('knownGaps is a subset of shaderPassRequired', () {
      // A gap entry only makes sense if the op is still classified. If
      // an op is removed from the classifier, remove it from gaps too.
      final stale = knownGaps.difference(OpRegistry.shaderPassRequired);
      expect(
        stale,
        isEmpty,
        reason:
            'These knownGaps entries are no longer in shaderPassRequired '
            '— either restore the classifier membership or remove the '
            'gap entry: $stale',
      );
    });
  });

  group('EditOpType delete-path guards', () {
    test('denoiseNlm is gone (Phase I.7)', () {
      // Guard against accidental re-introduction. If you need NLM back,
      // ship the shader + `_passesFor()` dispatch FIRST and THEN add
      // the constant back.
      const legacyString = 'noise.nonLocalMeans';
      expect(
        OpRegistry.shaderPassRequired.contains(legacyString),
        isFalse,
        reason: 'denoiseNlm must not return to shaderPassRequired without '
            'a matching _passesFor() branch',
      );
      expect(OpRegistry.presetReplaceable.contains(legacyString), isFalse);
      expect(OpRegistry.mementoRequired.contains(legacyString), isFalse);
      expect(OpRegistry.matrixComposable.contains(legacyString), isFalse);
    });

    test('aiColorize is gone (Phase I.6)', () {
      // Sibling guard to denoiseNlm — this file is the natural home for
      // "op type intentionally absent" invariants so future contributors
      // see the delete decisions in one place.
      const legacyString = 'ai.colorize';
      expect(OpRegistry.mementoRequired.contains(legacyString), isFalse);
      expect(OpRegistry.presetReplaceable.contains(legacyString), isFalse);
      expect(OpRegistry.shaderPassRequired.contains(legacyString), isFalse);
    });
  });
}
