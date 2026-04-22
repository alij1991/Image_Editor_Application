import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:image_editor/features/scanner/infrastructure/native_document_detector.dart';

/// IX.B.2 — `NativeScannerPermissionException.requiresSettings` must
/// be true for `permanentlyDenied` and `restricted`, false otherwise.
/// This is what drives the capture page's "Open Settings" CTA — a
/// regression would either show the button when a retry would work,
/// or hide it when the system dialog is blocked.
void main() {
  group('NativeScannerPermissionException.requiresSettings', () {
    test('permanentlyDenied → requiresSettings == true', () {
      const e = NativeScannerPermissionException(
        PermissionStatus.permanentlyDenied,
      );
      expect(e.requiresSettings, isTrue);
    });

    test('restricted → requiresSettings == true', () {
      const e = NativeScannerPermissionException(
        PermissionStatus.restricted,
      );
      expect(e.requiresSettings, isTrue);
    });

    test('denied → requiresSettings == false (retry can still prompt)', () {
      const e = NativeScannerPermissionException(PermissionStatus.denied);
      expect(e.requiresSettings, isFalse);
    });

    test('granted → requiresSettings == false', () {
      const e = NativeScannerPermissionException(PermissionStatus.granted);
      expect(e.requiresSettings, isFalse);
    });

    test('limited / provisional → requiresSettings == false', () {
      expect(
        const NativeScannerPermissionException(PermissionStatus.limited)
            .requiresSettings,
        isFalse,
      );
      expect(
        const NativeScannerPermissionException(
          PermissionStatus.provisional,
        ).requiresSettings,
        isFalse,
      );
    });
  });

  group('NativeScannerPermissionException.message', () {
    test('permanentlyDenied wording points to Settings', () {
      const e = NativeScannerPermissionException(
        PermissionStatus.permanentlyDenied,
      );
      expect(e.message, contains('Settings'));
      expect(e.message, contains('blocked'));
    });

    test('denied wording is retry-oriented, does not mention Settings', () {
      const e = NativeScannerPermissionException(PermissionStatus.denied);
      expect(e.message, isNot(contains('Settings')));
      expect(e.message, contains('Camera permission'));
    });

    test('toString includes the status name + message', () {
      const e = NativeScannerPermissionException(
        PermissionStatus.permanentlyDenied,
      );
      final s = e.toString();
      expect(s, contains('permanentlyDenied'));
      expect(s, contains('Settings'));
    });
  });
}
