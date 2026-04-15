import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;

import '../../core/logging/app_logger.dart';
import '../models/model_descriptor.dart';
import '../models/model_registry.dart';
import 'delegate_selector.dart';
import 'ml_runtime.dart';

final _log = AppLogger('OrtRuntime');

/// Real `onnxruntime_v2`-backed implementation of [MlRuntime].
///
/// Loads a `.onnx` file from disk and wraps it in an [ort.OrtSession]
/// with execution providers picked by [DelegateSelector.preferredOnnxChain].
/// The concrete [OrtV2Session] returned from [load] runs inference via
/// `runOnceAsync`, which spins up a fresh isolate per call — this
/// matches the "runs off the main thread" invariant of the 9a
/// abstraction without requiring a persistent worker.
///
/// Phase 9c uses this for RMBG-1.4 (downloadable, 46 MB). Phase 9g
/// reuses it for LaMa inpainting (208 MB). Env initialization is
/// idempotent: the first call to [load] lazily initializes `OrtEnv`.
class OrtRuntime implements MlRuntime {
  OrtRuntime({required this.selector});

  final DelegateSelector selector;
  bool _envInitialized = false;

  @override
  ModelRuntime get runtime => ModelRuntime.onnx;

  @override
  Future<OrtV2Session> load(ResolvedModel resolved) async {
    if (resolved.descriptor.runtime != ModelRuntime.onnx) {
      _log.w('load rejected — wrong runtime', {
        'id': resolved.descriptor.id,
        'expected': ModelRuntime.onnx.name,
        'actual': resolved.descriptor.runtime.name,
      });
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message:
            'OrtRuntime cannot load ${resolved.descriptor.runtime.name} '
            'model ${resolved.descriptor.id}',
      );
    }
    if (resolved.isBundled) {
      _log.w('load rejected — bundled models not yet supported', {
        'id': resolved.descriptor.id,
        'assetPath': resolved.localPath,
      });
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message:
            'Bundled ONNX models are not yet supported by OrtRuntime '
            '(id=${resolved.descriptor.id}). ONNX bundled assets would need '
            'a temp-file copy; Phase 9g adds that if needed.',
      );
    }
    final file = File(resolved.localPath);
    if (!await file.exists()) {
      _log.w('load rejected — file not found', {
        'id': resolved.descriptor.id,
        'path': resolved.localPath,
      });
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message: 'Model file not found: ${resolved.localPath}',
      );
    }

    // Initialize the env lazily. Safe to call more than once — the
    // underlying `init()` is idempotent within the package.
    if (!_envInitialized) {
      try {
        ort.OrtEnv.instance.init();
        _envInitialized = true;
        _log.d('ort env initialized', {'version': ort.OrtEnv.version});
      } catch (e, st) {
        _log.e('ort env init failed', error: e, stackTrace: st);
        throw MlRuntimeException(
          stage: MlRuntimeStage.load,
          message: 'Failed to initialize ONNX Runtime environment: $e',
          cause: e,
        );
      }
    }

    final chain = selector.preferredOnnxChain();
    _log.i('load', {
      'id': resolved.descriptor.id,
      'path': resolved.localPath,
      'sizeBytes': await file.length(),
      'providers': chain.map((d) => d.label).toList(),
    });

    final options = ort.OrtSessionOptions();
    // Skip CoreML: it tries to compile the entire ONNX graph into a
    // CoreML model at runtime, consuming 2-3 GB of memory and OOM-
    // killing the app on devices with ≤4 GB RAM. CPU/XNNPACK is fast
    // enough for the quantized models we use (~2-5 s on A17 Pro).
    try {
      options.setInterOpNumThreads(2);
      options.setIntraOpNumThreads(2);
    } catch (e) {
      _log.w('thread config failed', {'error': e.toString()});
    }

    try {
      final session = ort.OrtSession.fromFile(file, options);
      _log.i('session built', {
        'id': resolved.descriptor.id,
        'inputs': session.inputNames,
        'outputs': session.outputNames,
      });
      return OrtV2Session._(
        descriptor: resolved.descriptor,
        session: session,
        options: options,
      );
    } catch (e, st) {
      _log.e('session create failed',
          error: e, stackTrace: st, data: {'id': resolved.descriptor.id});
      options.release();
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message: 'OrtSession creation failed: $e',
        cause: e,
      );
    }
  }

  @override
  Future<void> close() async {
    _log.d('close');
    if (_envInitialized) {
      try {
        ort.OrtEnv.instance.release();
        _envInitialized = false;
      } catch (e) {
        _log.w('ort env release failed', {'error': e.toString()});
      }
    }
  }
}

/// A loaded ONNX Runtime session. Feature code calls [runTyped] with
/// pre-built [ort.OrtValue] inputs; byte-level [MlSession.run] throws
/// for the same reason LiteRT does (ONNX tensors are typed).
class OrtV2Session implements MlSession {
  OrtV2Session._({
    required this.descriptor,
    required ort.OrtSession session,
    required ort.OrtSessionOptions options,
  })  : _session = session,
        _options = options;

  @override
  final ModelDescriptor descriptor;

  final ort.OrtSession _session;
  final ort.OrtSessionOptions _options;
  bool _closed = false;

  /// Input tensor names in the model's declared order.
  List<String> get inputNames => _session.inputNames;

  /// Output tensor names in the model's declared order.
  List<String> get outputNames => _session.outputNames;

  /// Run one inference pass asynchronously. [inputs] is a map from
  /// input tensor name to pre-built [ort.OrtValue]. Returns the list
  /// of output tensors in `outputNames` order (any of which may be
  /// null if the run produced fewer outputs).
  ///
  /// `runOnceAsync` creates a fresh isolate per call so the main
  /// thread stays interactive. Callers should reuse the [OrtV2Session]
  /// across many inference calls — the session + options are the
  /// expensive resources.
  Future<List<ort.OrtValue?>> runTyped(
    Map<String, ort.OrtValue> inputs, {
    List<String>? outputNames,
  }) async {
    if (_closed) {
      throw const MlRuntimeException(
        stage: MlRuntimeStage.run,
        message: 'OrtV2Session is closed',
      );
    }
    final runOptions = ort.OrtRunOptions();
    try {
      final outputs = await _session.runOnceAsync(
        runOptions,
        inputs,
        outputNames,
      );
      return outputs;
    } catch (e, st) {
      _log.e('runTyped failed',
          error: e, stackTrace: st, data: {'id': descriptor.id});
      throw MlRuntimeException(
        stage: MlRuntimeStage.run,
        message: e.toString(),
        cause: e,
      );
    }
  }

  @override
  Future<Map<String, Uint8List>> run(Map<String, Uint8List> inputs) async {
    throw const MlRuntimeException(
      stage: MlRuntimeStage.run,
      message:
          'OrtV2Session: use runTyped() instead — byte-level run is not '
          'supported because ONNX tensors are typed, not opaque bytes.',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      // OrtSession.release() already kills the persistent + all
      // active isolates internally before freeing the native session.
      await _session.release();
    } catch (e) {
      _log.w('session release failed', {'error': e.toString()});
    }
    try {
      _options.release();
    } catch (e) {
      _log.w('options release failed', {'error': e.toString()});
    }
    _log.d('session close', {'id': descriptor.id});
  }
}
