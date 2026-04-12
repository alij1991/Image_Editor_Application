import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/utils/debouncer.dart';
import '../../../../engine/layers/content_layer.dart';
import '../../../../engine/pipeline/edit_pipeline.dart';
import '../../../../engine/pipeline/geometry_state.dart';
import '../../../../engine/rendering/shader_pass.dart';

final _log = AppLogger('PreviewController');

/// Holds the live render state for the preview path.
///
/// The blueprint's critical performance pattern is imperative state
/// updates for slider values with a 16 ms debounced commit. This
/// controller owns three independent ValueNotifiers so each subsystem
/// repaints only when its data changes:
///
///   - [passes]   — shader pass list (color chain)
///   - [geometry] — geometry transform (rotate/flip/straighten/crop)
///   - [layers]   — content layers (text / stickers / drawings) that
///     sit above the shader chain
class PreviewController {
  PreviewController({
    required FutureOr<void> Function(EditPipeline pipeline) onCommit,
    Duration commitDebounce = const Duration(milliseconds: 16),
  })  : _onCommit = onCommit,
        _commitDebouncer = Debouncer(duration: commitDebounce);

  final FutureOr<void> Function(EditPipeline pipeline) _onCommit;
  final Debouncer _commitDebouncer;

  final ValueNotifier<List<ShaderPass>> _passes = ValueNotifier(const []);
  final ValueNotifier<GeometryState> _geometry =
      ValueNotifier(GeometryState.identity);
  final ValueNotifier<List<ContentLayer>> _layers = ValueNotifier(const []);
  EditPipeline? _pendingCommit;

  ValueListenable<List<ShaderPass>> get passes => _passes;
  ValueListenable<GeometryState> get geometry => _geometry;
  ValueListenable<List<ContentLayer>> get layers => _layers;

  void setPasses(List<ShaderPass> newPasses) {
    _log.d('setPasses', {'count': newPasses.length});
    _passes.value = newPasses;
  }

  void setGeometry(GeometryState newGeometry) {
    if (_geometry.value == newGeometry) return;
    _log.d('setGeometry', {'state': newGeometry.toString()});
    _geometry.value = newGeometry;
  }

  void setLayers(List<ContentLayer> newLayers) {
    _log.d('setLayers', {'count': newLayers.length});
    _layers.value = newLayers;
  }

  void scheduleCommit(EditPipeline pipeline) {
    _pendingCommit = pipeline;
    _commitDebouncer.run(_flushCommit);
  }

  void _flushCommit() {
    final pending = _pendingCommit;
    _pendingCommit = null;
    if (pending != null) {
      _log.d('debounced commit firing', {'ops': pending.operations.length});
      _onCommit(pending);
    }
  }

  void flushCommit() {
    _log.d('flushCommit');
    _commitDebouncer.flush(_flushCommit);
  }

  void dispose() {
    _log.d('dispose');
    _commitDebouncer.dispose();
    _passes.dispose();
    _geometry.dispose();
    _layers.dispose();
  }
}
