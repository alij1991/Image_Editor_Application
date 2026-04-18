import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/inpaint/inpaint_service.dart';

/// Phase C5 scaffold: pin the contract that [InpaintService.inpaint]
/// throws an [InpaintException] with a user-facing coaching message
/// until the LaMa ONNX runtime is wired. The day someone implements
/// the real path this test will go red and prompt them to update the
/// message (or remove the test).
void main() {
  group('InpaintService (scaffold)', () {
    test('inpaint throws InpaintException with coaching message', () async {
      final svc = InpaintService();
      try {
        await svc.inpaint(
          sourcePath: '/tmp/anything.jpg',
          maskPng: Uint8List.fromList([1, 2, 3]),
        );
        fail('expected InpaintException');
      } on InpaintException catch (e) {
        expect(e.message, contains('not yet available'));
        expect(e.message, contains('Manage AI models'));
      } finally {
        await svc.close();
      }
    });

    test('toString includes the cause when present', () {
      const e = InpaintException('boom', cause: 'underlying');
      expect(e.toString(), contains('InpaintException'));
      expect(e.toString(), contains('boom'));
      expect(e.toString(), contains('underlying'));
    });

    test('close is idempotent', () async {
      final svc = InpaintService();
      await svc.close();
      await svc.close();
    });
  });
}
