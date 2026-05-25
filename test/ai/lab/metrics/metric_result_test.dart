import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/lab/metrics/metric_result.dart';

void main() {
  group('Threshold.grade — higher is better', () {
    const t = Threshold(pass: 0.85, higherIsBetter: true);

    test('above the pass line → pass', () {
      expect(t.grade(0.90), Verdict.pass);
      expect(t.grade(0.85), Verdict.pass);
    });

    test('inside the 5% amber band → amber', () {
      // 5% of 0.85 = 0.0425, so [0.8075, 0.85) is amber.
      expect(t.grade(0.84), Verdict.amber);
      expect(t.grade(0.81), Verdict.amber);
    });

    test('beyond the amber band → fail', () {
      expect(t.grade(0.80), Verdict.fail);
      expect(t.grade(0.5), Verdict.fail);
    });
  });

  group('Threshold.grade — lower is better', () {
    const t = Threshold(pass: 0.30, higherIsBetter: false);

    test('below the pass line → pass', () {
      expect(t.grade(0.25), Verdict.pass);
      expect(t.grade(0.30), Verdict.pass);
    });

    test('inside the amber band → amber', () {
      expect(t.grade(0.31), Verdict.amber);
      // 5% of 0.30 = 0.015 → up to 0.315 is amber.
    });

    test('beyond the amber band → fail', () {
      expect(t.grade(0.40), Verdict.fail);
    });
  });

  group('Threshold.grade — custom amber band', () {
    const t = Threshold(
      pass: 1.0,
      higherIsBetter: true,
      amberBandFraction: 0.20,
    );

    test('within 20% band counts as amber', () {
      expect(t.grade(0.95), Verdict.amber);
      expect(t.grade(0.81), Verdict.amber);
      expect(t.grade(0.79), Verdict.fail);
    });
  });

  group('MetricResult', () {
    test('toTrailerLine renders pass with threshold + name', () {
      final r = MetricResult.grade(
        metricName: 'SSIM',
        score: 0.972,
        threshold: const Threshold(pass: 0.95, higherIsBetter: true),
      );
      expect(r.verdict, Verdict.pass);
      expect(r.toTrailerLine(), contains('PASS'));
      expect(r.toTrailerLine(), contains('SSIM=0.972'));
      expect(r.toTrailerLine(), contains('>= 0.950'));
    });

    test('toTrailerLine renders fail + notes', () {
      final r = MetricResult.grade(
        metricName: 'BoundaryIoU',
        score: 0.40,
        threshold: const Threshold(pass: 0.70, higherIsBetter: true),
        notes: 'portrait_clean_01.png',
      );
      expect(r.verdict, Verdict.fail);
      final line = r.toTrailerLine();
      expect(line, contains('FAIL'));
      expect(line, contains('portrait_clean_01.png'));
    });

    test('toTrailerLine handles thresholdless metric', () {
      const r = MetricResult(
        metricName: 'LapVar',
        score: 142.5,
        threshold: null,
        verdict: Verdict.pass,
      );
      final line = r.toTrailerLine();
      expect(line, contains('LapVar=142.500'));
      expect(line, isNot(contains('>=')));
      expect(line, isNot(contains('<=')));
    });
  });
}
