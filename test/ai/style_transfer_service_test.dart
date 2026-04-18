import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/style_transfer/style_transfer_service.dart';

/// Phase C2 scaffold: until the bundled Magenta model lands, the
/// service must throw a [StyleTransferException] with a user-facing
/// message instead of silently failing or pretending to succeed. The
/// test pins that contract so the day someone wires up the real
/// runtime they'll see this test go red and update the message.
void main() {
  group('StyleTransferService (scaffold)', () {
    test('stylize throws StyleTransferException with coaching message',
        () async {
      final svc = StyleTransferService();
      try {
        await svc.stylize(
          sourcePath: '/tmp/does_not_matter.jpg',
          preset: StylePreset.starryNight,
        );
        fail('expected StyleTransferException');
      } on StyleTransferException catch (e) {
        // The message is shown verbatim to the user via UserFeedback —
        // it must mention what's missing and where to look.
        expect(e.message, contains('not yet available'));
        expect(e.message, contains('assets/models/bundled/'));
      } finally {
        await svc.close();
      }
    });

    test('toString includes the cause when present', () {
      const e = StyleTransferException('nope', cause: 'underlying');
      expect(e.toString(), contains('StyleTransferException'));
      expect(e.toString(), contains('nope'));
      expect(e.toString(), contains('underlying'));
    });

    test('every StylePreset has a label and emoji', () {
      for (final preset in StylePreset.values) {
        expect(preset.label, isNotEmpty);
        expect(preset.emoji, isNotEmpty);
      }
    });

    test('close is idempotent and never throws', () async {
      final svc = StyleTransferService();
      await svc.close();
      await svc.close();
    });
  });
}
