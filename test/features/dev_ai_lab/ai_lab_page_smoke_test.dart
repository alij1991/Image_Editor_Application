import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/dev_ai_lab/presentation/lab_op_catalogue.dart';
import 'package:image_editor/features/dev_ai_lab/presentation/pages/ai_lab_page.dart';

void main() {
  // Lab page widget tests are intentionally narrow. The loaded
  // state goes through Image.memory decodes that are flaky to time
  // inside pumpAndSettle, and the corpus↔catalogue cross-check
  // needs `rootBundle` against the test asset map (which is set up
  // in a sibling test file). End-to-end render coverage will land
  // in the lab's integration_test alongside Deliverable D.
  group('AiLabPage smoke', () {
    testWidgets('renders a progress indicator while corpus loads',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AiLabPage()),
      );
      // First frame: corpus future hasn't resolved → spinner +
      // app-bar title.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('AI Test Lab'), findsOneWidget);
    });
  });

  group('LabOp catalogue', () {
    test('every op id is unique', () {
      final ids = kLabOps.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length,
          reason: 'duplicate op id in kLabOps: $ids');
    });

    test('labOpById round-trips for every op', () {
      for (final op in kLabOps) {
        expect(labOpById(op.id), same(op));
      }
      expect(labOpById('not_a_real_op'), isNull);
    });

    test('every op has non-empty label, description, primaryMetric',
        () {
      for (final op in kLabOps) {
        expect(op.id, isNotEmpty, reason: 'id empty: ${op.label}');
        expect(op.label, isNotEmpty, reason: 'label empty: ${op.id}');
        expect(op.description, isNotEmpty,
            reason: 'description empty: ${op.id}');
        expect(op.primaryMetric, isNotEmpty,
            reason: 'primaryMetric empty: ${op.id}');
      }
    });

    test('catalogue covers the ops the corpus mentions', () {
      // Hard-coded mirror of the manifest's expectedOps set so the
      // check is fast and doesn't need rootBundle. Bumped when the
      // manifest grows (see scripts/generate_test_corpus.py).
      const corpusExpectedOps = <String>{
        'bg_removal',
        'face_restore',
        'compose_on_bg',
        'sky_replace',
        'smart_crop',
        'reduce_noise_identity',
        'reduce_noise_recovery',
        'deblur_identity',
        'deblur_recovery',
        'mobile_sam_tap',
        'inpaint',
      };
      for (final id in corpusExpectedOps) {
        expect(
          labOpById(id),
          isNotNull,
          reason: 'kLabOps missing entry for corpus op id "$id"',
        );
      }
    });
  });
}
