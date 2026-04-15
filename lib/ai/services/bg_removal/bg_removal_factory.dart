import '../../../core/logging/app_logger.dart';
import '../../models/model_descriptor.dart';
import '../../models/model_registry.dart';

import '../../runtime/litert_runtime.dart';
import '../../runtime/ml_runtime.dart';
import '../../runtime/ort_runtime.dart';
import 'bg_removal_strategy.dart';
import 'media_pipe_bg_removal.dart';
import 'modnet_bg_removal.dart';
import 'rmbg_bg_removal.dart';

final _log = AppLogger('BgRemovalFactory');

/// Builds a concrete [BgRemovalStrategy] for a given [BgRemovalStrategyKind]
/// and resolves any required model dependencies via [ModelRegistry].
///
/// The factory does NOT initiate downloads — if a required model isn't
/// cached, [availability] returns [BgRemovalAvailability.downloadRequired]
/// and the UI is responsible for kicking off the fetch via
/// [ModelDownloader] before retrying. This keeps the factory pure and
/// easy to test.
///
/// A fresh strategy is created every time [create] is called. Callers
/// own the returned instance and must [BgRemovalStrategy.close] it.
class BgRemovalFactory {
  BgRemovalFactory({
    required this.registry,
    required this.liteRtRuntime,
    required this.ortRuntime,
  });

  final ModelRegistry registry;
  final LiteRtRuntime liteRtRuntime;
  final OrtRuntime ortRuntime;

  /// Check whether [kind] can be built right now. Returns one of:
  ///   - [BgRemovalAvailability.ready] → `create` will succeed
  ///   - [BgRemovalAvailability.downloadRequired] → model needs fetch
  ///   - [BgRemovalAvailability.unknownModel] → manifest missing entry
  Future<BgRemovalAvailability> availability(
      BgRemovalStrategyKind kind) async {
    if (!kind.isDownloadable) {
      // MediaPipe is always available.
      _log.d('availability', {'kind': kind.name, 'result': 'ready'});
      return BgRemovalAvailability.ready;
    }
    final modelId = kind.modelId!;
    final descriptor = registry.descriptor(modelId);
    if (descriptor == null) {
      _log.w('manifest missing descriptor', {'id': modelId});
      return BgRemovalAvailability.unknownModel;
    }
    final resolved = await registry.resolve(modelId);
    if (resolved == null) {
      _log.d('availability', {
        'kind': kind.name,
        'result': 'downloadRequired',
        'modelId': modelId,
      });
      return BgRemovalAvailability.downloadRequired;
    }
    _log.d('availability', {
      'kind': kind.name,
      'result': 'ready',
      'modelId': modelId,
      'source': resolved.isBundled ? 'bundled' : 'cached',
    });
    return BgRemovalAvailability.ready;
  }

  /// Build a concrete [BgRemovalStrategy] for [kind]. Throws
  /// [BgRemovalException] if the model isn't ready yet — call
  /// [availability] first and prompt for download when needed.
  ///
  /// Errors from the underlying runtime (file missing, delegate
  /// failure, ORT env init) are wrapped as [BgRemovalException] with
  /// the original exception preserved as [BgRemovalException.cause]
  /// so session-level logs can show the full chain.
  Future<BgRemovalStrategy> create(BgRemovalStrategyKind kind) async {
    _log.i('create start', {'kind': kind.name});
    switch (kind) {
      case BgRemovalStrategyKind.mediaPipe:
        final strategy = MediaPipeBgRemoval();
        _log.i('create success', {'kind': kind.name});
        return strategy;

      case BgRemovalStrategyKind.modnet:
        final resolved = await _resolveOrThrow(kind);
        if (resolved.descriptor.runtime != ModelRuntime.onnx) {
          _log.w('create rejected — wrong runtime', {
            'kind': kind.name,
            'expected': ModelRuntime.onnx.name,
            'actual': resolved.descriptor.runtime.name,
          });
          throw BgRemovalException(
            'MODNet descriptor has wrong runtime '
            '(${resolved.descriptor.runtime.name})',
            kind: kind,
          );
        }
        try {
          final session = await ortRuntime.load(resolved);
          _log.i('create success', {
            'kind': kind.name,
            'inputs': session.inputNames,
            'outputs': session.outputNames,
          });
          return ModNetBgRemoval(session: session);
        } on MlRuntimeException catch (e, st) {
          _log.e('create failed — ort load threw',
              error: e, stackTrace: st, data: {'kind': kind.name});
          throw BgRemovalException(e.message, kind: kind, cause: e);
        }

      case BgRemovalStrategyKind.rmbg:
        final resolved = await _resolveOrThrow(kind);
        if (resolved.descriptor.runtime != ModelRuntime.onnx) {
          _log.w('create rejected — wrong runtime', {
            'kind': kind.name,
            'expected': ModelRuntime.onnx.name,
            'actual': resolved.descriptor.runtime.name,
          });
          throw BgRemovalException(
            'RMBG descriptor has wrong runtime '
            '(${resolved.descriptor.runtime.name})',
            kind: kind,
          );
        }
        try {
          final session = await ortRuntime.load(resolved);
          _log.i('create success', {
            'kind': kind.name,
            'inputs': session.inputNames,
            'outputs': session.outputNames,
          });
          return RmbgBgRemoval(session: session);
        } on MlRuntimeException catch (e, st) {
          _log.e('create failed — ort load threw',
              error: e, stackTrace: st, data: {'kind': kind.name});
          throw BgRemovalException(e.message, kind: kind, cause: e);
        }
    }
  }

  Future<ResolvedModel> _resolveOrThrow(BgRemovalStrategyKind kind) async {
    final modelId = kind.modelId!;
    final descriptor = registry.descriptor(modelId);
    if (descriptor == null) {
      throw BgRemovalException(
        'Unknown model id: $modelId',
        kind: kind,
      );
    }
    final resolved = await registry.resolve(modelId);
    if (resolved == null) {
      throw BgRemovalException(
        'Model "$modelId" is not downloaded yet. '
        'Fetch it from the AI model manager and try again.',
        kind: kind,
      );
    }
    return resolved;
  }
}

/// Current availability of a [BgRemovalStrategyKind] from the
/// factory's perspective. The picker sheet uses this to render a
/// status chip + appropriate call-to-action.
enum BgRemovalAvailability {
  /// Strategy can be created right now.
  ready,

  /// Strategy needs a model download before [BgRemovalFactory.create]
  /// will succeed.
  downloadRequired,

  /// Manifest has no descriptor for this strategy's model id — a bug
  /// or a version mismatch between app and bundled manifest.
  unknownModel,
}
