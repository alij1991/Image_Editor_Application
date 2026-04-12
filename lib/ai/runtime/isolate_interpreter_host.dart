import 'dart:typed_data';

import '../../core/logging/app_logger.dart';
import '../models/model_descriptor.dart';
import 'ml_runtime.dart';

final _log = AppLogger('IsolateInterpreterHost');

/// Proxy around an [MlSession] that serializes all `run` calls
/// through a single-lane queue.
///
/// Phase 9a ships this as an **in-isolate proxy** — the host runs on
/// the same isolate as the caller but still guarantees:
///
///   - Calls never overlap (sequentialized per session)
///   - Disposed sessions fail fast instead of crashing
///   - Telemetry wrapping (duration, success/failure) on every run
///
/// Phase 9c replaces the serial queue with a true long-lived
/// [Isolate] so inference runs off the main thread. The public API
/// doesn't change — callers write against [IsolateInterpreterHost]
/// from the start.
class IsolateInterpreterHost {
  IsolateInterpreterHost(this._session);

  final MlSession _session;
  Future<Map<String, Uint8List>>? _inflight;
  bool _closed = false;

  /// The descriptor of the model this host serves.
  ModelDescriptor get descriptor => _session.descriptor;

  /// True if the host has been closed and is no longer usable.
  bool get isClosed => _closed;

  /// Run one inference pass. Concurrent calls from the same host
  /// serialize — the second call awaits the first before starting.
  Future<Map<String, Uint8List>> run(Map<String, Uint8List> inputs) async {
    if (_closed) {
      throw const MlRuntimeException(
        stage: MlRuntimeStage.run,
        message: 'IsolateInterpreterHost is closed',
      );
    }
    // Queue behind any in-flight run.
    while (_inflight != null) {
      try {
        await _inflight;
      } catch (_) {
        // The prior run failed; surface its error to its own caller
        // and proceed with our own run.
      }
    }
    final completer = _runOne(inputs);
    _inflight = completer;
    try {
      return await completer;
    } finally {
      if (identical(_inflight, completer)) _inflight = null;
    }
  }

  Future<Map<String, Uint8List>> _runOne(
    Map<String, Uint8List> inputs,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final result = await _session.run(inputs);
      sw.stop();
      _log.d('run', {
        'id': _session.descriptor.id,
        'ms': sw.elapsedMilliseconds,
        'outputs': result.length,
      });
      return result;
    } catch (e, st) {
      sw.stop();
      _log.e(
        'run failed',
        error: e,
        stackTrace: st,
        data: {
          'id': _session.descriptor.id,
          'ms': sw.elapsedMilliseconds,
        },
      );
      rethrow;
    }
  }

  /// Close the session and release any resources. Safe to call
  /// multiple times.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close', {'id': _session.descriptor.id});
    await _session.close();
  }
}
