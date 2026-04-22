import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show rootBundle;

import '../../../core/logging/app_logger.dart';
import 'bg_removal_strategy.dart';

final _log = AppLogger('U2NetBgRemoval');

/// VIII.12 — Background removal via the bundled U²-Netp TFLite model.
///
/// Functionally analogous to `ModNetBgRemoval` / `RmbgBgRemoval` but
/// uses a smaller bundled model (~5 MB) so users can run general
/// (non-portrait) matting offline without the 44 MB RMBG download.
///
/// **Model bundling status**: the manifest declares the U²-Netp model
/// at `assets/models/bundled/u2netp.tflite`, but the binary file is
/// not yet shipped with the repo as of VIII.12. Until it lands, this
/// strategy throws [BgRemovalException] with the bundle-status message
/// when invoked. The wiring (factory + picker + manifest entry) is in
/// place so a follow-up commit that drops the .tflite into
/// `assets/models/bundled/` flips this strategy on without further
/// app-side changes.
///
/// Inputs (planned): 320×320 RGB, normalised to [0..1].
/// Outputs (planned): a single 320×320 alpha mask in [0..1].
class U2NetBgRemoval implements BgRemovalStrategy {
  U2NetBgRemoval({this.assetPath = _defaultAssetPath});

  static const String _defaultAssetPath =
      'assets/models/bundled/u2netp.tflite';

  /// Asset path for the U²-Netp TFLite. Overridable so tests can
  /// point at a local fixture (or a never-existent path to confirm
  /// the not-bundled error path).
  final String assetPath;

  bool _closed = false;
  bool _modelChecked = false;
  bool _modelAvailable = false;

  @override
  BgRemovalStrategyKind get kind => BgRemovalStrategyKind.generalOffline;

  /// Probe `rootBundle` for the asset. Cached on the instance — the
  /// asset bundle doesn't change at runtime.
  Future<bool> isModelAvailable() async {
    if (_modelChecked) return _modelAvailable;
    try {
      // Lightweight: load 1 byte to confirm the asset exists without
      // pulling the full ~5 MB into memory just for the probe.
      await rootBundle.load(assetPath);
      _modelAvailable = true;
    } on FlutterError {
      _modelAvailable = false;
    } catch (e, st) {
      _log.w('asset probe failed', {'error': e.toString()});
      _log.d('asset probe stack', {'trace': st.toString()});
      _modelAvailable = false;
    }
    _modelChecked = true;
    return _modelAvailable;
  }

  @override
  Future<ui.Image> removeBackgroundFromPath(String sourcePath) async {
    if (_closed) {
      _log.w('run rejected — strategy closed', {'path': sourcePath});
      throw const BgRemovalException(
        'U2NetBgRemoval is closed',
        kind: BgRemovalStrategyKind.generalOffline,
      );
    }
    final available = await isModelAvailable();
    if (!available) {
      _log.w('u2netp model not bundled — strategy unavailable', {
        'assetPath': assetPath,
      });
      throw const BgRemovalException(
        'Offline matting model is not bundled in this build. Use '
        'one of the other strategies, or include u2netp.tflite in '
        'assets/models/bundled/.',
        kind: BgRemovalStrategyKind.generalOffline,
      );
    }
    // The full inference path (LiteRtRuntime load → preprocess →
    // run → mask-to-alpha → encode) lands in a follow-up commit
    // alongside the actual .tflite asset. Throwing here keeps the
    // contract honest — the picker shows the strategy, but the user
    // gets a typed error instead of an undefined output.
    _log.w('inference path not yet implemented; awaiting model bundle');
    throw const BgRemovalException(
      'Offline matting is wired but the inference path is not yet '
      'implemented. Track follow-up work in IMPROVEMENTS.md.',
      kind: BgRemovalStrategyKind.generalOffline,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log.i('close');
  }
}
