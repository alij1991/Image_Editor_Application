import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../engine/telemetry/frame_timer.dart';

/// Floating dev-mode performance HUD.
///
/// Subscribes to a shared [FrameTimer] and renders a compact one-line
/// readout pinned to the bottom-right of the canvas:
///
///   `R 4.2  P95 8.1  drop 0.3%`
///
/// Tap to expand into a four-line breakdown (raster avg, raster p95,
/// drop rate vs the blueprint's <1.5% target, sample count).
///
/// The HUD is fully suppressed in release builds via [kReleaseMode]
/// and behind a single `enabled` flag so dev usage doesn't leak into
/// production. It does no per-frame setState — just a 0.5 Hz refresh.
class PerfHud extends StatefulWidget {
  const PerfHud({
    this.enabled = true,
    super.key,
  });

  /// Shared FrameTimer used by every [PerfHud] instance. Lazily started
  /// on first construction so we don't pay the timing-callback cost
  /// when the HUD is never mounted (e.g. release builds).
  static final FrameTimer sharedFrameTimer = FrameTimer();

  /// Master switch. Default true; bind to a debug-only setting if you
  /// want a runtime toggle. Always false in release via [kReleaseMode]
  /// gate inside [build].
  final bool enabled;

  @override
  State<PerfHud> createState() => _PerfHudState();
}

class _PerfHudState extends State<PerfHud> {
  Timer? _ticker;
  bool _expanded = false;

  FrameTimer get _frameTimer => PerfHud.sharedFrameTimer;

  @override
  void initState() {
    super.initState();
    if (kReleaseMode || !widget.enabled) return;
    if (!_frameTimer.isRunning) _frameTimer.start();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode || !widget.enabled) return const SizedBox.shrink();
    final ft = _frameTimer;
    if (ft.sampleCount == 0) return const SizedBox.shrink();
    final avg = ft.averageRasterMs;
    final p95 = ft.p95RasterMs;
    final drop = ft.frameDropRate * 100;
    final dropOver = drop > 1.5; // blueprint target
    final color =
        dropOver ? Colors.red.shade300 : Colors.greenAccent.shade100;

    return Positioned(
      right: 12,
      bottom: 80,
      child: Material(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              child: _expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'raster avg ${avg.toStringAsFixed(1)} ms',
                          style: const TextStyle(color: Colors.white),
                        ),
                        Text(
                          'raster p95 ${p95.toStringAsFixed(1)} ms',
                          style: const TextStyle(color: Colors.white),
                        ),
                        Text(
                          'drop rate ${drop.toStringAsFixed(2)}% '
                          '(target <1.5%)',
                          style: TextStyle(color: color),
                        ),
                        Text(
                          'samples ${ft.sampleCount}/${ft.windowSize}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    )
                  : Text(
                      'R ${avg.toStringAsFixed(1)}  '
                      'P95 ${p95.toStringAsFixed(1)}  '
                      'drop ${drop.toStringAsFixed(1)}%',
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
