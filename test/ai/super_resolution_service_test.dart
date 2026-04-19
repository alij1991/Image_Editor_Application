import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/super_resolution/super_resolution_service.dart';

/// Phase C5 scaffold: pins the contract that
/// [SuperResolutionService.upscale] throws a
/// [SuperResolutionException] with a user-facing coaching message
/// until the Real-ESRGAN runtime is wired.
void main() {
  group('SuperResolutionService (scaffold)', () {
    test('upscale throws SuperResolutionException with coaching message',
        () async {
      final svc = SuperResolutionService();
      try {
        await svc.upscale(
          sourcePath: '/tmp/anything.jpg',
          factor: SuperResolutionFactor.x4,
        );
        fail('expected SuperResolutionException');
      } on SuperResolutionException catch (e) {
        expect(e.message, contains('not yet available'));
        expect(e.message, contains('Manage AI models'));
      } finally {
        await svc.close();
      }
    });

    test('toString includes the cause when present', () {
      const e = SuperResolutionException('boom', cause: 'underlying');
      expect(e.toString(), contains('SuperResolutionException'));
      expect(e.toString(), contains('boom'));
      expect(e.toString(), contains('underlying'));
    });

    test('every SuperResolutionFactor has a label', () {
      for (final f in SuperResolutionFactor.values) {
        expect(f.label, isNotEmpty);
      }
    });

    test('close is idempotent', () async {
      final svc = SuperResolutionService();
      await svc.close();
      await svc.close();
    });
  });
}
