import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/logging/app_logger.dart';
import 'collage_template.dart';

final _log = AppLogger('CollageState');

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
///
/// Image selections are stored in [imageHistory] — one slot per cell
/// index — and [cells] is derived from `template.cells` + `imageHistory`
/// so switching to a smaller template preserves dropped images for the
/// rest of the session. Switching back to a larger template restores
/// them from the history. A hard reset ([CollageNotifier.reset])
/// clears the history alongside the state.
class CollageState {
  const CollageState({
    required this.template,
    this.imageHistory = const [],
    this.aspect = CollageAspect.square,
    this.innerBorder = 4.0,
    this.outerMargin = 8.0,
    this.cornerRadius = 0.0,
    this.backgroundColor = const Color(0xFFFFFFFF),
  });

  final CollageTemplate template;

  /// Per-index image selections. Length is at least `template.cells.length`
  /// for any state produced by [CollageState.forTemplate] or the
  /// notifier; a persisted state whose saved history is shorter than
  /// the current template pads with `null`s when derived.
  ///
  /// This list survives template switches: switching from a 3×3 to a
  /// 2×2 and back restores the original 5 dropped images at indices
  /// 4–8. Only a mutation to one of those indices (either via
  /// `setCellImage` on a larger template, or `reset()`) can remove an
  /// entry from the history.
  final List<String?> imageHistory;
  final CollageAspect aspect;

  /// Gap between cells, in screen px.
  final double innerBorder;

  /// Padding around the outside of the entire collage, in screen px.
  final double outerMargin;

  /// Radius applied to each cell's rounded corners, in screen px.
  final double cornerRadius;

  /// Fill colour shown in the gaps and behind empty cells.
  final Color backgroundColor;

  /// Cells derived from `template.cells` paired with [imageHistory].
  /// Indices past the history's length are rendered as empty slots.
  /// This is the canvas's render input.
  List<CollageCell> get cells => [
        for (var i = 0; i < template.cells.length; i++)
          CollageCell(
            rect: template.cells[i],
            imagePath:
                i < imageHistory.length ? imageHistory[i] : null,
          ),
      ];

  CollageState copyWith({
    CollageTemplate? template,
    List<String?>? imageHistory,
    CollageAspect? aspect,
    double? innerBorder,
    double? outerMargin,
    double? cornerRadius,
    Color? backgroundColor,
  }) {
    return CollageState(
      template: template ?? this.template,
      imageHistory: imageHistory ?? this.imageHistory,
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
      imageHistory: List<String?>.filled(t.cells.length, null),
    );
  }

  /// Serialize to a plain JSON map suitable for [CollageRepository].
  ///
  /// Persists the full [imageHistory] (including entries beyond the
  /// current template's cell count) so switching templates across
  /// sessions still preserves previously-chosen images.
  Map<String, dynamic> toJson() => {
        'templateId': template.id,
        'imageHistory': imageHistory,
        'aspect': aspect.name,
        'innerBorder': innerBorder,
        'outerMargin': outerMargin,
        'cornerRadius': cornerRadius,
        // Dart's Color.value is deprecated; use .toARGB32() which
        // returns the stable 32-bit ARGB form.
        'backgroundColor': backgroundColor.toARGB32(),
      };

  /// Reconstruct a [CollageState] from JSON.
  ///
  /// Saved `imageHistory` entries whose files no longer exist on disk
  /// are nulled out (with a log). The resulting cells are always safe
  /// to render — broken entries become empty "Tap to add" slots.
  ///
  /// Accepts both the current v1 shape (`imageHistory`) and the first
  /// v1 draft shape (`imagePaths`) for forward migration of the very
  /// small number of early-access files that shipped with the older
  /// field name.
  factory CollageState.fromJson(Map<String, dynamic> json) {
    final templateId = json['templateId'] as String?;
    final template = templateId == null
        ? CollageTemplates.all.first
        : CollageTemplates.byId(templateId);
    final rawList = (json['imageHistory'] ?? json['imagePaths']) as List?;
    final raw = rawList ?? const [];
    final history = <String?>[];
    // Preserve the full history length so a saved session with more
    // entries than the current template still recalls them after a
    // template switch.
    final length = raw.length < template.cells.length
        ? template.cells.length
        : raw.length;
    for (var i = 0; i < length; i++) {
      final savedPath = i < raw.length ? raw[i] as String? : null;
      if (savedPath == null) {
        history.add(null);
        continue;
      }
      if (File(savedPath).existsSync()) {
        history.add(savedPath);
      } else {
        _log.w('missing cell source; clearing slot', {
          'idx': i,
          'path': savedPath,
        });
        history.add(null);
      }
    }
    final aspectName = json['aspect'] as String?;
    final aspect = CollageAspect.values.firstWhere(
      (a) => a.name == aspectName,
      orElse: () => CollageAspect.square,
    );
    double doubleParam(String key, double fallback) {
      final raw = json[key];
      return raw is num ? raw.toDouble() : fallback;
    }
    final rawColor = json['backgroundColor'];
    final color = rawColor is num
        ? Color(rawColor.toInt())
        : const Color(0xFFFFFFFF);
    return CollageState(
      template: template,
      imageHistory: history,
      aspect: aspect,
      innerBorder: doubleParam('innerBorder', 4.0),
      outerMargin: doubleParam('outerMargin', 8.0),
      cornerRadius: doubleParam('cornerRadius', 0.0),
      backgroundColor: color,
    );
  }
}
