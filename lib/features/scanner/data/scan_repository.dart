import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/models/scan_models.dart';

final _log = AppLogger('ScanRepo');

/// Flat-file persistence for scan sessions. Each session is written as
/// a JSON file under `<appDocs>/scans/<sessionId>.json`. We also copy
/// the processed page JPEGs into `<appDocs>/scans/<sessionId>/` so they
/// survive temp-dir eviction.
class ScanRepository {
  ScanRepository();

  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'scans'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Persist a finished session. Pages with processed JPEGs are copied
  /// into a session-specific folder so future launches can still load
  /// them after the OS clears the temp cache.
  Future<void> save(ScanSession session) async {
    final root = await _root();
    final sessionDir = Directory(p.join(root.path, session.id));
    if (!sessionDir.existsSync()) sessionDir.createSync(recursive: true);

    // Copy processed images to durable storage and rewrite paths.
    final pages = <ScanPage>[];
    for (final page in session.pages) {
      final source = page.processedImagePath ?? page.rawImagePath;
      final dest = p.join(sessionDir.path, '${page.id}.jpg');
      try {
        await File(source).copy(dest);
        pages.add(page.copyWith(processedImagePath: dest));
      } catch (e) {
        _log.w('copy page failed', {'page': page.id, 'err': e.toString()});
        pages.add(page);
      }
    }

    final stored = session.copyWith(pages: pages);
    final file = File(p.join(root.path, '${session.id}.json'));
    await file.writeAsString(jsonEncode(stored.toJson()));
    _log.i('saved', {'id': session.id, 'pages': pages.length});
  }

  Future<List<ScanSession>> loadAll() async {
    final sw = Stopwatch()..start();
    final root = await _root();
    if (!root.existsSync()) return const [];
    final list = <ScanSession>[];
    for (final f in root.listSync()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        list.add(ScanSession.fromJson(j));
      } catch (e) {
        _log.w('bad session file', {'path': f.path, 'err': e.toString()});
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _log.d('loaded', {'n': list.length, 'ms': sw.elapsedMilliseconds});
    return list;
  }

  Future<void> delete(String sessionId) async {
    final root = await _root();
    final file = File(p.join(root.path, '$sessionId.json'));
    if (file.existsSync()) await file.delete();
    final dir = Directory(p.join(root.path, sessionId));
    if (dir.existsSync()) await dir.delete(recursive: true);
    _log.i('deleted', {'id': sessionId});
  }
}
