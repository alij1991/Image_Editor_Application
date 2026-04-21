import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/ai/models/download_progress.dart';
import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/ai/models/model_downloader.dart';

/// Integrity tests for [ModelDownloader].
///
/// Covers the sha256-verification seam end-to-end by standing up a
/// throwaway `HttpServer` on loopback and pointing the downloader at
/// it. The downloader uses `dio` internally — exercising the real
/// adapter against a local server gives more realistic coverage than
/// mocking the network.
///
/// The corresponding Phase I.5 change pinned real hashes for LaMa
/// and RMBG in `assets/models/manifest.json`; this file pins the
/// *behaviour* that makes those hashes mean something.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('model_downloader_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('ModelDownloader sha256 verification', () {
    test('downloads complete when the sha256 matches', () async {
      final payload = _deterministicPayload(4096);
      final hash = ModelDownloader.sha256Bytes(payload);

      await _withServer(payload, (url) async {
        final descriptor = ModelDescriptor(
          id: 'hash-match',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: payload.length,
          sha256: hash,
          bundled: false,
          url: url,
        );
        final downloader = ModelDownloader();
        final dest = '${tmp.path}/match.bin';
        final last = await _lastEvent(
          downloader.download(descriptor: descriptor, destinationPath: dest),
        );
        expect(last, isA<DownloadComplete>());
        expect((last as DownloadComplete).sizeBytes, payload.length);
        expect(File(dest).existsSync(), isTrue);
        expect(File(dest).lengthSync(), payload.length);
      });
    });

    test('rejects tampered payload with sha256Mismatch + deletes file',
        () async {
      final payload = _deterministicPayload(4096);
      // 64-char hex hash that is NOT the hash of `payload`. The
      // downloader treats anything that isn't a 'PLACEHOLDER' prefix
      // as a real expected hash.
      const wrongHash =
          'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef';

      await _withServer(payload, (url) async {
        final descriptor = ModelDescriptor(
          id: 'hash-mismatch',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: payload.length,
          sha256: wrongHash,
          bundled: false,
          url: url,
        );
        final downloader = ModelDownloader();
        final dest = '${tmp.path}/tampered.bin';
        final last = await _lastEvent(
          downloader.download(descriptor: descriptor, destinationPath: dest),
        );
        expect(last, isA<DownloadFailed>());
        expect(
          (last as DownloadFailed).stage,
          DownloadFailureStage.sha256Mismatch,
          reason: 'mismatched hash must produce the dedicated failure stage',
        );
        // The downloader explicitly deletes the corrupted file so the
        // next retry starts clean (no spurious resume offset).
        expect(File(dest).existsSync(), isFalse,
            reason: 'corrupted file must be wiped on mismatch');
      });
    });

    test('hash verification is case-insensitive', () async {
      final payload = _deterministicPayload(256);
      final hash = ModelDownloader.sha256Bytes(payload);

      await _withServer(payload, (url) async {
        final descriptor = ModelDescriptor(
          id: 'case-insensitive',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: payload.length,
          // Upper-case the expected hash; the downloader lowercases
          // both sides before comparing.
          sha256: hash.toUpperCase(),
          bundled: false,
          url: url,
        );
        final downloader = ModelDownloader();
        final dest = '${tmp.path}/upper.bin';
        final last = await _lastEvent(
          downloader.download(descriptor: descriptor, destinationPath: dest),
        );
        expect(last, isA<DownloadComplete>());
      });
    });
  });

  group('ModelDownloader backward-compat seams', () {
    test('PLACEHOLDER sha256 skips verification (dev seam)', () async {
      final payload = _deterministicPayload(1024);
      await _withServer(payload, (url) async {
        const descriptor = ModelDescriptor(
          id: 'placeholder',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: 1024,
          sha256: 'PLACEHOLDER_FILL_WHEN_PINNED',
          bundled: false,
        );
        final descWithUrl = descriptor.copyWith(url: url);
        final downloader = ModelDownloader();
        final dest = '${tmp.path}/placeholder.bin';
        final last = await _lastEvent(
          downloader.download(
              descriptor: descWithUrl, destinationPath: dest),
        );
        expect(last, isA<DownloadComplete>(),
            reason: 'PLACEHOLDER-prefixed hashes are a dev-time escape hatch');
      });
    });

    test('empty sha256 skips verification (dev seam)', () async {
      final payload = _deterministicPayload(512);
      await _withServer(payload, (url) async {
        final descriptor = ModelDescriptor(
          id: 'empty-hash',
          version: '1.0',
          runtime: ModelRuntime.onnx,
          sizeBytes: payload.length,
          sha256: '',
          bundled: false,
          url: url,
        );
        final downloader = ModelDownloader();
        final dest = '${tmp.path}/empty.bin';
        final last = await _lastEvent(
          downloader.download(descriptor: descriptor, destinationPath: dest),
        );
        expect(last, isA<DownloadComplete>());
      });
    });
  });

  group('ModelDownloader guardrails', () {
    test('bundled descriptor fails fast without hitting the network',
        () async {
      const descriptor = ModelDescriptor(
        id: 'bundled',
        version: '1.0',
        runtime: ModelRuntime.litert,
        sizeBytes: 100,
        sha256: '',
        bundled: true,
        assetPath: 'assets/models/bundled/x.tflite',
      );
      final downloader = ModelDownloader();
      final last = await _lastEvent(
        downloader.download(
            descriptor: descriptor, destinationPath: '${tmp.path}/ignored'),
      );
      expect(last, isA<DownloadFailed>());
      expect((last as DownloadFailed).stage, DownloadFailureStage.unknown);
    });

    test('missing URL fails fast', () async {
      const descriptor = ModelDescriptor(
        id: 'no-url',
        version: '1.0',
        runtime: ModelRuntime.onnx,
        sizeBytes: 100,
        sha256: '',
        bundled: false,
      );
      final downloader = ModelDownloader();
      final last = await _lastEvent(
        downloader.download(
            descriptor: descriptor, destinationPath: '${tmp.path}/ignored'),
      );
      expect(last, isA<DownloadFailed>());
    });

    test('sha256Bytes produces 64-char lowercase hex', () {
      final hash = ModelDownloader.sha256Bytes(
        Uint8List.fromList(const [1, 2, 3, 4]),
      );
      expect(hash.length, 64);
      expect(hash, equals(hash.toLowerCase()));
    });
  });
}

/// A deterministic byte buffer so every run hashes to the same value.
Uint8List _deterministicPayload(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + 7) & 0xFF;
  }
  return out;
}

/// Collect the last event from a `Stream<DownloadProgress>`. The
/// downloader emits at least one terminal event (`DownloadComplete`
/// or `DownloadFailed`) so `last` is always populated.
Future<DownloadProgress> _lastEvent(Stream<DownloadProgress> s) async {
  DownloadProgress? last;
  await for (final e in s) {
    last = e;
  }
  expect(last, isNotNull, reason: 'downloader must emit at least one event');
  return last!;
}

/// Stand up a loopback HTTP server that serves [payload] at every
/// path, run [body] with the base URL, then close the server.
Future<void> _withServer(
  Uint8List payload,
  Future<void> Function(String url) body,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // Best-effort serve loop; the future completes when the server is
  // closed. Errors here surface via the test's assertion failures.
  unawaited(() async {
    await for (final req in server) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.binary
        ..contentLength = payload.length
        ..add(payload);
      await req.response.close();
    }
  }());
  try {
    await body('http://127.0.0.1:${server.port}/file');
  } finally {
    await server.close(force: true);
  }
}
