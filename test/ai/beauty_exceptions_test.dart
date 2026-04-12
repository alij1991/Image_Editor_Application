import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/services/face_detect/face_detection_service.dart';
import 'package:image_editor/ai/services/portrait_beauty/eye_brighten_service.dart';
import 'package:image_editor/ai/services/portrait_beauty/face_reshape_service.dart';
import 'package:image_editor/ai/services/portrait_beauty/portrait_smooth_service.dart';
import 'package:image_editor/ai/services/portrait_beauty/teeth_whiten_service.dart';
import 'package:image_editor/ai/services/sky_replace/sky_replace_service.dart';

/// Post-audit invariants for Phase 9d/9e exception types. The 9c
/// audit added a `cause` field to `BgRemovalException` so session
/// logs could retain the full failure chain when one layer
/// rewrapped another — this test file makes sure every beauty
/// exception type exposes the same contract.
void main() {
  group('FaceDetectionException', () {
    test('toString without cause', () {
      const e = FaceDetectionException('boom');
      expect(e.toString(), 'FaceDetectionException: boom');
      expect(e.cause, isNull);
    });

    test('toString with cause', () {
      const e = FaceDetectionException('boom', cause: 'underlying');
      expect(e.toString(), contains('boom'));
      expect(e.toString(), contains('caused by underlying'));
      expect(e.cause, 'underlying');
    });
  });

  group('PortraitSmoothException', () {
    test('toString without cause', () {
      const e = PortraitSmoothException('no face');
      expect(e.toString(), 'PortraitSmoothException: no face');
      expect(e.cause, isNull);
    });

    test('toString with cause', () {
      const underlying = FaceDetectionException('ML Kit failed');
      const e = PortraitSmoothException(
        'Face detection failed: ML Kit failed',
        cause: underlying,
      );
      expect(e.toString(), contains('Face detection failed'));
      expect(e.toString(), contains('caused by'));
      expect(e.cause, same(underlying));
    });
  });

  group('EyeBrightenException', () {
    test('toString without cause', () {
      const e = EyeBrightenException('no eyes');
      expect(e.toString(), 'EyeBrightenException: no eyes');
      expect(e.cause, isNull);
    });

    test('toString with cause preserves the chain', () {
      const underlying = FaceDetectionException('ML Kit failed');
      const e = EyeBrightenException(
        'Face detection failed: ML Kit failed',
        cause: underlying,
      );
      expect(e.toString(), contains('caused by'));
      expect(e.cause, same(underlying));
    });
  });

  group('TeethWhitenException', () {
    test('toString without cause', () {
      const e = TeethWhitenException('no mouth');
      expect(e.toString(), 'TeethWhitenException: no mouth');
      expect(e.cause, isNull);
    });

    test('toString with cause preserves the chain', () {
      const underlying = FaceDetectionException('ML Kit failed');
      const e = TeethWhitenException(
        'Face detection failed: ML Kit failed',
        cause: underlying,
      );
      expect(e.toString(), contains('caused by'));
      expect(e.cause, same(underlying));
    });
  });

  group('FaceReshapeException', () {
    test('toString without cause', () {
      const e = FaceReshapeException('no contours');
      expect(e.toString(), 'FaceReshapeException: no contours');
      expect(e.cause, isNull);
    });

    test('toString with cause preserves the chain', () {
      const underlying = FaceDetectionException('ML Kit failed');
      const e = FaceReshapeException(
        'Face detection failed: ML Kit failed',
        cause: underlying,
      );
      expect(e.toString(), contains('caused by'));
      expect(e.cause, same(underlying));
    });
  });

  group('SkyReplaceException', () {
    test('toString without cause', () {
      const e = SkyReplaceException('no sky');
      expect(e.toString(), 'SkyReplaceException: no sky');
      expect(e.cause, isNull);
    });

    test('toString with cause preserves the chain', () {
      // Phase 9g only wraps IO / unknown errors, not face
      // detection, so simulate with a plain string cause.
      const e = SkyReplaceException(
        'IO failure',
        cause: 'file not found',
      );
      expect(e.toString(), contains('caused by'));
      expect(e.cause, 'file not found');
    });
  });

  group('every beauty exception is a const-constructable Exception', () {
    // Guard against a future refactor accidentally breaking the
    // const-constructor pattern — session code uses `throw const
    // XxxException(...)` in a few places and would break silently.
    test('const construction works for every type', () {
      expect(
        () => const FaceDetectionException('x'),
        returnsNormally,
      );
      expect(
        () => const PortraitSmoothException('x'),
        returnsNormally,
      );
      expect(
        () => const EyeBrightenException('x'),
        returnsNormally,
      );
      expect(
        () => const TeethWhitenException('x'),
        returnsNormally,
      );
      expect(
        () => const FaceReshapeException('x'),
        returnsNormally,
      );
      expect(
        () => const SkyReplaceException('x'),
        returnsNormally,
      );
    });

    test('all implement Exception', () {
      expect(const FaceDetectionException('x'), isA<Exception>());
      expect(const PortraitSmoothException('x'), isA<Exception>());
      expect(const EyeBrightenException('x'), isA<Exception>());
      expect(const TeethWhitenException('x'), isA<Exception>());
      expect(const FaceReshapeException('x'), isA<Exception>());
      expect(const SkyReplaceException('x'), isA<Exception>());
    });
  });
}
