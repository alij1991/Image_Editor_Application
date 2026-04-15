/// A collage template — a named list of cell rectangles in normalised
/// 0..1 coords of the canvas. Templates are purely layout descriptions;
/// the images, borders, aspect ratio, and background colour live in
/// [CollageState].
class CollageTemplate {
  const CollageTemplate({
    required this.id,
    required this.name,
    required this.cells,
    this.category = CollageCategory.grid,
  });

  final String id;
  final String name;
  final List<CollageCellRect> cells;
  final CollageCategory category;

  int get cellCount => cells.length;
}

class CollageCellRect {
  const CollageCellRect(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
}

enum CollageCategory { grid, magazine, freestyle }

extension CollageCategoryLabel on CollageCategory {
  String get label => switch (this) {
        CollageCategory.grid => 'Grid',
        CollageCategory.magazine => 'Magazine',
        CollageCategory.freestyle => 'Freestyle',
      };
}

/// Catalog of 18 built-in layouts. Cells are expressed in normalised
/// coords so the same template adapts to any aspect ratio / canvas
/// size. Each row of the list below groups by category.
class CollageTemplates {
  CollageTemplates._();

  // Helper to reduce visual noise when declaring the catalog.
  static CollageCellRect _r(double l, double t, double w, double h) =>
      CollageCellRect(l, t, w, h);

  static final List<CollageTemplate> all = [
    // --- Grid ----------------------------------------------------------
    CollageTemplate(
      id: 'grid.1x2',
      name: '1 × 2',
      cells: [_r(0, 0, 1, 0.5), _r(0, 0.5, 1, 0.5)],
    ),
    CollageTemplate(
      id: 'grid.2x1',
      name: '2 × 1',
      cells: [_r(0, 0, 0.5, 1), _r(0.5, 0, 0.5, 1)],
    ),
    CollageTemplate(
      id: 'grid.2x2',
      name: '2 × 2',
      cells: [
        _r(0, 0, 0.5, 0.5),
        _r(0.5, 0, 0.5, 0.5),
        _r(0, 0.5, 0.5, 0.5),
        _r(0.5, 0.5, 0.5, 0.5),
      ],
    ),
    CollageTemplate(
      id: 'grid.2x3',
      name: '2 × 3',
      cells: [
        for (var r = 0; r < 3; r++)
          for (var c = 0; c < 2; c++) _r(c * 0.5, r / 3, 0.5, 1 / 3),
      ],
    ),
    CollageTemplate(
      id: 'grid.3x2',
      name: '3 × 2',
      cells: [
        for (var r = 0; r < 2; r++)
          for (var c = 0; c < 3; c++) _r(c / 3, r * 0.5, 1 / 3, 0.5),
      ],
    ),
    CollageTemplate(
      id: 'grid.3x3',
      name: '3 × 3',
      cells: [
        for (var r = 0; r < 3; r++)
          for (var c = 0; c < 3; c++) _r(c / 3, r / 3, 1 / 3, 1 / 3),
      ],
    ),

    // --- Magazine ------------------------------------------------------
    CollageTemplate(
      id: 'mag.big_top_2',
      name: 'Hero · 2',
      category: CollageCategory.magazine,
      cells: [
        _r(0, 0, 1, 0.6),
        _r(0, 0.6, 0.5, 0.4),
        _r(0.5, 0.6, 0.5, 0.4),
      ],
    ),
    CollageTemplate(
      id: 'mag.big_left_2',
      name: 'Hero L · 2',
      category: CollageCategory.magazine,
      cells: [
        _r(0, 0, 0.6, 1),
        _r(0.6, 0, 0.4, 0.5),
        _r(0.6, 0.5, 0.4, 0.5),
      ],
    ),
    CollageTemplate(
      id: 'mag.big_top_3',
      name: 'Hero · 3',
      category: CollageCategory.magazine,
      cells: [
        _r(0, 0, 1, 0.55),
        _r(0, 0.55, 1 / 3, 0.45),
        _r(1 / 3, 0.55, 1 / 3, 0.45),
        _r(2 / 3, 0.55, 1 / 3, 0.45),
      ],
    ),
    CollageTemplate(
      id: 'mag.left_column',
      name: 'Column',
      category: CollageCategory.magazine,
      cells: [
        _r(0, 0, 0.5, 1),
        _r(0.5, 0, 0.5, 1 / 3),
        _r(0.5, 1 / 3, 0.5, 1 / 3),
        _r(0.5, 2 / 3, 0.5, 1 / 3),
      ],
    ),
    CollageTemplate(
      id: 'mag.asymmetric_5',
      name: 'Asym · 5',
      category: CollageCategory.magazine,
      cells: [
        _r(0, 0, 0.5, 0.5),
        _r(0.5, 0, 0.5, 0.3),
        _r(0.5, 0.3, 0.5, 0.2),
        _r(0, 0.5, 0.6, 0.5),
        _r(0.6, 0.5, 0.4, 0.5),
      ],
    ),
    CollageTemplate(
      id: 'mag.center_hero',
      name: 'Center Hero',
      category: CollageCategory.magazine,
      cells: [
        _r(0, 0, 1, 0.25),
        _r(0, 0.25, 0.25, 0.5),
        _r(0.25, 0.25, 0.5, 0.5),
        _r(0.75, 0.25, 0.25, 0.5),
        _r(0, 0.75, 1, 0.25),
      ],
    ),

    // --- Freestyle (loose arrangements) -------------------------------
    CollageTemplate(
      id: 'free.pinwheel',
      name: 'Pinwheel',
      category: CollageCategory.freestyle,
      cells: [
        _r(0, 0, 0.5, 0.7),
        _r(0.5, 0, 0.5, 0.3),
        _r(0.5, 0.3, 0.5, 0.7),
        _r(0, 0.7, 0.5, 0.3),
      ],
    ),
    CollageTemplate(
      id: 'free.stair',
      name: 'Stair',
      category: CollageCategory.freestyle,
      cells: [
        _r(0, 0, 0.5, 0.4),
        _r(0.5, 0.1, 0.5, 0.4),
        _r(0, 0.5, 0.5, 0.4),
        _r(0.5, 0.6, 0.5, 0.4),
      ],
    ),
    CollageTemplate(
      id: 'free.diamond',
      name: 'Diamond',
      category: CollageCategory.freestyle,
      cells: [
        _r(0.25, 0, 0.5, 0.5),
        _r(0, 0.25, 0.5, 0.5),
        _r(0.5, 0.25, 0.5, 0.5),
        _r(0.25, 0.5, 0.5, 0.5),
      ],
    ),
    CollageTemplate(
      id: 'free.six_split',
      name: 'Six Split',
      category: CollageCategory.freestyle,
      cells: [
        _r(0, 0, 1 / 3, 0.5),
        _r(1 / 3, 0, 1 / 3, 0.5),
        _r(2 / 3, 0, 1 / 3, 0.5),
        _r(0, 0.5, 0.5, 0.5),
        _r(0.5, 0.5, 0.25, 0.5),
        _r(0.75, 0.5, 0.25, 0.5),
      ],
    ),
    CollageTemplate(
      id: 'free.offset_3',
      name: 'Offset · 3',
      category: CollageCategory.freestyle,
      cells: [
        _r(0, 0, 0.55, 0.65),
        _r(0.55, 0, 0.45, 0.4),
        _r(0.55, 0.4, 0.45, 0.6),
      ],
    ),
    CollageTemplate(
      id: 'free.single',
      name: 'Single',
      category: CollageCategory.freestyle,
      cells: [_r(0, 0, 1, 1)],
    ),
  ];

  static CollageTemplate byId(String id) {
    return all.firstWhere((t) => t.id == id, orElse: () => all.first);
  }
}
