import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:image_editor/features/editor/data/export_history.dart';
import 'package:image_editor/features/editor/data/export_service.dart';

/// Behaviour tests for [ExportHistory]. Backed by an in-memory mock
/// SharedPreferences so tests run without a platform channel and
/// don't pollute each other.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ExportHistoryEntry sample({
    String path = '/tmp/export_1.jpg',
    ExportFormat format = ExportFormat.jpeg,
    int bytes = 1024,
    DateTime? at,
  }) {
    return ExportHistoryEntry(
      path: path,
      format: format,
      width: 1920,
      height: 1080,
      bytes: bytes,
      exportedAt: at ?? DateTime(2026, 4, 1, 12, 0),
    );
  }

  group('ExportHistory', () {
    test('list returns empty when nothing has been added', () async {
      final h = ExportHistory();
      expect(await h.list(), isEmpty);
    });

    test('add → list round-trips a single entry', () async {
      final h = ExportHistory();
      await h.add(sample());
      final all = await h.list();
      expect(all.length, 1);
      expect(all.first.path, '/tmp/export_1.jpg');
      expect(all.first.format, ExportFormat.jpeg);
      expect(all.first.bytes, 1024);
    });

    test('newest entry appears at the front', () async {
      final h = ExportHistory();
      await h.add(sample(path: '/tmp/a.jpg'));
      await h.add(sample(path: '/tmp/b.png', format: ExportFormat.png));
      final all = await h.list();
      expect(all.first.path, '/tmp/b.png');
      expect(all.last.path, '/tmp/a.jpg');
    });

    test('add caps at 20 entries (oldest fall off)', () async {
      final h = ExportHistory();
      for (int i = 0; i < 25; i++) {
        await h.add(sample(path: '/tmp/$i.jpg'));
      }
      final all = await h.list();
      expect(all.length, 20);
      // Most recent (i=24) is first; oldest kept is i=5.
      expect(all.first.path, '/tmp/24.jpg');
      expect(all.last.path, '/tmp/5.jpg');
    });

    test('remove drops the matching entry', () async {
      final h = ExportHistory();
      await h.add(sample(path: '/tmp/a.jpg'));
      await h.add(sample(path: '/tmp/b.png', format: ExportFormat.png));
      await h.remove('/tmp/a.jpg');
      final all = await h.list();
      expect(all.length, 1);
      expect(all.first.path, '/tmp/b.png');
    });

    test('remove for unknown path is a no-op', () async {
      final h = ExportHistory();
      await h.add(sample());
      await h.remove('/tmp/never_added.png');
      expect((await h.list()).length, 1);
    });

    test('clear wipes everything', () async {
      final h = ExportHistory();
      await h.add(sample(path: '/tmp/a.jpg'));
      await h.add(sample(path: '/tmp/b.jpg'));
      await h.clear();
      expect(await h.list(), isEmpty);
    });
  });

  group('ExportHistoryEntry JSON', () {
    test('toJson/fromJson round-trips every field', () {
      final entry = sample(
        path: '/tmp/x.png',
        format: ExportFormat.png,
        bytes: 4096,
        at: DateTime.utc(2026, 4, 18, 10, 30),
      );
      final json = entry.toJson();
      final back = ExportHistoryEntry.fromJson(
        Map<String, dynamic>.from(json),
      );
      expect(back, isNotNull);
      expect(back!.path, entry.path);
      expect(back.format, entry.format);
      expect(back.width, entry.width);
      expect(back.height, entry.height);
      expect(back.bytes, entry.bytes);
      expect(back.exportedAt, entry.exportedAt);
    });

    test('fromJson returns null on missing required fields', () {
      expect(
        ExportHistoryEntry.fromJson(<String, dynamic>{}),
        isNull,
      );
      expect(
        ExportHistoryEntry.fromJson(<String, dynamic>{'path': '/x'}),
        isNull,
      );
    });

    test('fromJson tolerates an unknown format string by falling back to jpeg',
        () {
      final back = ExportHistoryEntry.fromJson({
        'path': '/x',
        'format': 'avif_does_not_exist',
        'width': 1,
        'height': 1,
        'bytes': 1,
        'exportedAt': DateTime(2026).toIso8601String(),
      });
      expect(back, isNotNull);
      expect(back!.format, ExportFormat.jpeg);
    });
  });
}
