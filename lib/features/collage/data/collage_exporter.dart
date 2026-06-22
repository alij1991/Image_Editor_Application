import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../../../core/io/export_file_sink.dart';
import '../../../core/logging/app_logger.dart';

final _log = AppLogger('CollageExport');

/// D3 (XVI.123) — universal fallback ceiling for the rasterised collage
/// long edge (in pixels). The page passes a device-tier value derived
/// from [MemoryBudget]; this default just keeps direct callers + tests
/// safe.
const int kCollageMaxOutputLongEdge = 4096;

/// Clamp the requested export `pixelRatio` so the rasterised long edge
/// stays within [maxOutputLongEdge]. At 8× a 1080-pt canvas rasterises
/// to ~8640² (~299 MB RGBA), which OOMs mid-tier devices; this honours
/// the user's choice up to the budget, then caps. Returns [requested]
/// unchanged when it's already within budget or inputs are degenerate.
double effectiveCollagePixelRatio({
  required double requested,
  required double logicalLongEdge,
  required int maxOutputLongEdge,
}) {
  if (!logicalLongEdge.isFinite || logicalLongEdge <= 0 || requested <= 0) {
    return requested;
  }
  final maxRatio = maxOutputLongEdge / logicalLongEdge;
  return requested > maxRatio ? maxRatio : requested;
}

/// Renders a `RepaintBoundary`-wrapped collage canvas to a PNG file
/// under the app documents directory. Uses the widget tree's real
/// layout output, so whatever the user sees on screen is what ships.
class CollageExporter {
  const CollageExporter();

  Future<File> export({
    required RenderRepaintBoundary boundary,
    required double pixelRatio,
    int maxOutputLongEdge = kCollageMaxOutputLongEdge,
    String? title,
  }) async {
    final sw = Stopwatch()..start();
    // D3 — cap the effective pixelRatio so the rasterised RGBA buffer
    // can't OOM the device.
    final effective = effectiveCollagePixelRatio(
      requested: pixelRatio,
      logicalLongEdge: boundary.size.longestSide,
      maxOutputLongEdge: maxOutputLongEdge,
    );
    if (effective < pixelRatio) {
      _log.w('export pixelRatio capped to fit memory budget', {
        'requested': pixelRatio,
        'effective': effective,
        'logicalLongEdge': boundary.size.longestSide,
        'maxOutputLongEdge': maxOutputLongEdge,
      });
    }
    final image = await boundary.toImage(pixelRatio: effective);
    // Snapshot dimensions BEFORE dispose — accessing them afterwards
    // is undefined.
    final w = image.width;
    final h = image.height;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      image.dispose();
      throw StateError('toByteData returned null');
    }
    final bytes = data.buffer.asUint8List();
    image.dispose();
    final file = await writeExportBytes(
      bytes: bytes,
      subdir: 'collage_exports',
      extension: '.png',
      title: title,
      timestampPrefix: 'Collage',
    );
    _log.i('exported', {
      'w': w,
      'h': h,
      'bytes': bytes.length,
      'path': file.path,
      'ms': sw.elapsedMilliseconds,
    });
    return file;
  }

}
