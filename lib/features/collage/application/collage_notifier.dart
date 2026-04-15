import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/collage_state.dart';
import '../domain/collage_template.dart';

final _log = AppLogger('Collage');

/// Riverpod notifier for the live collage session. One session at a
/// time; cleared via [CollageNotifier.reset] when the user exits.
class CollageNotifier extends StateNotifier<CollageState> {
  CollageNotifier()
      : super(CollageState.forTemplate(CollageTemplates.all.first)) {
    _log.i('init', {'template': CollageTemplates.all.first.id});
  }

  /// Switch to a different template, preserving any images that still
  /// fit (by index).
  void setTemplate(CollageTemplate t) {
    if (state.template.id == t.id) return;
    _log.i('setTemplate', {'id': t.id, 'cells': t.cells.length});
    final oldCells = state.cells;
    final newCells = <CollageCell>[
      for (var i = 0; i < t.cells.length; i++)
        CollageCell(
          rect: t.cells[i],
          imagePath: i < oldCells.length ? oldCells[i].imagePath : null,
        ),
    ];
    state = state.copyWith(template: t, cells: newCells);
  }

  void setAspect(CollageAspect aspect) {
    if (state.aspect == aspect) return;
    _log.i('setAspect', {'aspect': aspect.name});
    state = state.copyWith(aspect: aspect);
  }

  void setInnerBorder(double value) =>
      state = state.copyWith(innerBorder: value);

  void setOuterMargin(double value) =>
      state = state.copyWith(outerMargin: value);

  void setCornerRadius(double value) =>
      state = state.copyWith(cornerRadius: value);

  void setBackgroundColor(Color c) =>
      state = state.copyWith(backgroundColor: c);

  /// Set or clear the image path for the cell at [index].
  void setCellImage(int index, String? path) {
    if (index < 0 || index >= state.cells.length) return;
    _log.d('setCellImage', {'idx': index, 'path': path});
    final newCells = [...state.cells];
    newCells[index] = newCells[index].copyWith(imagePath: path);
    state = state.copyWith(cells: newCells);
  }

  /// Swap two cells' images — used by drag-and-drop re-ordering.
  void swapCellImages(int a, int b) {
    if (a == b) return;
    if (a < 0 || b < 0 || a >= state.cells.length || b >= state.cells.length) {
      return;
    }
    _log.d('swap', {'a': a, 'b': b});
    final newCells = [...state.cells];
    final pathA = newCells[a].imagePath;
    final pathB = newCells[b].imagePath;
    newCells[a] = newCells[a].copyWith(imagePath: pathB);
    newCells[b] = newCells[b].copyWith(imagePath: pathA);
    state = state.copyWith(cells: newCells);
  }

  /// Restart with the first template and empty cells.
  void reset() {
    _log.i('reset');
    state = CollageState.forTemplate(CollageTemplates.all.first);
  }
}

/// Global provider for the collage session. Auto-disposed when the
/// collage route leaves the widget tree.
final collageNotifierProvider =
    StateNotifierProvider.autoDispose<CollageNotifier, CollageState>(
  (ref) => CollageNotifier(),
);
