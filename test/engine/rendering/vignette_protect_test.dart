import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';
import 'package:image_editor/engine/pipeline/matrix_composer.dart';
import 'package:image_editor/engine/presets/lut_asset_cache.dart';
import 'package:image_editor/engine/rendering/shader_keys.dart';
import 'package:image_editor/features/editor/presentation/notifiers/pass_builders.dart';

/// Phase XVI.33 — pin the contract for the subject-aware vignette
/// pass:
///   1. Without a subject mask AND without a fallback, the pass is
///      skipped (defensive — every production code path provides at
///      least one).
///   2. With a fallback only (no real mask), the pass IS emitted —
///      the shader receives a 1×1 transparent texture so `mask` is 0
///      and the protect mix collapses to identity. Vignette behaves
///      as pre-XVI.33.
///   3. With a real subject mask, the pass binds it as the second
///      sampler so the shader can read `texture(u_subjectMask, uv).a`
///      to recover the mask.
///   4. The `protectStrength` uniform is gated by the `protectSubject`
///      flag — when the flag is false the strength is zero regardless
///      of the raw param value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image fallback;
  late ui.Image subjectMask;
  setUpAll(() async {
    Future<ui.Image> bake(List<int> rgba) {
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList(rgba),
        1,
        1,
        ui.PixelFormat.rgba8888,
        c.complete,
      );
      return c.future;
    }

    fallback = await bake(const [0, 0, 0, 0]);
    subjectMask = await bake(const [255, 255, 255, 255]);
  });

  PassBuildContext makeCtx({
    ui.Image? subjectMaskImage,
    ui.Image? subjectMaskFallback,
  }) {
    return PassBuildContext(
      composer: const MatrixComposer(),
      matrixScratch: Float32List(20),
      curveLutImage: null,
      curveLutKey: null,
      curveLutLoading: false,
      onBakeCurveLut: (_, _) {},
      lutCache: LutAssetCache.instance,
      onRebuildPreview: () {},
      isDisposed: () => false,
      onClearCurveLutCache: () {},
      subjectMaskImage: subjectMaskImage,
      subjectMaskFallback: subjectMaskFallback,
    );
  }

  EditPipeline pipelineWithVignette(Map<String, dynamic> extraParams) {
    final op = EditOperation.create(
      type: EditOpType.vignette,
      parameters: {
        'amount': 0.6,
        'feather': 0.4,
        ...extraParams,
      },
    );
    return EditPipeline.forOriginal('/tmp/img.jpg').append(op);
  }

  group('vignette pass: subject mask threading (XVI.33)', () {
    test('no mask + no fallback → pass is skipped', () {
      // Defensive — production always provides at least a fallback.
      // Tests that don't care about vignette ordering may pass null.
      final pipeline = pipelineWithVignette(const {});
      final ctx = makeCtx();
      final passes = <String>[];
      for (final build in editorPassBuilders) {
        for (final pass in build(pipeline, ctx)) {
          passes.add(pass.assetKey);
        }
      }
      expect(passes, isNot(contains(ShaderKeys.vignette)));
    });

    test('fallback only, no real mask → pass emits with fallback bound',
        () {
      final pipeline = pipelineWithVignette(const {});
      final ctx = makeCtx(subjectMaskFallback: fallback);
      final passes = <String>[];
      ui.Image? boundSampler;
      for (final build in editorPassBuilders) {
        for (final pass in build(pipeline, ctx)) {
          passes.add(pass.assetKey);
          if (pass.assetKey == ShaderKeys.vignette) {
            boundSampler = pass.samplers.first;
          }
        }
      }
      expect(passes, contains(ShaderKeys.vignette));
      expect(boundSampler, same(fallback),
          reason: 'pass builder must bind the fallback when no real '
              'subject mask is set');
    });

    test('real subject mask → pass binds it as the sampler', () {
      final pipeline = pipelineWithVignette(const {
        'protectSubject': true,
        'protectStrength': 0.7,
      });
      final ctx = makeCtx(
        subjectMaskImage: subjectMask,
        subjectMaskFallback: fallback,
      );
      ui.Image? boundSampler;
      for (final build in editorPassBuilders) {
        for (final pass in build(pipeline, ctx)) {
          if (pass.assetKey == ShaderKeys.vignette) {
            boundSampler = pass.samplers.first;
          }
        }
      }
      expect(boundSampler, same(subjectMask),
          reason: 'real subject mask should be preferred over the '
              'fallback');
    });

    test(
        'protectSubject=false → protectStrength is forced to 0 even '
        'when raw param is non-zero', () {
      // The pass builder gates the user-set strength behind the flag
      // so a preset that ships protectStrength: 0.8 but
      // protectSubject: false has no effect.
      // We can't read uniform values from a ShaderPass directly, so
      // assert via the contentHash: two passes with the same flag/
      // strength should hash equal, two with different effective
      // strengths should hash different.
      final ctxWithMask = makeCtx(
        subjectMaskImage: subjectMask,
        subjectMaskFallback: fallback,
      );
      final pipelineProtectOff = pipelineWithVignette(const {
        'protectSubject': false,
        'protectStrength': 0.8,
      });
      final pipelineNoProtectAtAll = pipelineWithVignette(const {});
      final hashOff = _vignetteContentHash(pipelineProtectOff, ctxWithMask);
      final hashNone =
          _vignetteContentHash(pipelineNoProtectAtAll, ctxWithMask);
      expect(hashOff, equals(hashNone),
          reason: 'protectSubject=false must produce the same shader '
              'state as omitting the flag entirely');

      final pipelineProtectOn = pipelineWithVignette(const {
        'protectSubject': true,
        'protectStrength': 0.8,
      });
      final hashOn = _vignetteContentHash(pipelineProtectOn, ctxWithMask);
      expect(hashOn, isNot(equals(hashOff)),
          reason: 'protectSubject=true with strength 0.8 must produce '
              'a different shader state from the no-protect variant');
    });
  });
}

int? _vignetteContentHash(EditPipeline p, PassBuildContext ctx) {
  for (final build in editorPassBuilders) {
    for (final pass in build(p, ctx)) {
      if (pass.assetKey == ShaderKeys.vignette) {
        return pass.contentHash;
      }
    }
  }
  fail('vignette pass missing — pipeline did not emit it');
}
