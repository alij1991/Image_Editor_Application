import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/bg_removal/bg_removal_strategy.dart';
import 'package:image_editor/ai/services/bg_removal/u2netp_bg_removal.dart';

/// VIII.12 — `U2NetBgRemoval` is wired as the fourth bg-removal
/// strategy. Until `assets/models/bundled/u2netp.tflite` is shipped
/// in the repo, the strategy throws a typed exception with a
/// model-status message instead of crashing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('kind is generalOffline', () {
    expect(U2NetBgRemoval().kind, BgRemovalStrategyKind.generalOffline);
  });

  test('label + description surface offline framing', () {
    expect(BgRemovalStrategyKind.generalOffline.label,
        contains('Offline'));
    expect(BgRemovalStrategyKind.generalOffline.description,
        contains('U²-Netp'));
  });

  test('isDownloadable is false (bundled, not downloaded)', () {
    expect(BgRemovalStrategyKind.generalOffline.isDownloadable, isFalse);
  });

  test('modelId references the bundled u2netp manifest entry', () {
    expect(BgRemovalStrategyKind.generalOffline.modelId, 'u2netp');
  });

  test('isModelAvailable returns false for a missing asset path',
      () async {
    final strat = U2NetBgRemoval(
      assetPath: 'assets/missing/never_present.tflite',
    );
    expect(await strat.isModelAvailable(), isFalse);
    await strat.close();
  });

  test('removeBackgroundFromPath throws typed exception when not bundled',
      () async {
    final strat = U2NetBgRemoval(
      assetPath: 'assets/missing/never_present.tflite',
    );
    expect(
      () => strat.removeBackgroundFromPath('/tmp/anything.jpg'),
      throwsA(
        isA<BgRemovalException>()
            .having((e) => e.kind, 'kind',
                BgRemovalStrategyKind.generalOffline)
            .having((e) => e.message, 'message',
                contains('not bundled')),
      ),
    );
    await strat.close();
  });

  test('post-close calls throw a closed exception', () async {
    final strat = U2NetBgRemoval();
    await strat.close();
    expect(
      () => strat.removeBackgroundFromPath('/tmp/x.jpg'),
      throwsA(
        isA<BgRemovalException>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
  });

  test('double close is idempotent', () async {
    final strat = U2NetBgRemoval();
    await strat.close();
    await strat.close(); // must not throw
  });
}
