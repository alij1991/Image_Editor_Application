import 'package:uuid/uuid.dart';

import '../pipeline/edit_operation.dart';
import '../pipeline/edit_pipeline.dart';
import 'memento_store.dart';

/// A single entry in the edit history.
///
/// For parametric ops ([EditOperation.requiresMemento] == false) only the
/// op itself and the before/after pipeline snapshots are stored.
/// For non-reversible ops (LaMa, ESRGAN, etc.) we additionally hold a
/// [Memento] id so Undo can swap back to the previous pixel state.
class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.op,
    required this.beforePipeline,
    required this.afterPipeline,
    this.beforeMementoId,
    this.afterMementoId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String id;
  final EditOperation op;
  final EditPipeline beforePipeline;
  final EditPipeline afterPipeline;
  final String? beforeMementoId;
  final String? afterMementoId;
  final DateTime timestamp;
}

/// Hybrid Command + Memento history manager.
///
/// - Command path: every parametric edit produces a [HistoryEntry] whose
///   before/after pipelines capture the full state. Undo/redo swap between
///   them. Because pipelines are immutable freezed values this is cheap.
/// - Memento path: non-reversible ops additionally pin a memento in the
///   [MementoStore] so the renderer can reconstruct the pre-op bytes
///   without re-running the AI model.
///
/// Follows the plan's "Execute / Undo / Redo / ToggleEnabled / JumpTo"
/// event surface; the [HistoryBloc] wraps this with event-state semantics.
class HistoryManager {
  HistoryManager({
    required MementoStore mementoStore,
    this.historyLimit = 128,
  }) : _mementoStore = mementoStore;

  final MementoStore _mementoStore;
  final int historyLimit;

  final List<HistoryEntry> _entries = [];
  int _cursor = -1; // index of the last applied entry; -1 = empty

  /// Cumulative count of entries evicted by `_enforceHistoryLimit`
  /// since the last `clear()`. Surfaced through `HistoryState` so the
  /// timeline sheet can warn "N earliest edit(s) dropped" — otherwise
  /// users hitting the cap silently lose Undo targets.
  int _droppedCount = 0;

  EditPipeline _currentPipeline = EditPipeline.forOriginal('');

  /// Returns a HistoryManager initialized with the given starting pipeline.
  factory HistoryManager.withPipeline({
    required MementoStore mementoStore,
    required EditPipeline initial,
    int historyLimit = 128,
  }) {
    final hm = HistoryManager(
      mementoStore: mementoStore,
      historyLimit: historyLimit,
    );
    hm._currentPipeline = initial;
    return hm;
  }

  EditPipeline get currentPipeline => _currentPipeline;

  bool get canUndo => _cursor >= 0;
  bool get canRedo => _cursor < _entries.length - 1;
  int get entryCount => _entries.length;
  int get cursor => _cursor;
  int get droppedCount => _droppedCount;

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  /// Execute a new edit: apply [newPipeline], record the delta as a
  /// [HistoryEntry], and truncate the redo tail.
  HistoryEntry execute({
    required EditOperation op,
    required EditPipeline newPipeline,
    String? beforeMementoId,
    String? afterMementoId,
  }) {
    final entry = HistoryEntry(
      id: const Uuid().v4(),
      op: op,
      beforePipeline: _currentPipeline,
      afterPipeline: newPipeline,
      beforeMementoId: beforeMementoId,
      afterMementoId: afterMementoId,
    );

    // Truncate anything past the cursor.
    if (_cursor < _entries.length - 1) {
      final removed = _entries.sublist(_cursor + 1);
      _entries.removeRange(_cursor + 1, _entries.length);
      _dropRemovedMementos(removed);
    }

    _entries.add(entry);
    _cursor = _entries.length - 1;
    _currentPipeline = newPipeline;

    _enforceHistoryLimit();
    return entry;
  }

  /// Step backward: set current to the entry's beforePipeline.
  /// Returns false if nothing to undo.
  bool undo() {
    if (!canUndo) return false;
    final entry = _entries[_cursor];
    _currentPipeline = entry.beforePipeline;
    _cursor--;
    return true;
  }

  /// Step forward: re-apply the next entry's afterPipeline.
  bool redo() {
    if (!canRedo) return false;
    _cursor++;
    final entry = _entries[_cursor];
    _currentPipeline = entry.afterPipeline;
    return true;
  }

  /// Jump the current state to the entry at [index]. If [index] == -1 the
  /// pipeline returns to its initial (pre-history) state.
  void jumpTo(int index) {
    if (index == _cursor) return;
    if (index < -1 || index >= _entries.length) {
      throw RangeError.index(index, _entries);
    }
    if (index == -1) {
      _currentPipeline = _entries.first.beforePipeline;
      _cursor = -1;
    } else {
      _currentPipeline = _entries[index].afterPipeline;
      _cursor = index;
    }
  }

  /// Toggle the `enabled` flag on an op inside the current pipeline. This
  /// is itself an event — it produces a new HistoryEntry so the user can
  /// undo the toggle.
  HistoryEntry toggleEnabled(String opId) {
    final before = _currentPipeline;
    final after = before.toggleEnabled(opId);
    final op = after.operations.firstWhere((o) => o.id == opId);
    return execute(op: op, newPipeline: after);
  }

  /// Clear everything. Drops all mementos from the store.
  Future<void> clear() async {
    for (final e in _entries) {
      if (e.beforeMementoId != null) {
        await _mementoStore.drop(e.beforeMementoId!);
      }
      if (e.afterMementoId != null) {
        await _mementoStore.drop(e.afterMementoId!);
      }
    }
    _entries.clear();
    _cursor = -1;
    _droppedCount = 0;
  }

  void _dropRemovedMementos(List<HistoryEntry> removed) {
    for (final e in removed) {
      if (e.beforeMementoId != null) {
        _mementoStore.drop(e.beforeMementoId!);
      }
      if (e.afterMementoId != null) {
        _mementoStore.drop(e.afterMementoId!);
      }
    }
  }

  void _enforceHistoryLimit() {
    while (_entries.length > historyLimit) {
      final dropped = _entries.removeAt(0);
      if (_cursor > -1) _cursor--;
      if (dropped.beforeMementoId != null) {
        _mementoStore.drop(dropped.beforeMementoId!);
      }
      if (dropped.afterMementoId != null) {
        _mementoStore.drop(dropped.afterMementoId!);
      }
      _droppedCount++;
    }
  }
}
