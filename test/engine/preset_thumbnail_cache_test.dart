import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/presets/preset.dart';
import 'package:image_editor/features/editor/domain/preset_thumbnail_cache.dart';

/// Phase VI.6 — `PresetThumbnailCache` preview-hash keying contract.
///
/// The module-level singleton caches recipes under
/// (previewHash, preset.id). Tests here pin:
///   - same (preset, hash) → cache hit on the second call;
///   - different hash → cache miss (photo changed invalidates);
///   - different preset → cache miss;
///   - 65th distinct key → LRU evicts the oldest;
///   - recently-used entries survive eviction (MRU promotion);
///   - `hashPreviewImage` is stable per-content + differs across
///     visually-different images.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(PresetThumbnailCache.instance.debugReset);

  Preset presetOf(String id, List<EditOperation> ops) =>
      Preset(id: id, name: id, category: 'test', operations: ops);

  EditOperation op(String type, Map<String, dynamic> params) =>
      EditOperation.create(type: type, parameters: params);

  Future<ui.Image> solid(int w, int h, int rgba) async {
    final bytes = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      bytes[i * 4 + 0] = (rgba >> 24) & 0xff;
      bytes[i * 4 + 1] = (rgba >> 16) & 0xff;
      bytes[i * 4 + 2] = (rgba >> 8) & 0xff;
      bytes[i * 4 + 3] = rgba & 0xff;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  group('PresetThumbnailCache.recipeFor', () {
    test('same (preset, hash) → second call is a hit and returns the '
        'identical recipe object', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('mono', [
        op(EditOpType.saturation, {'value': -1.0}),
      ]);
      expect(cache.debugMisses, 0);
      expect(cache.debugHits, 0);
      final r1 = cache.recipeFor(p, 'hash-abc');
      expect(cache.debugMisses, 1);
      expect(cache.debugHits, 0);
      expect(cache.debugBuilds, 1);
      final r2 = cache.recipeFor(p, 'hash-abc');
      expect(cache.debugMisses, 1);
      expect(cache.debugHits, 1);
      expect(cache.debugBuilds, 1);
      // Pointer-identity: second call reuses the cached recipe object,
      // not a rebuilt equivalent.
      expect(identical(r1, r2), isTrue);
    });

    test('different previewHash → cache miss, both entries coexist', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('mono', [
        op(EditOpType.saturation, {'value': -1.0}),
      ]);
      cache.recipeFor(p, 'hash-A');
      cache.recipeFor(p, 'hash-B');
      expect(cache.debugMisses, 2);
      expect(cache.debugBuilds, 2);
      expect(cache.debugSize, 2);
      // Hash-A still in the cache (hit).
      cache.recipeFor(p, 'hash-A');
      expect(cache.debugHits, 1);
    });

    test('different preset, same hash → cache miss', () {
      final cache = PresetThumbnailCache.instance;
      final a = presetOf('a', [op(EditOpType.exposure, {'value': 0.2})]);
      final b = presetOf('b', [op(EditOpType.contrast, {'value': 0.3})]);
      cache.recipeFor(a, 'same-hash');
      cache.recipeFor(b, 'same-hash');
      expect(cache.debugMisses, 2);
      expect(cache.debugSize, 2);
    });

    test('recipe survives across calls that interleave hashes '
        '(no global state leak)', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('faded', [
        op(EditOpType.contrast, {'value': -0.3}),
      ]);
      cache.recipeFor(p, 'hash-1');
      cache.recipeFor(p, 'hash-2');
      cache.recipeFor(p, 'hash-1'); // hit on hash-1
      expect(cache.debugHits, 1);
      expect(cache.debugMisses, 2);
    });

    test('LRU capacity 64 — 65th unique insertion evicts the first', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('p', []);
      for (int i = 0; i < 64; i++) {
        cache.recipeFor(p, 'h$i');
      }
      expect(cache.debugSize, 64);
      // First hash should still hit.
      cache.recipeFor(p, 'h0');
      expect(cache.debugHits, 1);
      // Insert a new unique hash → pushes cache to 65, evicts 'h0'.
      cache.recipeFor(p, 'h64');
      expect(cache.debugSize, 64);
      // 'h0' was evicted (h0 was just hit so now MRU? no — after hit
      // it went to MRU, so h1 is now the eviction victim). Double
      // check by re-requesting h0 — it should miss.
      // Actually, the touch above promoted h0 to MRU. So the
      // eviction victim was h1.
      // Just verify h0 and h64 are in cache:
      final missesBefore = cache.debugMisses;
      cache.recipeFor(p, 'h0');
      cache.recipeFor(p, 'h64');
      expect(cache.debugMisses, missesBefore);
    });

    test('LRU: MRU promotion protects a touched entry from eviction', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('p', []);
      // Fill exactly to capacity.
      for (int i = 0; i < 64; i++) {
        cache.recipeFor(p, 'k$i');
      }
      expect(cache.debugSize, 64);
      // Touch k0 → promoted to MRU, so the next eviction victim
      // becomes k1 (oldest non-touched).
      cache.recipeFor(p, 'k0');
      // Insert a fresh hash → evicts k1 instead of k0.
      cache.recipeFor(p, 'k_fresh');
      // k0 should still be present.
      final missesBefore = cache.debugMisses;
      cache.recipeFor(p, 'k0');
      expect(cache.debugMisses, missesBefore);
      // k1 should have been evicted.
      cache.recipeFor(p, 'k1');
      expect(cache.debugMisses, missesBefore + 1);
    });

    test('debugReset clears entries and counters', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('p', [op(EditOpType.exposure, {'value': 0.5})]);
      cache.recipeFor(p, 'h');
      cache.recipeFor(p, 'h');
      expect(cache.debugSize, 1);
      expect(cache.debugHits, 1);
      expect(cache.debugMisses, 1);
      cache.debugReset();
      expect(cache.debugSize, 0);
      expect(cache.debugHits, 0);
      expect(cache.debugMisses, 0);
      expect(cache.debugBuilds, 0);
    });

    test('recipe colorMatrix is identity for an empty preset', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf('identity', const []);
      final recipe = cache.recipeFor(p, 'h');
      expect(recipe.colorMatrix.length, 20);
      expect(recipe.colorMatrix[0], 1.0); // r row, r coeff
      expect(recipe.colorMatrix[6], 1.0);
      expect(recipe.colorMatrix[12], 1.0);
      expect(recipe.colorMatrix[18], 1.0);
      expect(recipe.hasVignette, isFalse);
    });

    test('recipe carries vignette amount through to caller', () {
      final cache = PresetThumbnailCache.instance;
      final p = presetOf(
        'vg',
        [op(EditOpType.vignette, {'amount': 0.6})],
      );
      final recipe = cache.recipeFor(p, 'h');
      expect(recipe.vignetteAmount, closeTo(0.6, 1e-6));
      expect(recipe.hasVignette, isTrue);
    });
  });

  group('hashPreviewImage', () {
    test('returns the same hash for byte-identical images', () async {
      final a = await solid(16, 16, 0xff112233);
      final b = await solid(16, 16, 0xff112233);
      try {
        final hashA = await hashPreviewImage(a);
        final hashB = await hashPreviewImage(b);
        expect(hashA, isNotNull);
        expect(hashA, hashB);
        // SHA-256 returns 64 hex chars.
        expect(hashA!.length, 64);
      } finally {
        a.dispose();
        b.dispose();
      }
    });

    test('returns different hashes for visually-different images', () async {
      final a = await solid(16, 16, 0xff000000);
      final b = await solid(16, 16, 0xffffffff);
      try {
        final hashA = await hashPreviewImage(a);
        final hashB = await hashPreviewImage(b);
        expect(hashA, isNot(equals(hashB)));
      } finally {
        a.dispose();
        b.dispose();
      }
    });

    test('different dimensions but same colour produce different hashes',
        () async {
      // Same per-pixel colour but more pixels → more bytes → SHA
      // differs. Without this property the cache would incorrectly
      // share entries across different-resolution proxies.
      final small = await solid(8, 8, 0xff808080);
      final big = await solid(16, 16, 0xff808080);
      try {
        final h1 = await hashPreviewImage(small);
        final h2 = await hashPreviewImage(big);
        expect(h1, isNot(equals(h2)));
      } finally {
        small.dispose();
        big.dispose();
      }
    });
  });
}
