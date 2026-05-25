/// XVI.95a — Common types for the AI Test Lab metric library.
///
/// Each metric returns a [MetricResult] containing the numeric score,
/// the threshold used to decide pass/fail, and the verdict. The lab
/// UI maps [Verdict] to colour chips (green/amber/red) and the
/// commit-flow trailer renders the same triple as a one-line
/// summary the developer pastes into the commit message.
library;

import 'package:flutter/foundation.dart';

/// Pass/fail verdict for a single metric run.
///
/// - [pass]   — score meets or beats [Threshold.pass].
/// - [amber]  — score is within `5%` of [Threshold.pass] but on the
///   wrong side. Surfaced as a yellow chip in the lab so the user
///   notices the drift before it becomes a hard regression.
/// - [fail]   — score is worse than the amber band. The commit
///   protocol refuses commits with any [fail] for an op the change
///   touched.
enum Verdict { pass, amber, fail }

/// Threshold + comparison direction used to grade a metric.
///
/// Some metrics are "higher is better" (SSIM, PSNR, IoU, Laplacian
/// variance), others are "lower is better" (LPIPS, MSE, matting SAD).
/// [higherIsBetter] tells [MetricResult.grade] which way to compare.
///
/// `amberBandFraction` controls how close to the pass line counts as
/// amber. Default 0.05 mirrors the 5% rule in the strategy doc.
@immutable
class Threshold {
  const Threshold({
    required this.pass,
    required this.higherIsBetter,
    this.amberBandFraction = 0.05,
  }) : assert(amberBandFraction >= 0 && amberBandFraction < 1);

  /// The score required to count as [Verdict.pass].
  final double pass;

  /// `true` if higher score is better (SSIM, PSNR). `false` for
  /// metrics where smaller is better (LPIPS, MSE, SAD).
  final bool higherIsBetter;

  /// Width of the amber band as a fraction of [pass]. `0.05` means
  /// scores within ±5 % of the pass line count as amber.
  final double amberBandFraction;

  /// Decide the verdict for [score] against this threshold.
  Verdict grade(double score) {
    final delta = (score - pass) * (higherIsBetter ? 1 : -1);
    if (delta >= 0) return Verdict.pass;
    final band = pass.abs() * amberBandFraction;
    if (band > 0 && -delta <= band) return Verdict.amber;
    return Verdict.fail;
  }
}

/// Result of running a single metric on a single op output.
@immutable
class MetricResult {
  const MetricResult({
    required this.metricName,
    required this.score,
    required this.threshold,
    required this.verdict,
    this.notes,
  });

  /// Short human-readable metric name (`"SSIM"`, `"BoundaryIoU"`).
  final String metricName;

  /// Numeric score produced by the metric.
  final double score;

  /// Threshold the score was graded against. May be `null` for raw
  /// reference-free measurements where the lab is recording but not
  /// gating.
  final Threshold? threshold;

  /// Pass/amber/fail verdict from [Threshold.grade].
  final Verdict verdict;

  /// Optional free-form note (e.g. `"trimap unknown region"`).
  final String? notes;

  /// One-line summary for commit-message `Lab:` trailers.
  String toTrailerLine() {
    final tag = switch (verdict) {
      Verdict.pass => 'PASS',
      Verdict.amber => 'AMBER',
      Verdict.fail => 'FAIL',
    };
    final threshStr = threshold == null
        ? ''
        : ' (${threshold!.higherIsBetter ? '>=' : '<='} '
            '${threshold!.pass.toStringAsFixed(3)})';
    final notesStr = notes == null ? '' : '  // $notes';
    return '$tag  $metricName=${score.toStringAsFixed(3)}$threshStr$notesStr';
  }

  /// Build a result by grading [score] against [threshold]. Convenience
  /// for the common case where the caller just wants the verdict
  /// derived automatically.
  factory MetricResult.grade({
    required String metricName,
    required double score,
    required Threshold threshold,
    String? notes,
  }) {
    return MetricResult(
      metricName: metricName,
      score: score,
      threshold: threshold,
      verdict: threshold.grade(score),
      notes: notes,
    );
  }
}
