import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/color/lens_profile_db.dart';

/// Phase XVI.35 — pin the lens profile matcher behaviour and the
/// bundled JSON's structural invariants. The matcher's two failure
/// modes (no make tag, no model match) must both return null cleanly
/// so the editor's auto-correct path silently no-ops in those cases.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LensProfile.match (XVI.35)', () {
    final db = LensProfileDb.fromProfiles(const [
      LensProfile(
        make: 'Apple',
        modelPattern: 'iPhone 15 Pro',
        ca: 0.10,
        vignetteAmount: 0.18,
        vignetteFeather: 0.55,
      ),
      LensProfile(
        make: 'Apple',
        modelPattern: 'iPhone',
        ca: 0.18,
        vignetteAmount: 0.25,
        vignetteFeather: 0.50,
      ),
      LensProfile(
        make: 'samsung',
        modelPattern: 'SM-S928',
        ca: 0.12,
        vignetteAmount: 0.20,
        vignetteFeather: 0.55,
      ),
    ]);

    test('first matching entry wins (specific before catch-all)', () {
      final p = db.match('Apple', 'iPhone 15 Pro Max');
      expect(p, isNotNull);
      expect(p!.modelPattern, 'iPhone 15 Pro');
      expect(p.ca, 0.10);
    });

    test('catch-all entry matches a less-specific model', () {
      // "iPhone 11" doesn't hit the iPhone-15-Pro-specific entry but
      // does hit the broader "iPhone" catch-all below it.
      final p = db.match('Apple', 'iPhone 11');
      expect(p, isNotNull);
      expect(p!.modelPattern, 'iPhone');
      expect(p.ca, 0.18);
    });

    test('case-insensitive make + model matching', () {
      final p = db.match('APPLE', 'IPHONE 15 PRO MAX');
      expect(p, isNotNull);
      expect(p!.modelPattern, 'iPhone 15 Pro');
    });

    test('null make returns null (no model-only matches)', () {
      // Without a make tag we don't trust a model substring — too
      // many false positives across DSLR + phone DBs.
      final p = db.match(null, 'iPhone 15 Pro Max');
      expect(p, isNull);
    });

    test('non-matching make returns null', () {
      final p = db.match('Sony', 'iPhone 15 Pro');
      expect(p, isNull);
    });

    test('non-matching model under matching make returns null', () {
      final p = db.match('samsung', 'Galaxy XYZ');
      expect(p, isNull);
    });
  });

  group('LensProfileDb.load (XVI.35)', () {
    test('bundled manifest deserialises and is non-empty', () async {
      final db = await LensProfileDb.load();
      expect(db.profiles, isNotEmpty,
          reason: 'assets/lens_profiles/manifest.json must be bundled');

      // Every profile must have at least a non-empty make so the
      // matcher's "skip null make" rule still admits it.
      for (final p in db.profiles) {
        expect(p.make.isNotEmpty || p.modelPattern.isNotEmpty, isTrue,
            reason: 'profile must specify either make or modelPattern '
                '(both empty would silently match every photo)');
      }
    });

    test('Apple iPhone 15 Pro Max resolves through the bundled manifest',
        () async {
      final db = await LensProfileDb.load();
      final p = db.match('Apple', 'iPhone 15 Pro Max');
      expect(p, isNotNull, reason: 'flagship phone should resolve');
      expect(p!.isObservable, isTrue,
          reason: 'matched profile must contribute non-zero deltas');
    });

    test('malformed JSON returns empty DB (silent fallback)', () {
      // Direct construction with no profiles mirrors what a load
      // failure produces (the production loader catches every error
      // and returns the empty DB). `match` must come back null
      // cleanly so the EditorSession.start path no-ops.
      final db = LensProfileDb.fromProfiles(const []);
      expect(db.profiles, isEmpty);
      expect(db.match('Apple', 'iPhone 15 Pro'), isNull);
    });
  });

  group('LensProfile.isObservable', () {
    test('zero coefficients are not observable', () {
      const p = LensProfile(
        make: 'X',
        modelPattern: 'Y',
        ca: 0.0,
        vignetteAmount: 0.0,
        vignetteFeather: 0.4,
      );
      expect(p.isObservable, isFalse);
    });

    test('any non-trivial CA or vignette flips to observable', () {
      const ca = LensProfile(
        make: 'X',
        modelPattern: 'Y',
        ca: 0.05,
        vignetteAmount: 0.0,
        vignetteFeather: 0.4,
      );
      const vig = LensProfile(
        make: 'X',
        modelPattern: 'Y',
        ca: 0.0,
        vignetteAmount: 0.05,
        vignetteFeather: 0.4,
      );
      expect(ca.isObservable, isTrue);
      expect(vig.isObservable, isTrue);
    });
  });
}
