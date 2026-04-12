import 'dart:async';

import 'package:flutter/foundation.dart';

/// Off-main-thread task runner.
///
/// Phase 1 implementation: wraps Flutter's [compute] so callers get a
/// simple `run` API without per-call isolate plumbing. Each `run` spawns
/// an ephemeral isolate; for ML inference we use `IsolateInterpreter` from
/// `flutter_litert` (Phase 9) which owns its own long-lived isolate.
///
/// Constraints (documented on behalf of the blueprint):
/// - Handlers must be top-level or static functions.
/// - Handlers CANNOT touch `dart:ui` — no `ui.Image`, no `FragmentShader`.
///   Decode-to-bytes must stay on the main isolate.
/// - Large payloads should be wrapped in [TransferableTypedData] to avoid
///   serialization copies.
///
/// When Phase 10's Rust export backend lands, we may revisit this with a
/// true long-lived pool if profiling shows the per-call isolate spawn
/// cost is non-trivial; today compute() suffices for EXIF, JSON, and
/// image_package_worker.
class WorkerPool {
  WorkerPool({this.size = 2});

  final int size;
  bool _disposed = false;

  bool get isInitialized => true;

  Future<void> init() async {
    // No-op for the compute-based implementation. Here for API symmetry
    // with a future long-lived-pool refactor.
  }

  /// Run [handler] in an isolate with [payload] as input. Returns the result.
  Future<R> run<Q, R>(
    ComputeCallback<Q, R> handler,
    Q payload, {
    String? debugLabel,
  }) {
    if (_disposed) {
      throw StateError('WorkerPool has been disposed');
    }
    return compute<Q, R>(
      handler,
      payload,
      debugLabel: debugLabel ?? 'WorkerPool.run',
    );
  }

  Future<void> dispose() async {
    _disposed = true;
  }
}
