import 'package:flutter/painting.dart';
import 'package:logger/logger.dart';

import 'memory_budget.dart';

/// Applies [MemoryBudget] limits to [PaintingBinding.instance.imageCache]
/// and provides a watchdog that logs when usage approaches the budget
/// (tied to Flutter issue #178264 — Impeller GPU memory balloon).
///
/// Called from bootstrap.dart after probing the device.
class ImageCachePolicy {
  ImageCachePolicy({required this.budget, Logger? logger})
      : _logger = logger ?? Logger();

  final MemoryBudget budget;
  final Logger _logger;

  void apply() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = budget.imageCacheMaxBytes;
    // Keep maximumSize modest so large-image churn doesn't hang on to
    // dozens of thumbnails.
    cache.maximumSize = 128;
    _logger.d(
      'ImageCachePolicy applied: '
      'maxBytes=${budget.imageCacheMaxBytes} '
      'previewLongEdge=${budget.previewLongEdge}',
    );
  }

  /// Returns true if the current image cache byte usage is within the
  /// warning band (> 75% of max). Intended to be called on a watchdog tick
  /// (e.g. SchedulerBinding.addPostFrameCallback or a periodic Timer).
  bool nearBudget() {
    final cache = PaintingBinding.instance.imageCache;
    if (cache.maximumSizeBytes == 0) return false;
    return cache.currentSizeBytes > (cache.maximumSizeBytes * 3 / 4);
  }

  /// Aggressively purge the cache down to half its maximum. Called when
  /// [nearBudget] fires repeatedly or when the memory watchdog detects the
  /// Impeller balloon symptom.
  void purge() {
    final cache = PaintingBinding.instance.imageCache;
    final before = cache.currentSizeBytes;
    cache.clear();
    cache.clearLiveImages();
    _logger.w(
      'ImageCachePolicy purge: freed '
      '${before - cache.currentSizeBytes} bytes '
      '(Flutter #178264 mitigation)',
    );
  }
}
