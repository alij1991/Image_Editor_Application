import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image_editor/engine/rendering/shader_pass.dart';
import 'package:image_editor/engine/rendering/shader_renderer.dart';
import 'package:image_editor/engine/rendering/shaders/color_grading_shader.dart';
import 'package:image_editor/engine/rendering/shaders/tonal_shaders.dart';

/// Phase XI.A.3: `ShaderRenderer.shouldRepaint` consults per-pass
/// `contentHash` snapshots so unchanged frames skip GPU work.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Helper: synthesise a tiny ui.Image for tests that don't actually
  // paint — the renderer only reads `source` through identity checks
  // in `shouldRepaint`, so the contents don't matter.
  Future<ui.Image> tinyImage() async {
    final bytes = Uint8List.fromList(List.filled(4, 0));
    final completer = _imageFromPixels(bytes, 1, 1);
    return completer;
  }

  group('ShaderRenderer.shouldRepaint (Phase XI.A.3)', () {
    test('same source + empty passes → no repaint', () async {
      final img = await tinyImage();
      final a = ShaderRenderer(source: img, passes: const []);
      final b = ShaderRenderer(source: img, passes: const []);
      expect(b.shouldRepaint(a), isFalse);
    });

    test('different source → repaint', () async {
      final img1 = await tinyImage();
      final img2 = await tinyImage();
      final a = ShaderRenderer(source: img1, passes: const []);
      final b = ShaderRenderer(source: img2, passes: const []);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('same pass with equal uniforms → no repaint', () async {
      final img = await tinyImage();
      final passA = const VibranceShader(vibrance: 0.5).toPass();
      final passB = const VibranceShader(vibrance: 0.5).toPass();
      final a = ShaderRenderer(source: img, passes: [passA]);
      final b = ShaderRenderer(source: img, passes: [passB]);
      expect(b.shouldRepaint(a), isFalse,
          reason: 'content hashes match — no GPU work needed');
    });

    test('same pass with one scalar changed → repaint', () async {
      final img = await tinyImage();
      final passA = const VibranceShader(vibrance: 0.5).toPass();
      final passB = const VibranceShader(vibrance: 0.6).toPass();
      final a = ShaderRenderer(source: img, passes: [passA]);
      final b = ShaderRenderer(source: img, passes: [passB]);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('pass with null contentHash falls back to repaint', () async {
      final img = await tinyImage();
      final unhashed = ShaderPass(
        assetKey: 'custom',
        setUniforms: (_, i) => i,
      );
      final a = ShaderRenderer(source: img, passes: [unhashed]);
      final b = ShaderRenderer(source: img, passes: [unhashed]);
      expect(b.shouldRepaint(a), isTrue,
          reason: 'null hash must be conservative');
    });

    test('HSL pass with structurally-equal lists → no repaint', () async {
      final img = await tinyImage();
      final hueA = List<double>.filled(8, 0.1);
      final satA = List<double>.filled(8, 0.0);
      final lumA = List<double>.filled(8, 0.0);
      final hueB = List<double>.filled(8, 0.1); // fresh list
      final satB = List<double>.filled(8, 0.0);
      final lumB = List<double>.filled(8, 0.0);
      final passA =
          HslShader(hueDelta: hueA, satDelta: satA, lumDelta: lumA).toPass();
      final passB =
          HslShader(hueDelta: hueB, satDelta: satB, lumDelta: lumB).toPass();
      final a = ShaderRenderer(source: img, passes: [passA]);
      final b = ShaderRenderer(source: img, passes: [passB]);
      expect(b.shouldRepaint(a), isFalse);
    });

    test('HSL pass with one list-element change → repaint', () async {
      final img = await tinyImage();
      final hueA = List<double>.filled(8, 0.1);
      final hueB = List<double>.filled(8, 0.1);
      hueB[3] = 0.5; // changed
      final passA = HslShader(
        hueDelta: hueA,
        satDelta: List.filled(8, 0),
        lumDelta: List.filled(8, 0),
      ).toPass();
      final passB = HslShader(
        hueDelta: hueB,
        satDelta: List.filled(8, 0),
        lumDelta: List.filled(8, 0),
      ).toPass();
      final a = ShaderRenderer(source: img, passes: [passA]);
      final b = ShaderRenderer(source: img, passes: [passB]);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('ColorGrading snapshots matrix contents at build time', () async {
      final img = await tinyImage();
      // Simulate the session's reused scratch buffer: one Float32List
      // that a shader wrapper hashes at build-time, then the next frame
      // would reuse and overwrite. The contentHash must have captured
      // frame-N's values.
      final scratch = Float32List.fromList([
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 1, 0, //
      ]);
      final passA = ColorGradingShader(colorMatrix5x4: scratch).toPass();
      // Simulate frame N+1 overwriting in place.
      scratch[0] = 1.5;
      final passB = ColorGradingShader(colorMatrix5x4: scratch).toPass();
      final a = ShaderRenderer(source: img, passes: [passA]);
      final b = ShaderRenderer(source: img, passes: [passB]);
      expect(b.shouldRepaint(a), isTrue,
          reason: 'frame-N hash ≠ frame-N+1 hash even when buffer is shared');
    });

    test('different pass count → repaint', () async {
      final img = await tinyImage();
      final a = ShaderRenderer(
        source: img,
        passes: [const VibranceShader(vibrance: 0.3).toPass()],
      );
      final b = ShaderRenderer(source: img, passes: const []);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('different assetKey at same index → repaint', () async {
      final img = await tinyImage();
      final passA = const VibranceShader(vibrance: 0.5).toPass();
      final passB = const DehazeShader(amount: 0.5).toPass();
      final a = ShaderRenderer(source: img, passes: [passA]);
      final b = ShaderRenderer(source: img, passes: [passB]);
      expect(b.shouldRepaint(a), isTrue);
    });
  });
}

Future<ui.Image> _imageFromPixels(Uint8List bytes, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
