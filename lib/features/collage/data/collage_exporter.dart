import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../../../core/io/export_file_sink.dart';
import '../../../core/logging/app_logger.dart';

final _log = AppLogger('CollageExport');

/// Renders a `RepaintBoundary`-wrapped collage canvas to a PNG file
/// under the app documents directory. Uses the widget tree's real
/// layout output, so whatever the user sees on screen is what ships.
class CollageExporter {
  const CollageExporter();

  Future<File> export({
    required RenderRepaintBoundary boundary,
    required double pixelRatio,
    String? title,
  }) async {
    final sw = Stopwatch()..start();
    final image = await boundary.toImage(pixelRatio: pixelRatio);
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
