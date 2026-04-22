import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:image_editor/ai/models/model_cache.dart';
import 'package:image_editor/ai/models/model_descriptor.dart';
import 'package:image_editor/features/settings/presentation/widgets/model_manager_sheet.dart';

/// VIII.7 — `deletePartialFor` removes the in-flight file at the
/// descriptor's destination path if one exists, returning true on
/// success. Missing-file is a no-op that returns false.
class _TmpPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.tmp);
  final String tmp;
  @override
  Future<String?> getTemporaryPath() async => tmp;
  @override
  Future<String?> getApplicationDocumentsPath() async => tmp;
  @override
  Future<String?> getApplicationSupportPath() async => tmp;
  @override
  Future<String?> getApplicationCachePath() async => tmp;
}

const _desc = ModelDescriptor(
  id: 'test-model',
  version: '1',
  runtime: ModelRuntime.onnx,
  sizeBytes: 1024,
  sha256: '',
  bundled: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late ModelCache cache;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cancel_and_delete');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
    cache = ModelCache();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('deletes a pre-existing partial file + returns true', () async {
    final destPath = await cache.destinationPathFor(_desc);
    await File(destPath).create(recursive: true);
    await File(destPath).writeAsBytes([1, 2, 3, 4]);
    expect(File(destPath).existsSync(), isTrue);

    final deleted = await deletePartialFor(cache, _desc);

    expect(deleted, isTrue);
    expect(File(destPath).existsSync(), isFalse);
  });

  test('returns false when no partial file exists', () async {
    final destPath = await cache.destinationPathFor(_desc);
    expect(File(destPath).existsSync(), isFalse);

    final deleted = await deletePartialFor(cache, _desc);

    expect(deleted, isFalse);
  });

  test('idempotent — second call with no file returns false', () async {
    final destPath = await cache.destinationPathFor(_desc);
    await File(destPath).create(recursive: true);
    await File(destPath).writeAsString('partial');

    final first = await deletePartialFor(cache, _desc);
    final second = await deletePartialFor(cache, _desc);

    expect(first, isTrue);
    expect(second, isFalse);
    expect(File(destPath).existsSync(), isFalse);
  });

  test('destination path follows <id>_<version> naming', () async {
    final destPath = await cache.destinationPathFor(_desc);
    expect(p.basename(destPath), 'test-model_1');
  });
}
