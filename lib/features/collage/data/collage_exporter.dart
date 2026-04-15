import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
    final file = await _saveBytes(bytes, title);
    _log.i('exported', {
      'w': w,
      'h': h,
      'bytes': bytes.length,
      'path': file.path,
      'ms': sw.elapsedMilliseconds,
    });
    return file;
  }

  Future<File> _saveBytes(Uint8List bytes, String? title) async {
    final dir = await getApplicationDocumentsDirectory();
    final exportsDir = Directory(p.join(dir.path, 'collage_exports'));
    if (!exportsDir.existsSync()) exportsDir.createSync(recursive: true);
    final base = (title == null || title.trim().isEmpty)
        ? _timestampName()
        : title.trim();
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    final file = File(p.join(exportsDir.path, '$safe.png'));
    await file.writeAsBytes(bytes);
    return file;
  }

  String _timestampName() {
    final now = DateTime.now();
    two(int n) => n.toString().padLeft(2, '0');
    return 'Collage_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
