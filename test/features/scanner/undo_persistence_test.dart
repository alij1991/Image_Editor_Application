import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/features/scanner/data/scan_repository.dart';
import 'package:image_editor/features/scanner/domain/models/scan_models.dart';

/// VIII.16 — undo stack survives a save → load round-trip via the
/// scan repository. Bounded at [kPersistedUndoDepth] entries.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('undo_persistence');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ScanSession session(String id, {String? title}) {
    final raw = File('${tmp.path}/raw_$id.jpg')
      ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
    return ScanSession(
      id: id,
      title: title,
      pages: [ScanPage(id: 'p-$id', rawImagePath: raw.path)],
    );
  }

  test('kPersistedUndoDepth is 5', () {
    expect(kPersistedUndoDepth, 5);
  });

  test('save without undoStack omits the field; load returns empty stack',
      () async {
    final repo = ScanRepository(rootOverride: tmp);
    final s = session('s1');
    await repo.save(s);
    final result = await repo.loadWithUndo('s1');
    expect(result, isNotNull);
    expect(result!.session.id, 's1');
    expect(result.undoStack, isEmpty);
  });

  test('save with undoStack persists every entry up to the cap',
      () async {
    final repo = ScanRepository(rootOverride: tmp);
    final stack = [
      session('s1', title: 'undo-1'),
      session('s1', title: 'undo-2'),
      session('s1', title: 'undo-3'),
    ];
    await repo.save(session('s1', title: 'current'), undoStack: stack);
    final result = await repo.loadWithUndo('s1');
    expect(result, isNotNull);
    expect(result!.session.title, 'current');
    expect(result.undoStack.length, 3);
    expect(result.undoStack[0].title, 'undo-1');
    expect(result.undoStack[2].title, 'undo-3');
  });

  test('save truncates undo stack to the last kPersistedUndoDepth entries',
      () async {
    final repo = ScanRepository(rootOverride: tmp);
    final stack = [
      for (var i = 0; i < 10; i++) session('s1', title: 'u$i'),
    ];
    await repo.save(session('s1', title: 'current'), undoStack: stack);
    final result = await repo.loadWithUndo('s1');
    expect(result!.undoStack.length, kPersistedUndoDepth);
    // Truncation keeps the TAIL (most recent entries).
    expect(result.undoStack[0].title, 'u5');
    expect(result.undoStack[4].title, 'u9');
  });

  test('loadWithUndo returns null for a missing session', () async {
    final repo = ScanRepository(rootOverride: tmp);
    expect(await repo.loadWithUndo('does-not-exist'), isNull);
  });

  test('legacy file without undoStack key still loads with empty stack',
      () async {
    final repo = ScanRepository(rootOverride: tmp);
    // Write a file in the older shape (no undoStack key).
    final s = session('legacy');
    await repo.save(s); // pre-VIII.16 shape (no undoStack arg)
    final result = await repo.loadWithUndo('legacy');
    expect(result!.undoStack, isEmpty);
  });
}
