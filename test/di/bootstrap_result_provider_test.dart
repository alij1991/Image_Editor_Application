import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/di/providers.dart';

/// IX.B.1 — `bootstrapResultProvider` is a "must be overridden"
/// sentinel. Reading it without an override MUST throw, otherwise a
/// forgotten `overrideWithValue` would silently produce an empty /
/// null-populated bootstrap graph and trip AI features downstream
/// with misleading errors.
///
/// The error message must mention "bootstrap" so a developer hitting
/// it in a test can trace the fix quickly.
void main() {
  test('reading the provider without an override throws', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      () => container.read(bootstrapResultProvider),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('error message mentions the override requirement', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    try {
      container.read(bootstrapResultProvider);
      fail('should have thrown');
    } on UnimplementedError catch (e) {
      final msg = e.message ?? '';
      expect(msg, contains('bootstrap'),
          reason: 'error must mention bootstrap so devs can trace it');
      expect(msg.toLowerCase(), contains('override'),
          reason: 'error must explain how to fix it — override the '
              'provider at startup or via a test override');
    }
  });

  test('dependent providers (memoryBudget) also throw until override lands',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Riverpod propagates the UnimplementedError up through any
    // provider that watches bootstrapResultProvider.
    expect(
      () => container.read(memoryBudgetProvider),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
