import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_manifest.dart';
import 'package:image_editor/bootstrap.dart';
import 'package:image_editor/di/providers.dart';
import 'package:image_editor/features/settings/presentation/widgets/model_manager_sheet.dart';

import 'test_support/fake_bootstrap.dart';

/// Tests for Phase I.10 — the bootstrap visible-degradation banner.
///
/// Two seams are exercised:
///
///   1. [detectManifestDegradation] — pure helper, tested in
///      isolation so the full bootstrap (memory probe, model runtimes,
///      shader preload) doesn't have to spin up.
///
///   2. [ModelManagerSheet] — widget test confirming a banner is
///      rendered when the degradation provider returns non-null, and
///      absent when it returns null. The banner text mirrors the
///      degradation message so the UX is tied to the reason.
void main() {
  group('detectManifestDegradation', () {
    test('returns null for a healthy manifest with descriptors', () {
      final manifest = ModelManifest([
        const ModelDescriptor(
          id: 'bundled-a',
          version: '1.0',
          runtime: ModelRuntime.litert,
          sizeBytes: 1024,
          sha256: '',
          bundled: true,
          assetPath: 'assets/models/bundled/a.tflite',
        ),
      ]);
      expect(detectManifestDegradation(manifest), isNull);
    });

    test('flags an empty manifest', () {
      final manifest = ModelManifest(const []);
      final reason = detectManifestDegradation(manifest);
      expect(reason, isNotNull);
      expect(reason!.reason, DegradationReason.manifestEmpty);
      expect(reason.message, contains('manifest'));
    });

    test('flags a load error regardless of whether manifest is empty', () {
      final manifest = ModelManifest([
        const ModelDescriptor(
          id: 'x',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: 10,
          sha256: '',
          bundled: false,
        ),
      ]);
      final reason = detectManifestDegradation(
        manifest,
        loadError: Exception('asset bundle unavailable'),
      );
      expect(reason, isNotNull);
      expect(reason!.reason, DegradationReason.manifestLoadFailed);
      expect(reason.message, contains('could not be read'));
    });

    test('load error supersedes empty-manifest reason', () {
      // If both conditions hold, the load error is the more specific
      // signal — the empty manifest is a CONSEQUENCE of the load
      // failure, not an independent shipping issue.
      final manifest = ModelManifest(const []);
      final reason = detectManifestDegradation(
        manifest,
        loadError: Exception('rootBundle threw'),
      );
      expect(reason!.reason, DegradationReason.manifestLoadFailed);
    });
  });

  group('ModelManagerSheet degradation banner', () {
    testWidgets('shows the warning banner when degradation is non-null',
        (tester) async {
      final fake = buildFakeBootstrap(
        degradation: const BootstrapDegradation(
          reason: DegradationReason.manifestLoadFailed,
          message: 'mock-reason-for-test',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapResultProvider.overrideWithValue(fake)],
          child: const MaterialApp(
            home: Scaffold(body: ModelManagerSheet()),
          ),
        ),
      );
      // Let the _load()'s setState land so we're past the spinner.
      await tester.pump();

      expect(
        find.byKey(const Key('model-manager.degradation-banner')),
        findsOneWidget,
        reason: 'banner must be visible when degradation is flagged',
      );
      expect(find.text('AI features are unavailable'), findsOneWidget);
      expect(find.text('mock-reason-for-test'), findsOneWidget,
          reason: 'banner text should mirror the degradation message so '
              'the cause is visible, not generic');
    });

    testWidgets('banner is absent for a healthy bootstrap', (tester) async {
      // Use a manifest with one bundled descriptor so `detect` returns
      // null — but we're injecting the degradation directly anyway,
      // and leaving it null here is the health signal.
      final fake = buildFakeBootstrap(
        manifest: ModelManifest([
          const ModelDescriptor(
            id: 'healthy-bundled',
            version: '1.0',
            runtime: ModelRuntime.litert,
            sizeBytes: 1024,
            sha256: '',
            bundled: true,
            assetPath: 'assets/models/bundled/x.tflite',
          ),
        ]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapResultProvider.overrideWithValue(fake)],
          child: const MaterialApp(
            home: Scaffold(body: ModelManagerSheet()),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('model-manager.degradation-banner')),
        findsNothing,
        reason: 'healthy bootstrap must not show the banner',
      );
      expect(find.text('AI features are unavailable'), findsNothing);
    });
  });
}
