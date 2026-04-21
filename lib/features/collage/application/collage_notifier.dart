import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../data/collage_repository.dart';
import '../domain/collage_state.dart';
import '../domain/collage_template.dart';

final _log = AppLogger('Collage');

/// Riverpod notifier for the live collage session.
///
/// One session at a time; cleared via [reset] when the user exits.
/// When a [CollageRepository] is injected (production + integration
/// tests) every committed state change schedules a 600 ms debounced
/// auto-save, and [hydrate] rebuilds state from disk on page open.
/// Unit tests can omit the repo to skip the IO side-effects.
class CollageNotifier extends StateNotifier<CollageState> {
  CollageNotifier({CollageRepository? repository})
      : _repository = repository,
        super(CollageState.forTemplate(CollageTemplates.all.first)) {
    _log.i('init', {
      'template': CollageTemplates.all.first.id,
      'persist': repository != null,
    });
  }

  final CollageRepository? _repository;

  /// Debounced auto-save timer. Each mutation cancels the pending
  /// timer and schedules a fresh one; the final state in a burst of
  /// edits is the only one that reaches disk.
  Timer? _autoSaveTimer;
  static const Duration _kAutoSaveDelay = Duration(milliseconds: 600);

  /// True once [hydrate] has returned. Until then, auto-save is
  /// suppressed so a hydrate-after-mutation race doesn't overwrite
  /// the saved file with freshly-constructed default state.
  bool _hydrated = false;

  /// Load any persisted state from the repository and replace the
  /// current (default) state with it. Safe to call after widgets are
  /// already observing — the state replacement fires a normal
  /// notification.
  ///
  /// After return, auto-save is enabled regardless of whether a
  /// restore happened; subsequent mutations persist.
  Future<void> hydrate() async {
    if (_hydrated) return;
    final repo = _repository;
    if (repo == null) {
      _hydrated = true;
      return;
    }
    try {
      final restored = await repo.load();
      if (restored != null && mounted) {
        _log.i('hydrated', {
          'templateId': restored.template.id,
          'cells': restored.cells.length,
        });
        state = restored;
      }
    } catch (e, st) {
      _log.w('hydrate failed', {'error': e.toString()});
      _log.e('hydrate trace', error: e, stackTrace: st);
    } finally {
      _hydrated = true;
    }
  }

  /// Schedule an auto-save 600 ms in the future, cancelling any prior
  /// pending timer. No-op until [hydrate] has resolved (see the
  /// [_hydrated] rationale).
  void _scheduleAutoSave() {
    if (!_hydrated) return;
    final repo = _repository;
    if (repo == null) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_kAutoSaveDelay, () {
      // Snapshot the current state at fire-time; if a later edit has
      // already scheduled a newer save, the repo's last-write-wins
      // semantics still land the right bytes on disk.
      repo.save(state);
    });
  }

  /// Switch to a different template.
  ///
  /// Image selections survive the switch: the underlying
  /// [CollageState.imageHistory] is preserved, so moving from a 3×3
  /// (9 cells) to a 2×2 (4 cells) and back restores the original
  /// images at indices 4–8. No confirmation dialog is shown — the
  /// preservation makes template-flipping a safe, exploratory action.
  void setTemplate(CollageTemplate t) {
    if (state.template.id == t.id) return;
    _log.i('setTemplate', {
      'id': t.id,
      'cells': t.cells.length,
      'historyLen': state.imageHistory.length,
    });
    // Grow the history if the new template has more cells than we've
    // tracked before. Shrinking would lose preserved entries, so the
    // history only ever grows within a session.
    final grown = _growHistoryTo(state.imageHistory, t.cells.length);
    state = state.copyWith(template: t, imageHistory: grown);
    _scheduleAutoSave();
  }

  void setAspect(CollageAspect aspect) {
    if (state.aspect == aspect) return;
    _log.i('setAspect', {'aspect': aspect.name});
    state = state.copyWith(aspect: aspect);
    _scheduleAutoSave();
  }

  void setInnerBorder(double value) {
    state = state.copyWith(innerBorder: value);
    _scheduleAutoSave();
  }

  void setOuterMargin(double value) {
    state = state.copyWith(outerMargin: value);
    _scheduleAutoSave();
  }

  void setCornerRadius(double value) {
    state = state.copyWith(cornerRadius: value);
    _scheduleAutoSave();
  }

  void setBackgroundColor(Color c) {
    state = state.copyWith(backgroundColor: c);
    _scheduleAutoSave();
  }

  /// Set or clear the image path for the cell at [index]. Updates
  /// [CollageState.imageHistory] at the same index so future template
  /// changes restore this pick.
  void setCellImage(int index, String? path) {
    if (index < 0 || index >= state.template.cells.length) return;
    _log.d('setCellImage', {'idx': index, 'path': path});
    final next = _growHistoryTo(
      state.imageHistory,
      state.template.cells.length,
    );
    next[index] = path;
    state = state.copyWith(imageHistory: next);
    _scheduleAutoSave();
  }

  /// Swap two cells' images — used by drag-and-drop re-ordering.
  /// Swaps the two entries in [CollageState.imageHistory] so a
  /// subsequent template switch respects the new positions.
  void swapCellImages(int a, int b) {
    if (a == b) return;
    if (a < 0 ||
        b < 0 ||
        a >= state.template.cells.length ||
        b >= state.template.cells.length) {
      return;
    }
    _log.d('swap', {'a': a, 'b': b});
    final next = _growHistoryTo(
      state.imageHistory,
      state.template.cells.length,
    );
    final tmp = next[a];
    next[a] = next[b];
    next[b] = tmp;
    state = state.copyWith(imageHistory: next);
    _scheduleAutoSave();
  }

  /// Restart with the first template and empty cells. Drops the
  /// preserved history so the next pick starts fresh, and deletes the
  /// persisted file.
  void reset() {
    _log.i('reset');
    state = CollageState.forTemplate(CollageTemplates.all.first);
    // Cancel any pending save + delete the file; the repo's delete
    // is fire-and-forget (errors log but don't throw).
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _repository?.delete();
  }

  /// Return a mutable copy of [history] padded with `null`s up to
  /// [minLength]. Preserves existing entries; never shrinks. The
  /// caller mutates the returned list and passes it to [copyWith].
  static List<String?> _growHistoryTo(
    List<String?> history,
    int minLength,
  ) {
    final length = history.length < minLength ? minLength : history.length;
    return <String?>[
      ...history,
      for (var i = history.length; i < length; i++) null,
    ];
  }

  @override
  void dispose() {
    // Flush any pending debounce by firing one final save if the
    // timer was still armed. Avoids losing the last few edits when
    // the user backs out of the route immediately after tweaking.
    if (_autoSaveTimer != null && _autoSaveTimer!.isActive) {
      _autoSaveTimer!.cancel();
      _repository?.save(state);
    }
    super.dispose();
  }
}

/// Shared [CollageRepository] singleton. Production uses the default
/// constructor (real `<AppDocs>/collages/` path); tests override with a
/// temp-dir `rootOverride` via a ProviderScope.
final collageRepositoryProvider = Provider<CollageRepository>((ref) {
  return CollageRepository();
});

/// Global provider for the collage session. Auto-disposed when the
/// collage route leaves the widget tree.
final collageNotifierProvider =
    StateNotifierProvider.autoDispose<CollageNotifier, CollageState>(
  (ref) => CollageNotifier(
    repository: ref.watch(collageRepositoryProvider),
  ),
);
