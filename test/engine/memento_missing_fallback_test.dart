import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/history/history_manager.dart';
import 'package:image_editor/engine/history/memento_store.dart';
import 'package:image_editor/engine/pipeline/edit_op_type.dart';
import 'package:image_editor/engine/pipeline/edit_operation.dart';
import 'package:image_editor/engine/pipeline/edit_pipeline.dart';

/// IX.B.5 — "undo via re-render" fallback.
///
/// When a memento is evicted (e.g. disk budget pushed it out) but the
/// HistoryEntry still references it, undo must succeed by swapping to
/// `beforePipeline` without reading the memento. The renderer downstream
/// re-runs the parametric chain to regenerate the pre-op state.
///
/// Asserted only in comments pre-IX.B.5. This test pins the contract
/// via the history manager directly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List bytes(int n, [int fill = 0xAA]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  EditOperation aiOp() => EditOperation.create(
        type: EditOpType.aiBackgroundRemoval,
        parameters: {'layerId': 'cutout-1'},
      );

  test('undo succeeds even when afterMementoId no longer resolves',
      () async {
    final store = MementoStore(ramRingCapacity: 4);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
    );

    // Store a memento, then evict it (simulating disk-budget eviction
    // past the ring size).
    final memento = await store.store(
      opId: 'op-ai',
      width: 1,
      height: 1,
      bytes: bytes(4),
    );
    await store.drop(memento.id);
    expect(store.lookup(memento.id), isNull,
        reason: 'sanity — memento is gone before we attempt undo');

    final before = history.currentPipeline;
    final op = aiOp();
    final after = before.append(op);
    history.execute(
      op: op,
      newPipeline: after,
      afterMementoId: memento.id, // dangling id — lookup will fail
    );
    expect(history.currentPipeline, after);

    // The crux: undo must NOT throw even though the afterMementoId
    // references an evicted memento. It restores the before-pipeline
    // — the renderer re-runs the parametric chain afterward.
    final ok = history.undo();
    expect(ok, isTrue);
    expect(history.currentPipeline, before,
        reason: 'undo restores beforePipeline — the parametric chain '
            'regenerates the pre-op state without the memento');
  });

  test('redo past a dangling memento also succeeds', () async {
    final store = MementoStore(ramRingCapacity: 4);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
    );

    final memento = await store.store(
      opId: 'op-ai',
      width: 1,
      height: 1,
      bytes: bytes(4),
    );
    final before = history.currentPipeline;
    final op = aiOp();
    final after = before.append(op);
    history.execute(
      op: op,
      newPipeline: after,
      afterMementoId: memento.id,
    );

    history.undo();
    // Now evict between undo and redo — simulates the disk-budget
    // eviction sweeping a memento while the user had an op undone.
    await store.drop(memento.id);
    expect(store.lookup(memento.id), isNull);

    final ok = history.redo();
    expect(ok, isTrue);
    expect(history.currentPipeline, after,
        reason: 'redo restores afterPipeline without reading the '
            'now-missing memento');
  });

  test('mixed history: AI op with missing memento between parametric '
      'ops still supports linear undo', () async {
    final store = MementoStore(ramRingCapacity: 2);
    final history = HistoryManager.withPipeline(
      mementoStore: store,
      initial: EditPipeline.forOriginal('/tmp/img.jpg'),
    );

    final brightnessOp = EditOperation.create(
      type: EditOpType.brightness,
      parameters: {'value': 0.3},
    );
    final stage1 = history.currentPipeline.append(brightnessOp);
    history.execute(op: brightnessOp, newPipeline: stage1);

    // AI op with a memento that's immediately dropped.
    final memento = await store.store(
      opId: 'ai',
      width: 1,
      height: 1,
      bytes: bytes(4),
    );
    await store.drop(memento.id);
    final op2 = aiOp();
    final stage2 = stage1.append(op2);
    history.execute(
      op: op2,
      newPipeline: stage2,
      afterMementoId: memento.id,
    );

    final contrastOp = EditOperation.create(
      type: EditOpType.contrast,
      parameters: {'value': 0.2},
    );
    final stage3 = stage2.append(contrastOp);
    history.execute(op: contrastOp, newPipeline: stage3);

    // Full undo chain: stage3 → stage2 → stage1 → initial.
    expect(history.undo(), isTrue);
    expect(history.currentPipeline, stage2);
    expect(history.undo(), isTrue);
    expect(history.currentPipeline, stage1,
        reason: 'undoing PAST the dangling-memento entry still works');
    expect(history.undo(), isTrue);
    expect(history.currentPipeline.operations, isEmpty);
  });
}
