import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/rendering/shader_texture_pool.dart';

/// Contract tests for [ShaderTexturePool].
///
/// The pool's job is to hold exactly two [ui.Image] slots across frames,
/// disposing the slot-peer (two installs ago) on every install. The
/// renderer reads the most-recently installed slot; the opposite-parity
/// install disposes the image the renderer just *finished* reading, not
/// the one it's about to read. These tests pin that invariant.
///
/// Test images are made via `decodeImageFromPixels` (tiny solid colours)
/// so the suite runs without a GPU — `ui.Image.dispose()` is synchronous
/// and observable via its `debugDisposed` flag.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> makeImage(int w, int h, int rgba) async {
    final pixels = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      pixels[i * 4 + 0] = (rgba >> 24) & 0xff;
      pixels[i * 4 + 1] = (rgba >> 16) & 0xff;
      pixels[i * 4 + 2] = (rgba >> 8) & 0xff;
      pixels[i * 4 + 3] = rgba & 0xff;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  group('ShaderTexturePool', () {
    test('starts empty with zero dimensions', () {
      final pool = ShaderTexturePool();
      expect(pool.latest, isNull);
      expect(pool.cursor, 0);
      expect(pool.debugDimensions, (width: 0, height: 0));
      expect(pool.debugSlots, (slotA: null, slotB: null));
      pool.dispose();
    });

    test('beginFrame sets dimensions and keeps cursor at 0', () {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 100, height: 80);
      expect(pool.debugDimensions, (width: 100, height: 80));
      expect(pool.cursor, 0);
      pool.dispose();
    });

    test('first two installs land in slot A then slot B', () async {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 2, height: 2);

      final img0 = await makeImage(2, 2, 0xff000000);
      pool.install(img0);
      expect(pool.debugSlots.slotA, same(img0));
      expect(pool.debugSlots.slotB, isNull);
      expect(pool.latest, same(img0));
      expect(pool.cursor, 1);

      final img1 = await makeImage(2, 2, 0xffff0000);
      pool.install(img1);
      expect(pool.debugSlots.slotA, same(img0));
      expect(pool.debugSlots.slotB, same(img1));
      expect(pool.latest, same(img1));
      expect(pool.cursor, 2);

      pool.dispose();
    });

    test('third install disposes slot-A peer (two installs ago)', () async {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 2, height: 2);

      final img0 = await makeImage(2, 2, 0xff000000);
      final img1 = await makeImage(2, 2, 0xffff0000);
      final img2 = await makeImage(2, 2, 0xff00ff00);

      pool.install(img0);
      pool.install(img1);
      pool.install(img2);

      // img0 (slot A peer) must be disposed; img1 (still in B) alive;
      // img2 (current A) alive and latest.
      expect(img0.debugDisposed, isTrue);
      expect(img1.debugDisposed, isFalse);
      expect(img2.debugDisposed, isFalse);
      expect(pool.latest, same(img2));
      expect(pool.debugSlots, (slotA: img2, slotB: img1));

      pool.dispose();
    });

    test('fourth install disposes slot-B peer', () async {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 2, height: 2);

      final img0 = await makeImage(2, 2, 0xff000000);
      final img1 = await makeImage(2, 2, 0xffff0000);
      final img2 = await makeImage(2, 2, 0xff00ff00);
      final img3 = await makeImage(2, 2, 0xff0000ff);

      pool.install(img0);
      pool.install(img1);
      pool.install(img2);
      pool.install(img3);

      expect(img0.debugDisposed, isTrue);
      expect(img1.debugDisposed, isTrue); // slot B peer, two ago
      expect(img2.debugDisposed, isFalse); // in slot A
      expect(img3.debugDisposed, isFalse); // in slot B, latest
      expect(pool.latest, same(img3));

      pool.dispose();
    });

    test('cross-frame: slots persist across beginFrame, next frame '
        'disposes prior-frame peers', () async {
      final pool = ShaderTexturePool();

      // Frame 1: two installs.
      pool.beginFrame(width: 2, height: 2);
      final f1a = await makeImage(2, 2, 0xffaa0000);
      final f1b = await makeImage(2, 2, 0xffbb0000);
      pool.install(f1a);
      pool.install(f1b);
      expect(f1a.debugDisposed, isFalse);
      expect(f1b.debugDisposed, isFalse);

      // Frame 2 begins. Slots survive the beginFrame call unchanged.
      pool.beginFrame(width: 2, height: 2);
      expect(pool.cursor, 0);
      expect(pool.debugSlots, (slotA: f1a, slotB: f1b));
      expect(f1a.debugDisposed, isFalse);
      expect(f1b.debugDisposed, isFalse);

      // First install of frame 2 writes slot A, disposing f1a.
      final f2a = await makeImage(2, 2, 0xff00aa00);
      pool.install(f2a);
      expect(f1a.debugDisposed, isTrue);
      expect(f1b.debugDisposed, isFalse);
      expect(pool.debugSlots, (slotA: f2a, slotB: f1b));

      // Second install writes slot B, disposing f1b.
      final f2b = await makeImage(2, 2, 0xff00bb00);
      pool.install(f2b);
      expect(f1b.debugDisposed, isTrue);
      expect(pool.debugSlots, (slotA: f2a, slotB: f2b));

      pool.dispose();
    });

    test('dimension change on beginFrame flushes both slots', () async {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 4, height: 4);
      final a = await makeImage(4, 4, 0xff111111);
      final b = await makeImage(4, 4, 0xff222222);
      pool.install(a);
      pool.install(b);
      expect(a.debugDisposed, isFalse);
      expect(b.debugDisposed, isFalse);

      // User loads a different-sized preview. beginFrame must flush
      // both slots — the cached textures are the wrong size and would
      // trip the install assertion on the next install.
      pool.beginFrame(width: 8, height: 8);
      expect(a.debugDisposed, isTrue);
      expect(b.debugDisposed, isTrue);
      expect(pool.debugSlots, (slotA: null, slotB: null));
      expect(pool.debugDimensions, (width: 8, height: 8));

      pool.dispose();
    });

    test('dispose is idempotent and disposes live slots', () async {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 2, height: 2);
      final a = await makeImage(2, 2, 0xff000000);
      final b = await makeImage(2, 2, 0xffffffff);
      pool.install(a);
      pool.install(b);

      expect(pool.isDisposed, isFalse);
      pool.dispose();
      expect(pool.isDisposed, isTrue);
      expect(a.debugDisposed, isTrue);
      expect(b.debugDisposed, isTrue);

      // Calling again is a no-op.
      pool.dispose();
      expect(pool.isDisposed, isTrue);
    });

    test('install asserts dimension match (debug builds)', () async {
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 4, height: 4);
      final wrongSize = await makeImage(2, 2, 0xff000000);
      expect(
        () => pool.install(wrongSize),
        throwsA(isA<AssertionError>()),
      );
      wrongSize.dispose();
      pool.dispose();
    });

    test('beginFrame asserts not disposed', () {
      final pool = ShaderTexturePool();
      pool.dispose();
      expect(
        () => pool.beginFrame(width: 2, height: 2),
        throwsA(isA<AssertionError>()),
      );
    });

    test('peak slot occupancy stays at 2 across N installs', () async {
      // The whole point of ping-pong: regardless of pass count, at
      // most two slots are populated simultaneously. Simulates a
      // pathological 10-pass pipeline.
      final pool = ShaderTexturePool();
      pool.beginFrame(width: 2, height: 2);
      final all = <ui.Image>[];
      for (int i = 0; i < 10; i++) {
        final img = await makeImage(2, 2, 0xff000000 | i);
        all.add(img);
        pool.install(img);
        final slots = pool.debugSlots;
        final live = [slots.slotA, slots.slotB].where((e) => e != null).length;
        expect(live, lessThanOrEqualTo(2),
            reason: 'install $i: expected ≤2 live slots');
      }
      // All but the last two images must be disposed.
      for (int i = 0; i < 8; i++) {
        expect(all[i].debugDisposed, isTrue,
            reason: 'install $i should have been evicted');
      }
      expect(all[8].debugDisposed, isFalse);
      expect(all[9].debugDisposed, isFalse);
      pool.dispose();
    });
  });
}
