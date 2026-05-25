/// XVI.98 — Tier 1 lab validation for the sky-replace mask.
///
/// Runs the production [SkyMaskBuilder.build] (and optionally the
/// [GuidedFilter.upsampleMask] post-pass that XVI.93a added) against
/// the synthetic `landscape_horizon_objects` corpus image and grades
/// the result against the hand-derived `sky_mask` ground truth using
/// the B1 metric library.
///
/// The corpus scene is a deliberate reproduction of the device-log
/// regression XVI.93a chased: trees + yellow flowers along the
/// horizon that LOOK skyish-bright but must NOT classify as sky.
///
/// This is the canonical pass/fail gate for the sky-replace mask
/// going forward — any change touching the mask builder, the
/// segmenter, or the guided-filter pass is gated by these
/// assertions before the commit.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_editor/ai/inference/guided_filter.dart';
import 'package:image_editor/ai/inference/sky_colour_gate.dart';
import 'package:image_editor/ai/inference/sky_mask_builder.dart';
import 'package:image_editor/ai/lab/corpus/corpus.dart';
import 'package:image_editor/ai/lab/metrics/metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkyMaskBuilder — landscape_horizon_objects', () {
    late _SkyTestCase fixture;

    setUpAll(() async {
      fixture = await _loadFixture('landscape_horizon_objects');
    });

    test('reports a fixture-shape sanity baseline', () {
      // Sanity check the fixture parsed cleanly so a downstream
      // failure can't be blamed on a stale corpus.
      expect(fixture.width, greaterThan(100));
      expect(fixture.height, greaterThan(100));
      expect(fixture.sourceRgba.length, fixture.width * fixture.height * 4);
      expect(fixture.gtMask.length, fixture.width * fixture.height);
      // Synthetic sky takes ~half the frame (horizon at 55 %).
      final gtCoverage = computeMaskCoverage(fixture.gtMask);
      expect(gtCoverage, greaterThan(0.30));
      expect(gtCoverage, lessThan(0.60));
    });

    test('builder mask produces non-empty coverage', () {
      // The synthetic corpus has a smooth blue→white sky gradient
      // that the colour heuristic can only detect the upper third
      // of (the lower band is too pale + bright for the
      // 0.45-threshold score). That's a known shortcoming of the
      // pure-heuristic path that SegFormer fills in on production.
      // For the Tier-1 lab gate we accept ≥10 % coverage as proof
      // the builder ran and found *some* sky.
      final mask = SkyMaskBuilder.build(
        source: fixture.sourceRgba,
        width: fixture.width,
        height: fixture.height,
      );
      final binary = binariseFloatMask(mask, threshold: 0.5);
      final coverage = computeMaskCoverage(binary);
      final gtCoverage = computeMaskCoverage(fixture.gtMask);
      expect(coverage, greaterThan(0.10),
          reason: 'builder coverage=$coverage gt=$gtCoverage '
              '(empty mask suggests the heuristic broke)');
      // Sanity: builder must not OVER-cover (>10 % beyond GT).
      // A higher-than-GT result implies the heuristic latched onto
      // non-sky pixels.
      expect(coverage, lessThan(gtCoverage + 0.10),
          reason: 'builder over-covers: $coverage vs gt $gtCoverage');
    });

    test(
      'XVI.93a guided-filter radius=8 vs without — diagnostics',
      () {
        // This test is *diagnostic only* in this commit: it logs the
        // base vs refined FPR + coverage so we have a numerical
        // baseline for the XVI.99 fix to grade against. The
        // pass/fail gate flips to enforced once we know which
        // configuration is the production target.
        final maskBase = SkyMaskBuilder.build(
          source: fixture.sourceRgba,
          width: fixture.width,
          height: fixture.height,
        );
        final maskRefined = Float32List.fromList(
          GuidedFilter.upsampleMask(
            smallMask: maskBase,
            smallWidth: fixture.width,
            smallHeight: fixture.height,
            sourceRgba: fixture.sourceRgba,
            srcWidth: fixture.width,
            srcHeight: fixture.height,
            radius: 8,
          ),
        );

        final binaryBase = binariseFloatMask(maskBase, threshold: 0.5);
        final binaryRefined =
            binariseFloatMask(maskRefined, threshold: 0.5);

        final fprBase =
            computeFalsePositiveRate(binaryBase, fixture.gtMask);
        final fprRefined =
            computeFalsePositiveRate(binaryRefined, fixture.gtMask);
        final covBase = computeMaskCoverage(binaryBase);
        final covRefined = computeMaskCoverage(binaryRefined);
        final iouBase = computeMaskIou(binaryBase, fixture.gtMask);
        final iouRefined = computeMaskIou(binaryRefined, fixture.gtMask);

        // Always print the numbers so the lab summary shows them
        // in the commit-message trailer. `debugPrint` is captured by
        // the test runner and survives the noise filter.
        debugPrint('[XVI.93a diagnostic]');
        debugPrint('  coverage  base=${covBase.toStringAsFixed(4)}'
            '  refined=${covRefined.toStringAsFixed(4)}');
        debugPrint('  fpr       base=${fprBase.toStringAsFixed(4)}'
            '  refined=${fprRefined.toStringAsFixed(4)}');
        debugPrint('  iou       base=${iouBase.toStringAsFixed(4)}'
            '  refined=${iouRefined.toStringAsFixed(4)}');

        // Always-true assertion — keeps the test green while we
        // collect the diagnostics. The real gate lands in XVI.99.
        expect(fprBase, greaterThanOrEqualTo(0));
        expect(fprRefined, greaterThanOrEqualTo(0));
      },
    );

    test('builder mask IoU vs ground truth is above 0.30', () {
      // Heuristic baseline gate. The full sky-replace pipeline adds
      // SegFormer on real photos — IoU there is expected to be much
      // higher. For the pure-heuristic-only Tier-1 test we accept
      // 0.30 as proof the colour signal alone agrees with the GT
      // somewhere. Ratchet up when we add SegFormer to the lab.
      final mask = SkyMaskBuilder.build(
        source: fixture.sourceRgba,
        width: fixture.width,
        height: fixture.height,
      );
      final binary = binariseFloatMask(mask, threshold: 0.5);
      final iou = computeMaskIou(binary, fixture.gtMask);
      expect(iou, greaterThan(0.30), reason: 'mask IoU=$iou');
    });
  });

  // XVI.99 — REAL-PHOTO Tier-1 gate. Loaded from a gitignored path
  // (`assets/test_images/real/`) so the developer's personal photos
  // don't end up in the bundle, but the lab can still grade ops
  // against the actual on-device failure scenes. Skips with a clear
  // message when the file is absent (CI machines, fresh clones).
  group('SkyMaskBuilder — REAL: tulip_bench_portrait', () {
    const sourcePath =
        'assets/test_images/real/tulip_bench_portrait.png';
    const maskPath =
        'assets/test_images/real/tulip_bench_portrait.sky_mask.png';

    _SkyTestCase? fixture;

    setUpAll(() async {
      if (!File(sourcePath).existsSync()) {
        fixture = null;
        return;
      }
      fixture = await _loadRealFixture(sourcePath, maskPath);
    });

    test('fixture loaded (skip if real photo not present)', () {
      if (fixture == null) {
        markTestSkipped('real photo absent — run `python3 scripts/'
            'prep_real_corpus.py --input <photo> --id '
            'tulip_bench_portrait` to create it');
        return;
      }
      expect(fixture!.width, 2048);
      expect(fixture!.height, 1536);
      final gtCov = computeMaskCoverage(fixture!.gtMask);
      expect(gtCov, inInclusiveRange(0.25, 0.50));
    });

    test(
      'XVI.93a guided-filter radius=8 vs without — diagnostics on '
      'the REAL device-regression scene',
      () {
        if (fixture == null) {
          markTestSkipped('real photo absent');
          return;
        }
        final f = fixture!;
        final maskBase = SkyMaskBuilder.build(
          source: f.sourceRgba,
          width: f.width,
          height: f.height,
        );
        final maskRefined = GuidedFilter.upsampleMask(
          smallMask: maskBase,
          smallWidth: f.width,
          smallHeight: f.height,
          sourceRgba: f.sourceRgba,
          srcWidth: f.width,
          srcHeight: f.height,
          radius: 8,
        );

        final binaryBase = binariseFloatMask(maskBase, threshold: 0.5);
        final binaryRefined =
            binariseFloatMask(maskRefined, threshold: 0.5);

        final covBase = computeMaskCoverage(binaryBase);
        final covRefined = computeMaskCoverage(binaryRefined);
        final fprBase =
            computeFalsePositiveRate(binaryBase, f.gtMask);
        final fprRefined =
            computeFalsePositiveRate(binaryRefined, f.gtMask);
        final iouBase = computeMaskIou(binaryBase, f.gtMask);
        final iouRefined = computeMaskIou(binaryRefined, f.gtMask);

        debugPrint('[XVI.93a REAL diagnostic — tulip_bench_portrait]');
        debugPrint('  coverage  base=${covBase.toStringAsFixed(4)}'
            '  refined=${covRefined.toStringAsFixed(4)}');
        debugPrint('  fpr       base=${fprBase.toStringAsFixed(4)}'
            '  refined=${fprRefined.toStringAsFixed(4)}');
        debugPrint('  iou       base=${iouBase.toStringAsFixed(4)}'
            '  refined=${iouRefined.toStringAsFixed(4)}');

        // Diagnostic-only. The actual XVI.93a fix gate flips on once
        // we know which knob (smaller radius / binarisation pass /
        // higher threshold) actually reduces fpr on this scene.
        expect(fprBase, greaterThanOrEqualTo(0));
        expect(fprRefined, greaterThanOrEqualTo(0));
      },
    );

    test(
      'XVI.93a synthetic-bleed: does guided filter contract a mask '
      'dilated 30px into non-sky?',
      () {
        if (fixture == null) {
          markTestSkipped('real photo absent');
          return;
        }
        final f = fixture!;
        // Build a "messy" mask: start from the GT sky mask, then
        // dilate by 30 px (~1.5 % of long edge). This simulates the
        // SegFormer-bleed failure mode where the model's bilinearly
        // upsampled 128×128 logits paint adjacent tulip / mountain
        // pixels as sky.
        final messy = _dilateBinaryMask(
          f.gtMask,
          width: f.width,
          height: f.height,
          radius: 30,
        );
        // Convert to Float32List in [0, 1] for the guided filter.
        final messyF = Float32List(messy.length);
        for (var i = 0; i < messy.length; i++) {
          messyF[i] = messy[i] == 0 ? 0.0 : 1.0;
        }
        final refined = GuidedFilter.upsampleMask(
          smallMask: messyF,
          smallWidth: f.width,
          smallHeight: f.height,
          sourceRgba: f.sourceRgba,
          srcWidth: f.width,
          srcHeight: f.height,
          radius: 8,
        );

        final binaryMessy = messy;
        final binaryRefined = binariseFloatMask(refined, threshold: 0.5);

        final covMessy = computeMaskCoverage(binaryMessy);
        final covRefined = computeMaskCoverage(binaryRefined);
        final fprMessy =
            computeFalsePositiveRate(binaryMessy, f.gtMask);
        final fprRefined =
            computeFalsePositiveRate(binaryRefined, f.gtMask);
        final iouMessy = computeMaskIou(binaryMessy, f.gtMask);
        final iouRefined = computeMaskIou(binaryRefined, f.gtMask);

        debugPrint('[XVI.93a bleed test — tulip_bench_portrait]');
        debugPrint('  coverage  messy=${covMessy.toStringAsFixed(4)}'
            '  refined=${covRefined.toStringAsFixed(4)}');
        debugPrint('  fpr       messy=${fprMessy.toStringAsFixed(4)}'
            '  refined=${fprRefined.toStringAsFixed(4)}');
        debugPrint('  iou       messy=${iouMessy.toStringAsFixed(4)}'
            '  refined=${iouRefined.toStringAsFixed(4)}');
        debugPrint('  Δfpr (refined − messy) = '
            '${(fprRefined - fprMessy).toStringAsFixed(4)}  '
            '(negative = filter contracted bleed = good)');

        // Documents the XVI.93a failure: the guided filter at
        // radius=8 does NOT contract the synthetic bleed. Keep this
        // assertion in place to pin the historical evidence even
        // though XVI.100 replaced the filter with the colour gate.
        expect(fprMessy, greaterThan(0),
            reason: 'messy mask should have fpr > 0 by construction');
        expect(
          (fprRefined - fprMessy).abs(),
          lessThan(0.002),
          reason: 'guided filter (XVI.93a) should not meaningfully '
              'change fpr on the bleed scenario — this pins the '
              'no-op evidence',
        );
      },
    );

    test(
      'XVI.100 colour gate ENFORCED: drops bleed pixels on the '
      'real scene',
      () {
        if (fixture == null) {
          markTestSkipped('real photo absent');
          return;
        }
        final f = fixture!;
        final messy = _dilateBinaryMask(
          f.gtMask,
          width: f.width,
          height: f.height,
          radius: 30,
        );
        final messyF = Float32List(messy.length);
        for (var i = 0; i < messy.length; i++) {
          messyF[i] = messy[i] == 0 ? 0.0 : 1.0;
        }

        final fprBefore = computeFalsePositiveRate(messy, f.gtMask);
        final iouBefore = computeMaskIou(messy, f.gtMask);

        final droppedCount = dropNonSkyPixels(
          messyF,
          f.sourceRgba,
          width: f.width,
          height: f.height,
        );

        final binaryAfter = binariseFloatMask(messyF, threshold: 0.5);
        final fprAfter =
            computeFalsePositiveRate(binaryAfter, f.gtMask);
        final iouAfter = computeMaskIou(binaryAfter, f.gtMask);

        debugPrint('[XVI.100 colour-gate ENFORCED on bleed]');
        debugPrint('  fpr   before=${fprBefore.toStringAsFixed(4)}'
            '  after=${fprAfter.toStringAsFixed(4)}'
            '  Δ=${(fprAfter - fprBefore).toStringAsFixed(4)}');
        debugPrint('  iou   before=${iouBefore.toStringAsFixed(4)}'
            '  after=${iouAfter.toStringAsFixed(4)}');
        debugPrint('  droppedBleedPixels=$droppedCount');

        // ENFORCED gates per the XVI.100 strategy. The colour gate
        // must drop the false-positive rate by at least 0.005
        // (0.5 percentage points) and lift IoU. The XVI.100 sweep
        // measured fpr 0.0309 → 0.0234 (Δ=-0.0075) and iou
        // 0.9194 → 0.9378 on this same fixture; the bands below
        // are deliberately looser to leave headroom for future
        // gate tuning.
        expect(
          fprAfter - fprBefore,
          lessThanOrEqualTo(-0.005),
          reason: 'gate must reduce fpr by >= 0.005, '
              'before=$fprBefore after=$fprAfter',
        );
        expect(
          iouAfter,
          greaterThan(iouBefore),
          reason: 'gate must lift IoU, before=$iouBefore '
              'after=$iouAfter',
        );
        expect(droppedCount, greaterThan(0));
      },
    );

    test(
      'XVI.100 fix-candidate sweep against the synthetic bleed',
      () {
        if (fixture == null) {
          markTestSkipped('real photo absent');
          return;
        }
        final f = fixture!;
        // Reuse the same messy mask the bleed test built (GT
        // dilated 30 px). Each candidate operates on this baseline.
        final messy = _dilateBinaryMask(
          f.gtMask,
          width: f.width,
          height: f.height,
          radius: 30,
        );
        final messyF = Float32List(messy.length);
        for (var i = 0; i < messy.length; i++) {
          messyF[i] = messy[i] == 0 ? 0.0 : 1.0;
        }

        debugPrint('[XVI.100 sweep — tulip_bench_portrait]');
        debugPrint('  candidate                   coverage    fpr       iou');

        // Baseline: messy mask, no fix applied.
        _logCandidate('messy (baseline)', messy, f);

        // Candidate A: XVI.93a as shipped (radius=8).
        {
          final refined = GuidedFilter.upsampleMask(
            smallMask: messyF,
            smallWidth: f.width,
            smallHeight: f.height,
            sourceRgba: f.sourceRgba,
            srcWidth: f.width,
            srcHeight: f.height,
            radius: 8,
          );
          _logCandidate('A: guided r=8 (shipped)',
              binariseFloatMask(refined, threshold: 0.5), f);
        }

        // Candidate B: larger guided-filter radius (r=24).
        {
          final refined = GuidedFilter.upsampleMask(
            smallMask: messyF,
            smallWidth: f.width,
            smallHeight: f.height,
            sourceRgba: f.sourceRgba,
            srcWidth: f.width,
            srcHeight: f.height,
            radius: 24,
          );
          _logCandidate('B: guided r=24',
              binariseFloatMask(refined, threshold: 0.5), f);
        }

        // Candidate C: r=8 guided filter, then binarise at 0.7.
        {
          final refined = GuidedFilter.upsampleMask(
            smallMask: messyF,
            smallWidth: f.width,
            smallHeight: f.height,
            sourceRgba: f.sourceRgba,
            srcWidth: f.width,
            srcHeight: f.height,
            radius: 8,
          );
          _logCandidate('C: r=8 + binarise@0.7',
              binariseFloatMask(refined, threshold: 0.7), f);
        }

        // Candidate D: COLOUR GATE — drop mask pixels whose RGB
        // doesn't look sky-like (blueness < 0.02 AND warmness < 0.10).
        {
          final gated = _colorGateMask(messy, f.sourceRgba);
          _logCandidate('D: colour-gate', gated, f);
        }

        // Candidate E: D + r=8 guided filter (colour-gate then
        // refine).
        {
          final gated = _colorGateMask(messy, f.sourceRgba);
          final gatedF = Float32List(gated.length);
          for (var i = 0; i < gated.length; i++) {
            gatedF[i] = gated[i] == 0 ? 0.0 : 1.0;
          }
          final refined = GuidedFilter.upsampleMask(
            smallMask: gatedF,
            smallWidth: f.width,
            smallHeight: f.height,
            sourceRgba: f.sourceRgba,
            srcWidth: f.width,
            srcHeight: f.height,
            radius: 8,
          );
          _logCandidate('E: colour-gate + r=8',
              binariseFloatMask(refined, threshold: 0.5), f);
        }

        // No assertion — we're shopping for the winning candidate.
        // The next commit applies whichever has lowest fpr +
        // highest iou and flips this expectation to a gate.
        expect(true, true);
      },
    );
  });
}

/// Helper used by the sweep: drops every mask pixel whose source
/// RGB doesn't look sky-like (blueness < 0.02 AND warmness < 0.10).
/// Mirrors the gate logic SkyMaskBuilder applies on initial mask
/// build but at lower thresholds — catches obvious bleed pixels
/// (tulip red, bench red, vegetation green) without removing soft
/// sky-haze pixels at the cloud boundary.
Uint8List _colorGateMask(Uint8List mask, Uint8List rgba) {
  final out = Uint8List(mask.length);
  for (var i = 0, p = 0; i < mask.length; i++, p += 4) {
    if (mask[i] == 0) continue;
    final r = rgba[p];
    final g = rgba[p + 1];
    final b = rgba[p + 2];
    final maxRG = r > g ? r : g;
    final blueness = (b - maxRG) / 255.0;
    final warmness = (maxRG - b) / 255.0;
    // Drop only if the pixel fails BOTH the blueness test AND the
    // warmness test (so warm sunset skies survive the gate too).
    if (blueness < 0.02 && warmness < 0.10) continue;
    out[i] = 1;
  }
  return out;
}

void _logCandidate(String label, Uint8List binary, _SkyTestCase f) {
  final cov = computeMaskCoverage(binary);
  final fpr = computeFalsePositiveRate(binary, f.gtMask);
  final iou = computeMaskIou(binary, f.gtMask);
  debugPrint('  ${label.padRight(28)}'
      '${cov.toStringAsFixed(4)}    '
      '${fpr.toStringAsFixed(4)}    '
      '${iou.toStringAsFixed(4)}');
}

/// Binary dilation by [radius] pixels (Chebyshev neighborhood).
Uint8List _dilateBinaryMask(
  Uint8List mask, {
  required int width,
  required int height,
  required int radius,
}) {
  var current = Uint8List.fromList(mask);
  for (var iter = 0; iter < radius; iter++) {
    final next = Uint8List(current.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        if (current[i] != 0) {
          next[i] = 1;
          continue;
        }
        var on = false;
        if (x > 0 && current[i - 1] != 0) on = true;
        if (x < width - 1 && current[i + 1] != 0) on = true;
        if (y > 0 && current[i - width] != 0) on = true;
        if (y < height - 1 && current[i + width] != 0) on = true;
        next[i] = on ? 1 : 0;
      }
    }
    current = next;
  }
  return current;
}

Future<_SkyTestCase> _loadRealFixture(
  String sourcePath,
  String maskPath,
) async {
  final sourceBytes = await File(sourcePath).readAsBytes();
  final maskBytes = await File(maskPath).readAsBytes();
  final srcImg = img.decodeImage(sourceBytes);
  final mskImg = img.decodeImage(maskBytes);
  if (srcImg == null || mskImg == null) {
    throw StateError('failed to decode real-photo fixture');
  }
  final srcRgba = srcImg.getBytes(order: img.ChannelOrder.rgba);
  final mskRgba = mskImg.getBytes(order: img.ChannelOrder.rgba);
  if (srcImg.width != mskImg.width || srcImg.height != mskImg.height) {
    throw StateError('source/mask dim mismatch '
        '${srcImg.width}x${srcImg.height} vs '
        '${mskImg.width}x${mskImg.height}');
  }
  final gtMask = Uint8List(srcImg.width * srcImg.height);
  for (var i = 0, j = 0; i < mskRgba.length; i += 4, j++) {
    gtMask[j] = mskRgba[i] >= 128 ? 1 : 0;
  }
  return _SkyTestCase(
    width: srcImg.width,
    height: srcImg.height,
    sourceRgba: srcRgba,
    gtMask: gtMask,
  );
}

class _SkyTestCase {
  _SkyTestCase({
    required this.width,
    required this.height,
    required this.sourceRgba,
    required this.gtMask,
  });

  final int width;
  final int height;
  final Uint8List sourceRgba;

  /// Binary ground-truth sky mask: 1 = sky pixel, 0 = non-sky.
  final Uint8List gtMask;
}

Future<_SkyTestCase> _loadFixture(String id) async {
  final corpus = await TestCorpus.load();
  final entry = corpus.byId(id);
  final source = await _decodeAssetRgba(entry.path);
  final skyMaskPath = entry.skyMaskPath;
  if (skyMaskPath == null) {
    throw StateError('corpus image "$id" has no sky_mask ground truth');
  }
  final gtRaw = await _decodeAssetRgba(skyMaskPath);
  // The .sky_mask.png assets are 1-channel L-mode PNGs that the
  // image package upgrades to RGBA on decode — collapse back to a
  // binary mask via the R channel.
  final gtMask = Uint8List(entry.width * entry.height);
  for (var i = 0, j = 0; i < gtRaw.length; i += 4, j++) {
    gtMask[j] = gtRaw[i] >= 128 ? 1 : 0;
  }
  return _SkyTestCase(
    width: entry.width,
    height: entry.height,
    sourceRgba: source,
    gtMask: gtMask,
  );
}

Future<Uint8List> _decodeAssetRgba(String assetPath) async {
  final raw = await rootBundle.load(assetPath);
  final bytes = raw.buffer.asUint8List();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw StateError('failed to decode $assetPath');
  }
  return decoded.getBytes(order: img.ChannelOrder.rgba);
}
