import 'package:flutter/material.dart';

import 'collage_template.dart';

/// Supported canvas aspect ratios. `auto` derives from the template's
/// bounding rect (1:1 in all current templates).
enum CollageAspect { square, portrait, landscape, portraitTall, landscapeWide, story }

extension CollageAspectX on CollageAspect {
  double get ratio => switch (this) {
        CollageAspect.square => 1.0,
        CollageAspect.portrait => 4 / 5,
        CollageAspect.landscape => 5 / 4,
        CollageAspect.portraitTall => 3 / 4,
        CollageAspect.landscapeWide => 3 / 2,
        CollageAspect.story => 9 / 16,
      };

  String get label => switch (this) {
        CollageAspect.square => '1:1',
        CollageAspect.portrait => '4:5',
        CollageAspect.landscape => '5:4',
        CollageAspect.portraitTall => '3:4',
        CollageAspect.landscapeWide => '3:2',
        CollageAspect.story => '9:16',
      };
}

/// A single slot in the collage — a cell rect + optional picked image.
/// When [imagePath] is null the cell renders an empty "tap to add"
/// placeholder.
class CollageCell {
  const CollageCell({required this.rect, this.imagePath});

  final CollageCellRect rect;
  final String? imagePath;

  CollageCell copyWith({CollageCellRect? rect, Object? imagePath = _sentinel}) {
    return CollageCell(
      rect: rect ?? this.rect,
      imagePath: identical(imagePath, _sentinel)
          ? this.imagePath
          : imagePath as String?,
    );
  }
}

const _sentinel = Object();

/// Immutable state of the collage editor. Owned by `CollageNotifier`.
class CollageState {
  const CollageState({
    required this.template,
    required this.cells,
    this.aspect = CollageAspect.square,
    this.innerBorder = 4.0,
    this.outerMargin = 8.0,
    this.cornerRadius = 0.0,
    this.backgroundColor = const Color(0xFFFFFFFF),
  });

  final CollageTemplate template;
  final List<CollageCell> cells;
  final CollageAspect aspect;

  /// Gap between cells, in screen px.
  final double innerBorder;

  /// Padding around the outside of the entire collage, in screen px.
  final double outerMargin;

  /// Radius applied to each cell's rounded corners, in screen px.
  final double cornerRadius;

  /// Fill colour shown in the gaps and behind empty cells.
  final Color backgroundColor;

  CollageState copyWith({
    CollageTemplate? template,
    List<CollageCell>? cells,
    CollageAspect? aspect,
    double? innerBorder,
    double? outerMargin,
    double? cornerRadius,
    Color? backgroundColor,
  }) {
    return CollageState(
      template: template ?? this.template,
      cells: cells ?? this.cells,
      aspect: aspect ?? this.aspect,
      innerBorder: innerBorder ?? this.innerBorder,
      outerMargin: outerMargin ?? this.outerMargin,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
  }

  factory CollageState.forTemplate(CollageTemplate t) {
    return CollageState(
      template: t,
      cells: [for (final r in t.cells) CollageCell(rect: r)],
    );
  }
}
