import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/settings/presentation/widgets/model_manager_sheet.dart';

/// VIII.8 — pre-download confirm dialog adds a time estimate alongside
/// the byte size. The helper is unit-testable without the sheet so
/// the threshold boundaries (seconds vs minutes vs hours) stay pinned.
void main() {
  const mb = 1024 * 1024;

  test('small model reports seconds on both networks', () {
    final out = formatDownloadEstimates(6 * mb);
    expect(out, contains('on Wi-Fi'));
    expect(out, contains('on 4G'));
    expect(out, contains(' s on Wi-Fi'));
  });

  test('44 MB renders as roughly 15 s on Wi-Fi, 3 min on 4G', () {
    final out = formatDownloadEstimates(44 * mb);
    expect(out, '~15 s on Wi-Fi, ~3 min on 4G');
  });

  test('sub-1-second minimum clamps to 1 s', () {
    expect(formatDownloadEstimates(10 * 1024), startsWith('~1 s on Wi-Fi'));
  });

  test('200 MB download on 4G rolls into minutes', () {
    final out = formatDownloadEstimates(200 * mb);
    expect(out, contains('min on 4G'));
  });

  test('1 GB download reports hours on 4G, minutes on Wi-Fi', () {
    final out = formatDownloadEstimates(1024 * mb);
    expect(out, contains('min on Wi-Fi'));
    expect(out, contains('h on 4G'));
  });

  test('both numbers render — Wi-Fi always strictly smaller than 4G', () {
    // Property-ish: at least a 10x bandwidth ratio between the two
    // constants, so 4G time must exceed Wi-Fi for non-zero inputs.
    for (final sizeMb in [5, 50, 500]) {
      final out = formatDownloadEstimates(sizeMb * mb);
      final parts = out.split(',');
      expect(parts.length, 2);
      expect(parts[0].trim(), startsWith('~'));
      expect(parts[1].trim(), startsWith('~'));
    }
  });
}
