import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/download_progress.dart';
import 'package:image_editor/ai/models/model_cache.dart';
import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/features/settings/presentation/widgets/model_manager_status.dart';

/// XVI.121 — the Model Manager row's render state. The regression this
/// locks: a DownloadQueued progress used to fall through to
/// `downloadable`, so a queued model rendered a live Download button
/// that swallowed re-taps. `queued` must win.
ModelDescriptor _descriptor({bool bundled = false, String version = '1.0'}) =>
    ModelDescriptor(
      id: 'm',
      version: version,
      runtime: ModelRuntime.onnx,
      sizeBytes: 100,
      sha256: 'a' * 64,
      bundled: bundled,
      url: bundled ? null : 'https://example.com/m.onnx',
      assetPath: bundled ? 'assets/models/bundled/m.tflite' : null,
    );

ModelCacheEntry _entry({String version = '1.0'}) => ModelCacheEntry(
      modelId: 'm',
      version: version,
      path: '/tmp/m.onnx',
      sizeBytes: 100,
      sha256: 'a' * 64,
      downloadedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

void main() {
  group('modelManagerStatusFor (XVI.121)', () {
    test('DownloadQueued maps to queued, NOT downloadable', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(),
          progress: const DownloadQueued(modelId: 'm'),
          entry: null,
        ),
        ModelManagerStatus.queued,
      );
    });

    test('queued wins even when a cache entry already exists', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(),
          progress: const DownloadQueued(modelId: 'm'),
          entry: _entry(),
        ),
        ModelManagerStatus.queued,
      );
    });

    test('DownloadRunning maps to downloading', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(),
          progress: const DownloadRunning(
            modelId: 'm',
            receivedBytes: 1,
            totalBytes: 10,
          ),
          entry: null,
        ),
        ModelManagerStatus.downloading,
      );
    });

    test('DownloadFailed maps to failed', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(),
          progress: const DownloadFailed(
            modelId: 'm',
            stage: DownloadFailureStage.network,
            message: 'x',
          ),
          entry: null,
        ),
        ModelManagerStatus.failed,
      );
    });

    test('bundled with no progress maps to bundled', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(bundled: true),
          progress: null,
          entry: null,
        ),
        ModelManagerStatus.bundled,
      );
    });

    test('no progress + no cache entry maps to downloadable', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(),
          progress: null,
          entry: null,
        ),
        ModelManagerStatus.downloadable,
      );
    });

    test('cache entry with matching version maps to downloaded', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(version: '2.0'),
          progress: null,
          entry: _entry(version: '2.0'),
        ),
        ModelManagerStatus.downloaded,
      );
    });

    test('cache entry with stale version maps to outdated', () {
      expect(
        modelManagerStatusFor(
          descriptor: _descriptor(version: '2.0'),
          progress: null,
          entry: _entry(version: '1.0'),
        ),
        ModelManagerStatus.outdated,
      );
    });
  });
}
