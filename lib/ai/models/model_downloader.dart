import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/logging/app_logger.dart';
import 'download_progress.dart';
import 'model_descriptor.dart';

final _log = AppLogger('ModelDownloader');

/// Downloads a [ModelDescriptor] to a local file with progress
/// reporting, resume support, and sha256 verification.
///
/// The policy is "any connection with warning" — the downloader
/// itself doesn't gate on Wi-Fi vs cellular; the caller is
/// responsible for showing a confirmation prompt before kicking off
/// a large download. This keeps this class testable without mocking
/// connectivity APIs.
class ModelDownloader {
  ModelDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final Map<String, CancelToken> _active = {};

  /// Returns true if a download is currently in progress for [modelId].
  bool isDownloading(String modelId) => _active.containsKey(modelId);

  /// Cancel an in-flight download. No-op if nothing is downloading
  /// for [modelId].
  void cancel(String modelId) {
    final token = _active.remove(modelId);
    if (token != null && !token.isCancelled) {
      _log.i('cancel', {'id': modelId});
      token.cancel('user cancelled');
    }
  }

  /// Download [descriptor] to [destinationPath]. Returns a stream of
  /// progress events terminating in either [DownloadComplete] or
  /// [DownloadFailed].
  ///
  /// If [destinationPath] already contains a partial file (e.g. from
  /// a previous interrupted download), the downloader sends a
  /// `Range: bytes=N-` header to resume. If the server doesn't
  /// support range requests, the partial is discarded and the
  /// download restarts from zero.
  Stream<DownloadProgress> download({
    required ModelDescriptor descriptor,
    required String destinationPath,
  }) async* {
    if (descriptor.bundled) {
      yield DownloadFailed(
        modelId: descriptor.id,
        stage: DownloadFailureStage.unknown,
        message: 'Cannot download a bundled model',
      );
      return;
    }
    final url = descriptor.url;
    if (url == null || url.isEmpty) {
      yield DownloadFailed(
        modelId: descriptor.id,
        stage: DownloadFailureStage.unknown,
        message: 'Model descriptor has no URL',
      );
      return;
    }

    final cancelToken = CancelToken();
    _active[descriptor.id] = cancelToken;
    final controller = StreamController<DownloadProgress>();

    // Kick off the async work outside of the yield stream so the
    // progress events can be surfaced from the dio callback.
    // The returned stream listens to the controller.
    unawaited(
      _runDownload(
        descriptor: descriptor,
        url: url,
        destinationPath: destinationPath,
        cancelToken: cancelToken,
        controller: controller,
      ).whenComplete(() {
        _active.remove(descriptor.id);
        controller.close();
      }),
    );
    yield* controller.stream;
  }

  Future<void> _runDownload({
    required ModelDescriptor descriptor,
    required String url,
    required String destinationPath,
    required CancelToken cancelToken,
    required StreamController<DownloadProgress> controller,
  }) async {
    _log.i('start', {
      'id': descriptor.id,
      'url': url,
      'sizeBytes': descriptor.sizeBytes,
      'dest': destinationPath,
    });
    controller.add(DownloadQueued(modelId: descriptor.id));

    // Resume: if a partial file exists, try a range request starting
    // from its current length.
    final destFile = File(destinationPath);
    int resumeFrom = 0;
    try {
      if (await destFile.exists()) {
        resumeFrom = await destFile.length();
        _log.d('resume candidate', {'bytes': resumeFrom});
      } else {
        await destFile.parent.create(recursive: true);
      }
    } catch (e, st) {
      _log.e('filesystem pre-check failed', error: e, stackTrace: st);
      controller.add(
        DownloadFailed(
          modelId: descriptor.id,
          stage: DownloadFailureStage.fileSystem,
          message: e.toString(),
        ),
      );
      return;
    }

    try {
      Response<ResponseBody> response;
      try {
        response = await _dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: resumeFrom > 0 ? {'Range': 'bytes=$resumeFrom-'} : null,
            validateStatus: (s) => s != null && s < 400,
          ),
          cancelToken: cancelToken,
        );
      } on DioException catch (e) {
        // 416 Range Not Satisfiable — the file on disk is already
        // complete (resume offset == total size). If the local file
        // size is close to the expected size, treat it as a successful
        // download instead of deleting and re-fetching.
        if (e.response?.statusCode == 416 && resumeFrom > 0) {
          // Check if the file is already complete (within 5% tolerance
          // to handle manifest size estimates vs actual content-length).
          final expectedSize = descriptor.sizeBytes;
          final ratio = resumeFrom / expectedSize;
          if (ratio > 0.95) {
            _log.i('416 but file appears complete; skipping re-download', {
              'id': descriptor.id,
              'localBytes': resumeFrom,
              'expectedBytes': expectedSize,
            });
            controller.add(DownloadComplete(
              modelId: descriptor.id,
              localPath: destinationPath,
              sizeBytes: resumeFrom,
            ));
            return;
          }
          // File is partially downloaded but can't resume — delete and
          // start over.
          _log.w('416 range error; deleting partial file and retrying',
              {'id': descriptor.id, 'staleBytes': resumeFrom});
          await destFile.delete().catchError((Object _) => destFile);
          resumeFrom = 0;
          response = await _dio.get<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              validateStatus: (s) => s != null && s < 400,
            ),
            cancelToken: cancelToken,
          );
        } else {
          rethrow;
        }
      }

      final statusCode = response.statusCode ?? 200;
      final rangeSupported = statusCode == 206;
      final effectiveStart = rangeSupported ? resumeFrom : 0;
      if (!rangeSupported && resumeFrom > 0) {
        _log.w('server ignored Range header; restarting', {'id': descriptor.id});
        // Wipe the stale partial so the new bytes start at zero.
        await destFile.delete().catchError((Object _) => destFile);
      }

      // Determine the total byte count. For resumed downloads,
      // Content-Length is the remaining bytes, not the whole file.
      final contentLengthHeader = response.headers
          .value(Headers.contentLengthHeader);
      final contentLength =
          contentLengthHeader == null ? null : int.tryParse(contentLengthHeader);
      final totalBytes = contentLength == null
          ? descriptor.sizeBytes
          : contentLength + effectiveStart;
      _log.d('headers', {
        'status': statusCode,
        'rangeSupported': rangeSupported,
        'contentLength': contentLength,
        'totalBytes': totalBytes,
      });

      final raf = await destFile.open(
        mode: rangeSupported ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      int received = effectiveStart;
      controller.add(
        DownloadRunning(
          modelId: descriptor.id,
          receivedBytes: received,
          totalBytes: totalBytes,
        ),
      );

      final stream = response.data?.stream;
      if (stream == null) {
        await raf.close();
        throw const FormatException('Empty response body');
      }

      await for (final chunk in stream) {
        if (cancelToken.isCancelled) break;
        await raf.writeFrom(chunk);
        received += chunk.length;
        controller.add(
          DownloadRunning(
            modelId: descriptor.id,
            receivedBytes: received,
            totalBytes: totalBytes,
          ),
        );
      }
      await raf.close();

      if (cancelToken.isCancelled) {
        controller.add(
          DownloadFailed(
            modelId: descriptor.id,
            stage: DownloadFailureStage.cancelled,
            message: 'Cancelled',
          ),
        );
        return;
      }

      // Verify sha256. Placeholder sha is allowed so the manifest can
      // ship with empty hashes during development; real models in
      // production must have a real hash.
      if (descriptor.sha256.isNotEmpty &&
          !descriptor.sha256.startsWith('PLACEHOLDER')) {
        final actual = await _hashFile(destFile);
        if (actual.toLowerCase() != descriptor.sha256.toLowerCase()) {
          _log.w('sha256 mismatch', {
            'id': descriptor.id,
            'expected': descriptor.sha256,
            'actual': actual,
          });
          await destFile.delete().catchError((Object _) => destFile);
          controller.add(
            DownloadFailed(
              modelId: descriptor.id,
              stage: DownloadFailureStage.sha256Mismatch,
              message: 'sha256 mismatch',
            ),
          );
          return;
        }
      }

      _log.i('complete', {
        'id': descriptor.id,
        'bytes': received,
        'path': destinationPath,
      });
      controller.add(
        DownloadComplete(
          modelId: descriptor.id,
          localPath: destinationPath,
          sizeBytes: received,
        ),
      );
    } on DioException catch (e, st) {
      if (CancelToken.isCancel(e)) {
        _log.i('download cancelled', {'id': descriptor.id});
        controller.add(
          DownloadFailed(
            modelId: descriptor.id,
            stage: DownloadFailureStage.cancelled,
            message: 'Cancelled',
          ),
        );
        return;
      }
      _log.e('network failure',
          error: e, stackTrace: st, data: {'id': descriptor.id});
      controller.add(
        DownloadFailed(
          modelId: descriptor.id,
          stage: DownloadFailureStage.network,
          message: e.message ?? 'Unknown network error',
        ),
      );
    } catch (e, st) {
      _log.e('unknown failure',
          error: e, stackTrace: st, data: {'id': descriptor.id});
      controller.add(
        DownloadFailed(
          modelId: descriptor.id,
          stage: DownloadFailureStage.unknown,
          message: e.toString(),
        ),
      );
    }
  }

  static Future<String> _hashFile(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  /// Compute sha256 of a byte buffer. Exposed for tests.
  static String sha256Bytes(Uint8List bytes) =>
      sha256.convert(bytes).toString();
}
