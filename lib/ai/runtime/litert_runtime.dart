import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_litert/flutter_litert.dart' as tfl;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../models/model_descriptor.dart';
import '../models/model_registry.dart';
import 'delegate_selector.dart';
import 'ml_runtime.dart';

final _log = AppLogger('LiteRtRuntime');

/// Real `flutter_litert`-backed implementation of [MlRuntime].
///
/// Loads a `.tflite` file from disk (or bundled asset path), walks the
/// preferred delegate chain until an interpreter builds cleanly, and
/// wraps the result in an [tfl.IsolateInterpreter] so inference runs
/// off the main thread.
///
/// Phase 9c wires the full load/run path but only exercises it with
/// downloadable models (MODNet for portrait matting). Bundled models
/// declared as `runtime: litert` in the manifest are loaded through
/// the same path starting in Phase 9f (face mesh) and later.
///
/// The returned [LiteRtSession] exposes a typed [LiteRtSession.runTyped]
/// method that accepts nested `List<List<List<List<double>>>>` inputs
/// (the form `flutter_litert`'s `runForMultipleInputs` expects) in
/// addition to the opaque byte-level [MlSession.run] from the base
/// interface.
class LiteRtRuntime implements MlRuntime {
  LiteRtRuntime({required this.selector});

  final DelegateSelector selector;

  @override
  ModelRuntime get runtime => ModelRuntime.litert;

  @override
  Future<LiteRtSession> load(ResolvedModel resolved) async {
    if (resolved.descriptor.runtime != ModelRuntime.litert) {
      _log.w('load rejected — wrong runtime', {
        'id': resolved.descriptor.id,
        'expected': ModelRuntime.litert.name,
        'actual': resolved.descriptor.runtime.name,
      });
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message:
            'LiteRtRuntime cannot load ${resolved.descriptor.runtime.name} '
            'model ${resolved.descriptor.id}',
      );
    }
    File file;
    if (resolved.isBundled) {
      // Bundled models live behind rootBundle (asset key). Copy to a
      // temp file so the TFLite interpreter can open it via file path.
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
          'litert_${resolved.descriptor.id}.tflite',
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
          message: 'Failed to copy bundled model to temp file: $e',
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

    final chain = selector.preferredChain();
    _log.i('load', {
      'id': resolved.descriptor.id,
      'path': resolved.localPath,
      'sizeBytes': await file.length(),
      'delegates': chain.map((d) => d.label).toList(),
    });

    // Walk the delegate chain, catching errors, until one succeeds.
    //
    // IMPORTANT: If `Interpreter.fromFile` throws, the attached
    // delegate + options leak unless we explicitly tear them down.
    // The build helper returns both so the failure path can release
    // the native resources without a follow-up interpreter probe.
    tfl.Interpreter? interpreter;
    TfLiteDelegate? selectedDelegate;
    final delegateErrors = <String, String>{};
    for (final delegate in chain) {
      final build = _buildOptionsFor(delegate);
      try {
        interpreter = tfl.Interpreter.fromFile(file, options: build.options);
        selectedDelegate = delegate;
        _log.i('interpreter built', {
          'id': resolved.descriptor.id,
          'delegate': delegate.label,
        });
        break;
      } catch (e) {
        delegateErrors[delegate.label] = e.toString();
        _log.w('delegate build failed', {
          'id': resolved.descriptor.id,
          'delegate': delegate.label,
          'error': e.toString(),
        });
        // Release native handles we just created for the failed try.
        try {
          build.delegate?.delete();
        } catch (_) {
          // ignore — best effort
        }
        try {
          build.options.delete();
        } catch (_) {
          // ignore — best effort
        }
      }
    }
    if (interpreter == null || selectedDelegate == null) {
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message: 'Could not build interpreter for ${resolved.descriptor.id} '
            'with any delegate. Attempts: $delegateErrors',
      );
    }

    try {
      final isolate = await tfl.IsolateInterpreter.create(
        address: interpreter.address,
        debugName: 'LiteRt_${resolved.descriptor.id}',
      );
      return LiteRtSession._(
        descriptor: resolved.descriptor,
        interpreter: interpreter,
        isolate: isolate,
        delegate: selectedDelegate,
      );
    } catch (e, st) {
      _log.e('isolate interpreter create failed',
          error: e, stackTrace: st, data: {'id': resolved.descriptor.id});
      interpreter.close();
      throw MlRuntimeException(
        stage: MlRuntimeStage.load,
        message: 'IsolateInterpreter creation failed: $e',
        cause: e,
      );
    }
  }

  /// Build `InterpreterOptions` for a given [delegate]. Phase 9c wires
  /// the Android GPU path (`GpuDelegateV2`) and the iOS/macOS Metal
  /// path (`GpuDelegate`) and falls through to the default XNNPACK/CPU
  /// options for every other delegate kind. We intentionally don't
  /// wire NNAPI / CoreML yet — those delegates have known compatibility
  /// quirks and Phase 9d will introduce runtime probing + disable lists.
  ///
  /// Returns both the options and the raw delegate so the caller can
  /// release them individually on a failed interpreter build.
  _DelegateBuild _buildOptionsFor(TfLiteDelegate delegate) {
    final options = tfl.InterpreterOptions();
    // MODNet uses standard ops, but MediaPipe models (face_mesh etc.)
    // need the transposed-conv custom op. Registering it always is
    // cheap and future-proofs Phase 9f.
    options.addMediaPipeCustomOps();
    options.threads = 2;

    tfl.Delegate? raw;
    switch (delegate) {
      case TfLiteDelegate.gpu:
        if (defaultTargetPlatform == TargetPlatform.android) {
          raw = tfl.GpuDelegateV2();
          options.addDelegate(raw);
        } else if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          raw = tfl.GpuDelegate();
          options.addDelegate(raw);
        }
        break;
      case TfLiteDelegate.xnnpack:
      case TfLiteDelegate.cpu:
      case TfLiteDelegate.nnapi:
      case TfLiteDelegate.coreml:
        // XNNPACK is on by default; CPU is the no-delegate baseline;
        // NNAPI / CoreML are intentionally not wired yet (see doc).
        break;
    }
    return _DelegateBuild(options: options, delegate: raw);
  }

  @override
  Future<void> close() async {
    _log.d('close');
  }
}

/// A loaded LiteRT session wrapping a `flutter_litert` interpreter and
/// its paired [tfl.IsolateInterpreter]. The base [MlSession.run]
/// interface (byte maps) throws — feature code calls [runTyped]
/// instead, which forwards nested Dart lists directly to the isolate
/// interpreter.
class LiteRtSession implements MlSession {
  LiteRtSession._({
    required this.descriptor,
    required tfl.Interpreter interpreter,
    required tfl.IsolateInterpreter isolate,
    required this.delegate,
  })  : _interpreter = interpreter,
        _isolate = isolate;

  @override
  final ModelDescriptor descriptor;

  final tfl.Interpreter _interpreter;
  final tfl.IsolateInterpreter _isolate;
  final TfLiteDelegate delegate;
  bool _closed = false;

  /// The microsecond duration of the most recent native inference.
  /// Read after [runTyped] for latency telemetry.
  int get lastInferenceMicros =>
      _interpreter.lastNativeInferenceDurationMicroSeconds;

  /// Typed inference call that accepts nested Dart lists / typed data
  /// directly. [inputs] is one entry per input tensor in the model's
  /// declared order; [outputs] is keyed by output tensor index.
  ///
  /// Runs on the interpreter's background isolate so the main thread
  /// stays interactive.
  Future<void> runTyped(
    List<Object> inputs,
    Map<int, Object> outputs,
  ) async {
    if (_closed) {
      throw const MlRuntimeException(
        stage: MlRuntimeStage.run,
        message: 'LiteRtSession is closed',
      );
    }
    try {
      await _isolate.runForMultipleInputs(inputs, outputs);
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
          'LiteRtSession: use runTyped() instead — byte-level run is not '
          'supported because TFLite models have typed tensors, not opaque bytes.',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _isolate.close();
    } catch (e) {
      _log.w('isolate close failed', {'error': e.toString()});
    }
    try {
      _interpreter.close();
    } catch (e) {
      _log.w('interpreter close failed', {'error': e.toString()});
    }
    _log.d('session close', {'id': descriptor.id});
  }
}

/// Bundles an [tfl.InterpreterOptions] with the raw [tfl.Delegate] it
/// attached, if any. Returned by [LiteRtRuntime._buildOptionsFor] so
/// the caller can release both on a failed `Interpreter.fromFile`
/// call — otherwise native memory leaks per retry.
class _DelegateBuild {
  const _DelegateBuild({required this.options, this.delegate});

  final tfl.InterpreterOptions options;
  final tfl.Delegate? delegate;
}
