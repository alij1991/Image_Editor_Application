import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/download_progress.dart';

void main() {
  group('DownloadProgress', () {
    test('DownloadQueued has no progress fraction', () {
      const event = DownloadQueued(modelId: 'id');
      expect(event.modelId, 'id');
    });

    test('DownloadRunning computes fraction when totalBytes is known', () {
      const event = DownloadRunning(
        modelId: 'id',
        receivedBytes: 50,
        totalBytes: 200,
      );
      expect(event.fraction, 0.25);
    });

    test('DownloadRunning fraction is null when total is unknown', () {
      const event = DownloadRunning(
        modelId: 'id',
        receivedBytes: 50,
        totalBytes: null,
      );
      expect(event.fraction, isNull);
    });

    test('DownloadRunning fraction is null when total is 0', () {
      const event = DownloadRunning(
        modelId: 'id',
        receivedBytes: 50,
        totalBytes: 0,
      );
      expect(event.fraction, isNull);
    });

    test('DownloadComplete carries the final path + size', () {
      const event = DownloadComplete(
        modelId: 'id',
        localPath: '/tmp/x',
        sizeBytes: 1024,
      );
      expect(event.localPath, '/tmp/x');
      expect(event.sizeBytes, 1024);
    });

    test('DownloadFailed surface messages per stage', () {
      const stages = DownloadFailureStage.values;
      for (final stage in stages) {
        expect(stage.userMessage, isNotEmpty);
      }
    });

    test('Equatable equality for identical runs', () {
      const a = DownloadRunning(
          modelId: 'id', receivedBytes: 50, totalBytes: 100);
      const b = DownloadRunning(
          modelId: 'id', receivedBytes: 50, totalBytes: 100);
      expect(a, b);
    });

    test('Equatable inequality when bytes differ', () {
      const a = DownloadRunning(
          modelId: 'id', receivedBytes: 50, totalBytes: 100);
      const b = DownloadRunning(
          modelId: 'id', receivedBytes: 60, totalBytes: 100);
      expect(a, isNot(b));
    });
  });
}
