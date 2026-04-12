import 'dart:typed_data';

import '../models/model_descriptor.dart';
import '../models/model_registry.dart';

/// Abstract interface for an on-device ML inference runtime.
///
/// Phase 9a ships two implementations:
///   - [LiteRtRuntime] wrapping `flutter_litert` for TFLite models
///   - [OrtRuntime] wrapping `onnxruntime_v2` for ONNX models
///
/// Higher-level feature plugins (background removal, face mesh,
/// inpainting, etc.) talk only to [MlRuntime] so we can swap the
/// underlying runtime without touching feature code.
///
/// Every runtime loads one [MlSession] per resolved model. Sessions
/// live on a dedicated isolate (see `isolate_interpreter_host.dart`)
/// so inference never blocks the main thread.
abstract class MlRuntime {
  /// The runtime family this instance serves. Routers / factories use
  /// this to dispatch from a [ModelDescriptor].
  ModelRuntime get runtime;

  /// Load a model from its [resolved] location. Returns a ready-to-run
  /// [MlSession]. Throws on failure — delegate fallback happens inside
  /// the concrete implementation.
  Future<MlSession> load(ResolvedModel resolved);

  /// Release any global resources (e.g. shared delegate handles).
  /// Called on session dispose; concrete impls may no-op.
  Future<void> close();
}

/// A loaded model ready to accept tensor inputs. One session is
/// created per model and reused across many inference calls.
abstract class MlSession {
  /// The descriptor used to load this session.
  ModelDescriptor get descriptor;

  /// Run one inference pass. [inputs] is a map from input tensor name
  /// to raw bytes; [outputs] in the returned map uses the same
  /// convention. Concrete runtimes validate shapes/dtypes internally
  /// and throw on mismatch.
  ///
  /// Called from inside an isolate via [IsolateInterpreterHost]; do
  /// NOT touch `dart:ui` from implementations.
  Future<Map<String, Uint8List>> run(Map<String, Uint8List> inputs);

  /// Free the interpreter + delegates. Safe to call multiple times.
  Future<void> close();
}

/// Thrown when a runtime can't load or run a model. The stage lets
/// callers distinguish loading errors (which may mean the file is
/// corrupted or the delegate is unsupported) from inference errors
/// (which usually mean a tensor-shape mismatch).
class MlRuntimeException implements Exception {
  const MlRuntimeException({
    required this.stage,
    required this.message,
    this.cause,
  });

  final MlRuntimeStage stage;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'MlRuntimeException(stage: $stage, message: $message, cause: $cause)';
}

enum MlRuntimeStage { load, run, close }
