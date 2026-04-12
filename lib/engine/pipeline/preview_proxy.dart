import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/logging/app_logger.dart';
import '../../core/memory/ui_image_disposer.dart';

final _log = AppLogger('PreviewProxy');

/// Loads and manages the downscaled "preview proxy" for an editing session.
///
/// Per the blueprint: on session start the original is decoded once with
/// `cacheWidth` set to the device screen long-edge (e.g. 1920). The result
/// is a ~30 MB `ui.Image` that every shader pass runs against for 60 fps
/// feedback. The original is never decoded at full resolution on the main
/// isolate — that work is deferred to export via Rust.
class PreviewProxy {
  PreviewProxy({required this.sourcePath, required this.longEdge});

  final String sourcePath;
  final int longEdge;
  UiImageHandle? _handle;

  UiImageHandle? get handle => _handle;
  ui.Image? get image => _handle?.image;

  bool get isLoaded => _handle != null && !_handle!.isDisposed;

  /// Decode the source image at proxy resolution. Safe to call multiple
  /// times; subsequent calls no-op until [dispose] is invoked.
  Future<void> load() async {
    if (isLoaded) {
      _log.d('load skipped (already loaded)', {'path': sourcePath});
      return;
    }
    _log.i('load', {'path': sourcePath, 'longEdge': longEdge});
    final stopwatch = Stopwatch()..start();
    try {
      final bytes = await File(sourcePath).readAsBytes();
      _log.d('read bytes', {'bytes': bytes.length});
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(bytes),
        targetWidth: longEdge,
      );
      final frame = await codec.getNextFrame();
      _handle = UiImageHandle(frame.image);
      codec.dispose();
      stopwatch.stop();
      _log.i('load complete', {
        'ms': stopwatch.elapsedMilliseconds,
        'width': frame.image.width,
        'height': frame.image.height,
      });
    } catch (e, st) {
      _log.e('load failed',
          error: e, stackTrace: st, data: {'path': sourcePath});
      rethrow;
    }
  }

  /// Decode directly from in-memory bytes. Used by the model download
  /// path and the test harness (which does not touch the filesystem).
  Future<void> loadFromBytes(Uint8List bytes) async {
    if (isLoaded) return;
    _log.i('loadFromBytes', {'bytes': bytes.length, 'longEdge': longEdge});
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: longEdge);
    final frame = await codec.getNextFrame();
    _handle = UiImageHandle(frame.image);
    codec.dispose();
    _log.i('loadFromBytes complete', {
      'width': frame.image.width,
      'height': frame.image.height,
    });
  }

  void dispose() {
    if (_handle != null) {
      _log.d('dispose', {'path': sourcePath});
    }
    _handle?.release();
    _handle = null;
  }
}
