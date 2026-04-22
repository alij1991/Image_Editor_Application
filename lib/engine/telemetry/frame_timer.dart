import 'package:flutter/scheduler.dart';
import 'package:logger/logger.dart';

/// Captures frame timing via [SchedulerBinding.addTimingsCallback] and
/// computes rolling statistics tied to the blueprint's checkpoint targets:
///
/// - Single pass @ 1080p: < 2 ms
/// - Full color pipeline: < 5 ms raster
/// - Slider drag: 60 fps sustained, < 1.5% Impeller frame drops
///
/// Register [start] from `bootstrap.dart` or from a debug-only settings
/// toggle. Measurements are surfaced to the [logger] package in debug
/// builds and can be streamed to an in-app diagnostics panel.
class FrameTimer {
  FrameTimer({Logger? logger, this.windowSize = 120})
      : _logger = logger ?? Logger();

  final Logger _logger;
  final int windowSize;

  final List<double> _rasterMs = [];
  final List<double> _buildMs = [];
  bool _started = false;
  void Function(List<FrameTimingSample>)? _listener;

  bool get isRunning => _started;

  int get sampleCount => _rasterMs.length;

  double get averageRasterMs =>
      _rasterMs.isEmpty ? 0 : _rasterMs.reduce((a, b) => a + b) / _rasterMs.length;

  double get averageBuildMs =>
      _buildMs.isEmpty ? 0 : _buildMs.reduce((a, b) => a + b) / _buildMs.length;

  double get p95RasterMs {
    if (_rasterMs.isEmpty) return 0;
    final sorted = [..._rasterMs]..sort();
    final idx = (sorted.length * 0.95).floor().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  /// Fraction of the window with raster duration > 16.6 ms (dropped at 60 fps).
  double get frameDropRate {
    if (_rasterMs.isEmpty) return 0;
    final dropped = _rasterMs.where((ms) => ms > 16.6).length;
    return dropped / _rasterMs.length;
  }

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void attach(void Function(List<FrameTimingSample>) listener) {
    _listener = listener;
  }

  void _onTimings(List<FrameTiming> timings) {
    final samples = <FrameTimingSample>[];
    for (final t in timings) {
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      final build = t.buildDuration.inMicroseconds / 1000.0;
      _rasterMs.add(raster);
      _buildMs.add(build);
      while (_rasterMs.length > windowSize) {
        _rasterMs.removeAt(0);
      }
      while (_buildMs.length > windowSize) {
        _buildMs.removeAt(0);
      }
      samples.add(FrameTimingSample(buildMs: build, rasterMs: raster));
    }
    _listener?.call(samples);
    // Cheap periodic summary in debug.
    if (_rasterMs.length == windowSize && _rasterMs.length % 900 == 0) {
      _logger.d(
        'FrameTimer: avgRaster=${averageRasterMs.toStringAsFixed(2)} ms '
        'p95=${p95RasterMs.toStringAsFixed(2)} ms '
        'dropRate=${(frameDropRate * 100).toStringAsFixed(1)}%',
      );
    }
  }
}

class FrameTimingSample {
  const FrameTimingSample({required this.buildMs, required this.rasterMs});
  final double buildMs;
  final double rasterMs;
}
