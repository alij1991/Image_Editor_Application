import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/logging/app_logger.dart';

final _log = AppLogger('LensProfileDb');

/// Phase XVI.35 — bundled lens profile database for auto-correct of
/// chromatic aberration + vignette on session start. Each entry maps
/// an EXIF Make + Model substring to a small set of correction
/// constants the editor folds into the initial pipeline.
///
/// Asset path: `assets/lens_profiles/manifest.json`. Loaded once per
/// process via [LensProfileDb.load] and cached on the singleton.
/// Silent-fallback: if the asset is missing or malformed the DB
/// stays empty and `match()` returns null — the editor proceeds with
/// no auto-correct, matching pre-XVI.35 behaviour.
class LensProfile {
  const LensProfile({
    required this.make,
    required this.modelPattern,
    required this.ca,
    required this.vignetteAmount,
    required this.vignetteFeather,
  });

  /// Case-insensitive prefix match against the EXIF Make tag.
  /// "Apple" matches "Apple" but not "Samsung Apple". Empty string
  /// is a wildcard (used by the OnePlus catch-all entry).
  final String make;

  /// Case-insensitive substring match against the EXIF Model tag.
  /// "iPhone 15 Pro" matches "iPhone 15 Pro Max" so model lines stay
  /// short. Empty string is a wildcard.
  final String modelPattern;

  /// `chromaticAberration` op `amount` to seed the pipeline with.
  final double ca;

  /// `vignette` op `amount`. Positive darkens corners (lens-style).
  final double vignetteAmount;

  /// `vignette` op `feather`. Identity is 0.4 — different here so a
  /// 0.55 feather looks softer than the default vignette UI.
  final double vignetteFeather;

  /// True when this profile contributes anything observable. A
  /// matched profile with all-zero coefficients (could happen via a
  /// future bumpless lens entry) is treated as "no auto-correct
  /// needed" — the matcher returns it but the session-level merge
  /// short-circuits.
  bool get isObservable =>
      ca.abs() > 1e-3 || vignetteAmount.abs() > 1e-3;

  factory LensProfile.fromJson(Map<String, dynamic> json) {
    return LensProfile(
      make: (json['make'] as String? ?? '').trim(),
      modelPattern: (json['modelPattern'] as String? ?? '').trim(),
      ca: ((json['ca'] as num?) ?? 0).toDouble(),
      vignetteAmount: ((json['vignetteAmount'] as num?) ?? 0).toDouble(),
      vignetteFeather: ((json['vignetteFeather'] as num?) ?? 0.4).toDouble(),
    );
  }
}

class LensProfileDb {
  LensProfileDb._(this._profiles);

  final List<LensProfile> _profiles;

  /// Visible for tests so they can assert against the loaded set
  /// without going through `match()`.
  List<LensProfile> get profiles => List.unmodifiable(_profiles);

  /// Construct directly from a profile list. Tests use this; the
  /// production path goes through [load] which reads the bundled
  /// asset.
  factory LensProfileDb.fromProfiles(List<LensProfile> profiles) {
    return LensProfileDb._(List.of(profiles));
  }

  static const _assetPath = 'assets/lens_profiles/manifest.json';

  /// Load the bundled JSON. Silent-fallback returns an empty DB on
  /// any error — the editor's auto-correct then becomes a no-op,
  /// matching pre-XVI.35 behaviour.
  static Future<LensProfileDb> load() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) {
        _log.w('lens profile json is not an object', {'type': '${parsed.runtimeType}'});
        return LensProfileDb._(const []);
      }
      final list = parsed['profiles'];
      if (list is! List) {
        _log.w('lens profile json missing "profiles" array');
        return LensProfileDb._(const []);
      }
      final profiles = <LensProfile>[];
      for (final entry in list) {
        if (entry is Map<String, dynamic>) {
          profiles.add(LensProfile.fromJson(entry));
        }
      }
      _log.i('lens profile db loaded', {'count': profiles.length});
      return LensProfileDb._(profiles);
    } catch (e, st) {
      _log.w('lens profile db load failed',
          {'err': '$e', 'st': '$st'});
      return LensProfileDb._(const []);
    }
  }

  /// First profile whose Make matches (case-insensitive prefix) and
  /// whose modelPattern is a case-insensitive substring of [model].
  /// Returns null when nothing matches OR when [make] is null —
  /// without a make tag we don't trust a model-only match (e.g. a
  /// generic "Camera" model would falsely match too many profiles).
  ///
  /// Order matters: more-specific entries are listed first in the
  /// JSON so the iPhone 15 Pro profile wins over the catch-all
  /// "iPhone" entry.
  LensProfile? match(String? make, String? model) {
    if (make == null || make.trim().isEmpty) return null;
    final mk = make.toLowerCase();
    final mdl = (model ?? '').toLowerCase();
    for (final p in _profiles) {
      if (p.make.isEmpty) {
        // Empty make = wildcard, but still gate on model match below.
      } else if (!mk.startsWith(p.make.toLowerCase())) {
        continue;
      }
      if (p.modelPattern.isEmpty || mdl.contains(p.modelPattern.toLowerCase())) {
        return p;
      }
    }
    return null;
  }
}
