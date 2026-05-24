import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime_v2/onnxruntime_v2.dart' as ort;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
/// [ort.OrtSession.runAsync] — a **persistent worker isolate** that
/// stays alive across calls on the same session (Phase V.8). The
/// package previously spun a fresh isolate per call
/// (`runOnceAsync`), which paid ~5–10 ms of setup on every inference
/// — a significant fraction of small-input runs that themselves
/// take only 20–50 ms (RMBG, portrait matting). Switching to
/// `runAsync` amortises the spawn across the session lifetime.
///
/// Trade-off: `runAsync` serializes inference on the single
/// persistent isolate. Two concurrent `runTyped` calls queue behind
/// each other rather than running in parallel. Every call site in
/// the app is sequential (one AI feature at a time, user-driven),
/// so this matches real usage — parallel inference, if ever needed,
/// should opt in per-call via a dedicated helper.
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
  Future<OrtV2Session> load(ResolvedModel resolved) =>
      _loadInternal(resolved, useCoreML: false);

  /// Phase XVI.76 — opt-in CoreML execution provider for models that
  /// blow the iOS app-memory ceiling on pure CPU.
  ///
  /// CoreML is registered with `enableOnSubgraph` so ORT partitions
  /// the model: ops CoreML can map (Conv, MatMul, the bulk of Swin /
  /// transformer kernels) go to the Apple Neural Engine (memory off
  /// the app's 3376 MB ceiling), and exotic ops stay on CPU. We do
  /// NOT use the default `useNone` flag — that only kicks in for
  /// WHOLE-model offload, and any single unsupported op in BiRefNet's
  /// 4059-node graph would silently fall back to all-CPU.
  ///
  /// Risk: CoreML compiles the offloaded subgraph at session-create
  /// time, which itself can spike memory by 1–3 GB on big models.
  /// If the compile pushes us over the ceiling, the process crashes
  /// during `OrtSession.fromFile` BEFORE Dart sees an exception, so
  /// there's no graceful catch. The mitigation is to keep BiRefNet
  /// (and any other CoreML-only model) gated behind a deliberate
  /// user tap on the picker, never on the auto-init path.
  ///
  /// Any Dart-visible failure (subgraph compile error, op not
  /// supported, etc.) downgrades cleanly to the CPU-only `load`
  /// path so the model still loads even when CoreML refuses.
  Future<OrtV2Session> loadWithCoreML(ResolvedModel resolved) async {
    try {
      return await _loadInternal(resolved, useCoreML: true);
    } catch (e) {
      _log.w(
        'CoreML load failed — falling back to CPU-only path. '
        'This may OOM during inference for memory-heavy models.',
        {
          'id': resolved.descriptor.id,
          'error': e.toString().split('\n').first,
        },
      );
      // Don't re-throw the CoreML failure — give CPU a chance. If CPU
      // also fails (e.g. external-data regression), THAT exception
      // surfaces.
      try {
        return await _loadInternal(resolved, useCoreML: false);
      } catch (cpuError, cpuSt) {
        _log.e('CPU-only fallback also failed',
            error: cpuError, stackTrace: cpuSt,
            data: {'id': resolved.descriptor.id});
        throw MlRuntimeException(
          stage: MlRuntimeStage.load,
          message:
              'OrtSession creation failed under both CoreML and CPU-only '
              'paths. CoreML error: ${e.toString().split("\n").first}. '
              'CPU error: $cpuError',
          cause: cpuError,
        );
      }
    }
  }

  Future<OrtV2Session> _loadInternal(
    ResolvedModel resolved, {
    required bool useCoreML,
  }) async {
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
    File file;
    if (resolved.isBundled) {
      // Phase XVI.64 — bundled ONNX support. ORT (like LiteRT) takes a
      // file path, not a byte buffer, so we copy the asset bytes to a
      // temp file once and pass that path to the session. Mirrors the
      // pattern in `LiteRtRuntime.load` for bundled `.tflite` models;
      // earlier rev rejected this branch outright with a "not yet
      // supported" exception.
      final assetKey = resolved.localPath;
      _log.d('copying bundled asset to temp file', {
        'id': resolved.descriptor.id,
        'asset': assetKey,
      });
      try {
        final data = await rootBundle.load(assetKey);
        final tempDir = await getTemporaryDirectory();
        final tempPath = p.join(
          tempDir.path,
          'ort_${resolved.descriptor.id}.onnx',
        );
        file = File(tempPath);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        _log.d('bundled asset copied', {
          'id': resolved.descriptor.id,
          'tempPath': tempPath,
          'bytes': await file.length(),
        });
      } catch (e, st) {
        _log.e('bundled asset copy failed', error: e, stackTrace: st);
        throw MlRuntimeException(
          stage: MlRuntimeStage.load,
          message: 'Failed to copy bundled ONNX model to temp file: $e',
          cause: e,
        );
      }
    } else {
      file = File(resolved.localPath);
    }
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
    // CoreML EP — opted in per-model via [loadWithCoreML]. Default
    // (CPU/XNNPACK) is fast enough for our quantized models. CoreML
    // is the escape hatch for models whose intermediate-tensor memory
    // exceeds the iOS app-memory ceiling (3376 MB on iPhone 15 Pro
    // Max). With `enableOnSubgraph`, ORT partitions the model so
    // CoreML-mappable ops run on ANE (memory off the app budget) and
    // the rest stays on CPU. See [loadWithCoreML] docstring for the
    // full rationale.
    if (useCoreML && Platform.isIOS) {
      try {
        final accepted = options.appendCoreMLProvider(
          ort.CoreMLFlags.enableOnSubgraph,
        );
        _log.i('CoreML provider appended', {
          'id': resolved.descriptor.id,
          'accepted': accepted,
        });
      } catch (e) {
        _log.w('CoreML provider append failed — continuing without it',
            {'error': e.toString()});
      }
    }
    try {
      options.setInterOpNumThreads(2);
      options.setIntraOpNumThreads(2);
    } catch (e) {
      _log.w('thread config failed', {'error': e.toString()});
    }

    // Phase XVI.70 / XVI.74 — two-pass session creation.
    //
    // First pass uses default graph optimisation (ORT_ENABLE_ALL):
    // shape inference + operator fusion + memory planning, which
    // are essential for keeping inference RAM in budget on iOS.
    //
    // Second pass fires only if the first throws the specific
    // "Cannot parse data from external tensors" error — a known
    // regression in ORT 1.23.0 (microsoft/onnxruntime#26261) where
    // models using ONNX's in-memory external-data optimisation
    // (e.g. BiRefNet-Lite from onnx-community) crash the bundled
    // native lib's shape-inference pass during constant folding.
    //
    // XVI.74 patched ios/Podfile to override `onnxruntime-objc` to
    // 1.24.3 (the first CocoaPods-published version above 1.23.0,
    // containing PR #26263's fix), so on iOS this fallback should
    // be DEAD CODE. We keep it as a safety net for:
    //   - Android, which routes through a separate runtime build.
    //   - Anyone running with the unmodified package (no Podfile
    //     override) — they'll at least get a working session
    //     instead of a hard crash, just at higher memory cost.
    //
    // Runtime cost when fallback fires: slightly higher inference
    // latency AND substantially higher peak memory (no operator
    // fusion, no pre-computed shape constants, intermediate
    // tensors can't be re-planned). For a 244 MB model like
    // BiRefNet the difference is OOM vs. fits — which is the
    // whole reason XVI.74 attacked the root cause.
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
      final isExternalDataError = _isExternalDataParseError(e);
      if (!isExternalDataError) {
        _log.e('session create failed',
            error: e, stackTrace: st, data: {'id': resolved.descriptor.id});
        options.release();
        throw MlRuntimeException(
          stage: MlRuntimeStage.load,
          message: 'OrtSession creation failed: $e',
          cause: e,
        );
      }
      // Recoverable: retry with graph optimisation disabled so ORT
      // skips the shape-inference pass that 1.23.0 mishandles for
      // in-memory external-data tensors.
      _log.w(
        'session create hit ORT 1.23.0 external-data regression — '
        'retrying with graph optimisation disabled',
        {
          'id': resolved.descriptor.id,
          'firstAttemptError': e.toString().split('\n').first,
        },
      );
      options.release();
      final retryOptions = ort.OrtSessionOptions();
      try {
        retryOptions.setInterOpNumThreads(2);
        retryOptions.setIntraOpNumThreads(2);
      } catch (e) {
        _log.w('retry thread config failed', {'error': e.toString()});
      }
      try {
        retryOptions.setSessionGraphOptimizationLevel(
          ort.GraphOptimizationLevel.ortDisableAll,
        );
      } catch (e) {
        _log.w('retry: disable-optimizations call failed', {
          'error': e.toString(),
        });
      }
      try {
        final session = ort.OrtSession.fromFile(file, retryOptions);
        _log.i('session built (graph-opt-disabled fallback)', {
          'id': resolved.descriptor.id,
          'inputs': session.inputNames,
          'outputs': session.outputNames,
        });
        return OrtV2Session._(
          descriptor: resolved.descriptor,
          session: session,
          options: retryOptions,
        );
      } catch (retryError, retrySt) {
        _log.e('session create failed even with optimisations disabled',
            error: retryError,
            stackTrace: retrySt,
            data: {'id': resolved.descriptor.id});
        retryOptions.release();
        throw MlRuntimeException(
          stage: MlRuntimeStage.load,
          message:
              'OrtSession creation failed (both default and optimisation-'
              'disabled retries). This is likely the ORT 1.23.0 in-memory '
              'external-data regression — re-bake the model with '
              '`scripts/onnx_export/inline_onnx_model.py` and re-host the '
              'inlined file. Original error: $retryError',
          cause: retryError,
        );
      }
    }
  }

  /// Phase XVI.70 — detect the specific ORT 1.23.0 in-memory
  /// external-data parse failure. The error message contains the
  /// signature substring "Cannot parse data from external tensors";
  /// any other failure (file missing, wrong shape, unsupported op)
  /// is non-recoverable and surfaces through the normal error path.
  static bool _isExternalDataParseError(Object error) {
    final msg = error.toString();
    return msg.contains('Cannot parse data from external tensors');
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
  /// **Phase V.8**: uses [ort.OrtSession.runAsync], which keeps a
  /// single persistent isolate alive across calls on this session.
  /// The ~5–10 ms isolate-spawn cost of the pre-V.8 `runOnceAsync`
  /// is paid once per session instead of once per call; a 10-call
  /// inference loop on a small model sees 50–100 ms lifted. The
  /// persistent isolate is torn down in [close] via
  /// `_session.release()` (which calls `killAllIsolates` internally).
  ///
  /// [debugRunCount] increments on every call so tests + logs can
  /// pin the inference-count invariants without needing access to
  /// a real ONNX model.
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
      _debugRunCount++;
      // `runAsync` can return `null` when the persistent isolate
      // was released mid-call. Treat that as a typed run-stage
      // failure — the caller's retry path (e.g. bg-removal
      // fallback) is the right recovery.
      final result = await _session.runAsync(runOptions, inputs, outputNames);
      if (result == null) {
        _log.w('runTyped: runAsync returned null — isolate likely released',
            {'id': descriptor.id});
        throw const MlRuntimeException(
          stage: MlRuntimeStage.run,
          message: 'ONNX inference returned null — persistent isolate '
              'was torn down mid-call',
        );
      }
      return result;
    } on MlRuntimeException {
      rethrow;
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

  /// Diagnostic counter: number of times [runTyped] has been
  /// invoked on this session (successful + failed). Phase V.8 tests
  /// pin "N calls + 1 session = 1 persistent isolate, many
  /// inferences" by reading this counter alongside integration
  /// signals.
  @visibleForTesting
  int get debugRunCount => _debugRunCount;
  int _debugRunCount = 0;

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
      // Phase V.8: `OrtSession.release()` calls `killAllIsolates()`
      // internally before freeing the native session — this tears
      // down both the persistent `runAsync` worker AND any active
      // `runOnceAsync` isolates. No separate stopPersistentIsolate
      // call needed.
      await _session.release();
    } catch (e) {
      _log.w('session release failed', {'error': e.toString()});
    }
    try {
      _options.release();
    } catch (e) {
      _log.w('options release failed', {'error': e.toString()});
    }
    _log.d('session close', {
      'id': descriptor.id,
      'totalRunCalls': _debugRunCount,
    });
  }
}
