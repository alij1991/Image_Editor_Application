import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/history_manager.dart';
import 'package:image_editor/engine/history/memento_store.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

/// IX.C.3 — AI op round-trip: execute a destructive AI op with a
/// memento snapshot of the pre-op pixels, then undo and verify the
/// bytes come back byte-for-byte. Complements IX.B.5 (missing-
/// memento fallback) by pinning the happy path.
///
/// Drives `HistoryManager` + `MementoStore` directly — doesn't stand
/// up a full EditorSession since that requires render infra.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List bytes(int n, int fill) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  EditOperation aiOp({required String layerId}) =>
      EditOperation.create(
        type: EditOpType.aiBackgroundRemoval,
        parameters: {'layerId': layerId},
      );

  test('undo after an AI op returns to beforePipeline + memento bytes'
      ' are still readable', () async {
    final store = MementoStore(ramRingCapacity: 4);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
    );

    // Pre-op pixels (simulated) — the memento captures these BEFORE
    // the AI op runs so undo can restore them.
    final preOpBytes = bytes(16, 0x7F);
    final preOpMemento = await store.store(
      opId: 'bg-remove',
      width: 4,
      height: 4,
      bytes: preOpBytes,
    );

    final before = history.currentPipeline;
    final op = aiOp(layerId: 'cutout-1');
    final after = before.append(op);
    history.execute(
      op: op,
      newPipeline: after,
      beforeMementoId: preOpMemento.id,
    );

    expect(history.currentPipeline, after);
    expect(history.canUndo, isTrue);

    // Undo → pipeline pops back.
    expect(history.undo(), isTrue);
    expect(history.currentPipeline, before);
    expect(history.canRedo, isTrue);

    // The memento MUST still be readable — the renderer uses it to
    // restore the pixels without re-running the AI inference.
    final restored = store.lookup(preOpMemento.id);
    expect(restored, isNotNull,
        reason: 'memento must survive an undo for the renderer to '
            'restore the pre-op pixels');
    final readBack = await restored!.readBytes();
    expect(readBack, preOpBytes,
        reason: 'bytes on undo must equal bytes stored pre-op');
  });

  test('redo after undo re-applies the op + afterMementoId persists',
      () async {
    final store = MementoStore(ramRingCapacity: 4);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
    );

    final beforeBytes = bytes(8, 0x10);
    final afterBytes = bytes(8, 0x90);
    final beforeMem = await store.store(
        opId: 'm-before', width: 2, height: 2, bytes: beforeBytes);
    final afterMem = await store.store(
        opId: 'm-after', width: 2, height: 2, bytes: afterBytes);

    final op = aiOp(layerId: 'cutout-1');
    final before = history.currentPipeline;
    final after = before.append(op);
    history.execute(
      op: op,
      newPipeline: after,
      beforeMementoId: beforeMem.id,
      afterMementoId: afterMem.id,
    );

    history.undo();
    expect(history.currentPipeline, before);
    expect(await store.lookup(beforeMem.id)!.readBytes(), beforeBytes);

    history.redo();
    expect(history.currentPipeline, after);
    // After-memento must still be readable post-redo; the renderer
    // picks it up to restore the post-op pixels without re-running
    // the AI.
    final postRedo = store.lookup(afterMem.id);
    expect(postRedo, isNotNull);
    expect(await postRedo!.readBytes(), afterBytes);
  });

  test('multi-op chain: [brightness, AI, contrast] — full undo back to '
      'initial preserves every memento along the way', () async {
    final store = MementoStore(ramRingCapacity: 8);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
    );

    final aiMemento = await store.store(
      opId: 'ai-preop',
      width: 4,
      height: 4,
      bytes: bytes(16, 0x42),
    );

    final brightness = EditOperation.create(
      type: EditOpType.brightness,
      parameters: {'value': 0.2},
    );
    final p1 = history.currentPipeline.append(brightness);
    history.execute(op: brightness, newPipeline: p1);

    final ai = aiOp(layerId: 'layer');
    final p2 = p1.append(ai);
    history.execute(
      op: ai,
      newPipeline: p2,
      beforeMementoId: aiMemento.id,
    );

    final contrast = EditOperation.create(
      type: EditOpType.contrast,
      parameters: {'value': 0.1},
    );
    final p3 = p2.append(contrast);
    history.execute(op: contrast, newPipeline: p3);

    // Full undo chain.
    expect(history.undo(), isTrue);
    expect(history.currentPipeline, p2);
    expect(history.undo(), isTrue);
    expect(history.currentPipeline, p1);
    expect(history.undo(), isTrue);
    expect(history.currentPipeline.operations, isEmpty);

    // AI memento still readable — required so a redo-forward can
    // re-render the AI step without re-running inference.
    final m = store.lookup(aiMemento.id);
    expect(m, isNotNull);
    expect(await m!.readBytes(), bytes(16, 0x42));
  });

  test('execute past history limit: oldest entry + memento are dropped',
      () async {
    final store = MementoStore(ramRingCapacity: 8);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
      historyLimit: 3,
    );

    final mementos = <String>[];
    for (var i = 0; i < 5; i++) {
      final m = await store.store(
        opId: 'op$i',
        width: 1,
        height: 1,
        bytes: bytes(4, i),
      );
      mementos.add(m.id);
      final op = aiOp(layerId: 'op$i');
      final next = history.currentPipeline.append(op);
      history.execute(
        op: op,
        newPipeline: next,
        beforeMementoId: m.id,
      );
    }
    // The history limit clips to 3, so entries 0 and 1 got dropped
    // — and their mementos with them.
    expect(history.entryCount, 3);
    expect(store.lookup(mementos[0]), isNull,
        reason: 'dropped entry\'s memento should have been dropped too');
    expect(store.lookup(mementos[1]), isNull);
    expect(store.lookup(mementos[2]), isNotNull);
    expect(store.lookup(mementos[4]), isNotNull);
  });
}
