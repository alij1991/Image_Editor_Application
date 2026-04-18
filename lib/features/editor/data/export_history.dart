import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_logger.dart';
import 'export_service.dart';

final _log = AppLogger('ExportHistory');

const String _kExportHistoryPref = 'export_history_v1';
const int _kMaxEntries = 20;

/// One persisted record of a successful export. Stored as JSON in
/// SharedPreferences so it survives across launches without needing a
/// real database. Files written by [ExportService] live under
/// `getTemporaryDirectory()` so the OS may sweep them — entries
/// surface as "missing" in the UI when the backing file is gone.
class ExportHistoryEntry {
  ExportHistoryEntry({
    required this.path,
    required this.format,
    required this.width,
    required this.height,
    required this.bytes,
    required this.exportedAt,
  });

  final String path;
  final ExportFormat format;
  final int width;
  final int height;
  final int bytes;
  final DateTime exportedAt;

  Map<String, Object?> toJson() => {
        'path': path,
        'format': format.name,
        'width': width,
        'height': height,
        'bytes': bytes,
        'exportedAt': exportedAt.toIso8601String(),
      };

  static ExportHistoryEntry? fromJson(Map<String, dynamic> j) {
    final formatName = j['format'];
    final format = ExportFormat.values.firstWhere(
      (f) => f.name == formatName,
      orElse: () => ExportFormat.jpeg,
    );
    final path = j['path'];
    final exportedAt = j['exportedAt'];
    if (path is! String || exportedAt is! String) return null;
    return ExportHistoryEntry(
      path: path,
      format: format,
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      exportedAt: DateTime.tryParse(exportedAt) ?? DateTime.now(),
    );
  }
}

/// Persisted ring of recent successful exports. Used by the Settings
/// page's "Recent exports" section so users can re-share without
/// re-rendering, and by analytics-curious devs to understand which
/// formats / sizes are popular.
///
/// Capped at [_kMaxEntries] entries; oldest fall off when new ones
/// land. All operations are non-fatal — IO failures degrade silently
/// so the export path itself never fails because history bookkeeping
/// hit a snag.
class ExportHistory {
  ExportHistory();

  /// Append [entry] to the front of the persisted ring.
  Future<void> add(ExportHistoryEntry entry) async {
    final all = await _load();
    all.insert(0, entry);
    while (all.length > _kMaxEntries) {
      all.removeLast();
    }
    await _save(all);
    _log.d('add', {'path': entry.path, 'count': all.length});
  }

  /// Convenience adapter from an [ExportResult]: extracts the
  /// fields ExportHistoryEntry needs and stamps the timestamp.
  Future<void> addResult(ExportResult result) {
    return add(ExportHistoryEntry(
      path: result.file.path,
      format: result.format,
      width: result.width,
      height: result.height,
      bytes: result.bytes,
      exportedAt: DateTime.now(),
    ));
  }

  /// Read every persisted entry, newest-first. Returns an empty list
  /// when nothing has been saved or SharedPreferences is unavailable.
  Future<List<ExportHistoryEntry>> list() async => _load();

  /// Remove the entry whose path matches [path]. No-op if not found.
  Future<void> remove(String path) async {
    final all = await _load();
    final filtered = all.where((e) => e.path != path).toList();
    if (filtered.length == all.length) return;
    await _save(filtered);
    _log.d('removed', {'path': path});
  }

  /// Drop every entry. Used by the "Clear history" Settings button.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kExportHistoryPref);
      _log.i('cleared');
    } catch (e) {
      _log.w('clear failed', {'error': e.toString()});
    }
  }

  Future<List<ExportHistoryEntry>> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kExportHistoryPref);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <ExportHistoryEntry>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final entry = ExportHistoryEntry.fromJson(item);
        if (entry != null) out.add(entry);
      }
      return out;
    } catch (e) {
      _log.w('load failed', {'error': e.toString()});
      return [];
    }
  }

  Future<void> _save(List<ExportHistoryEntry> all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kExportHistoryPref,
        jsonEncode(all.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      _log.w('save failed', {'error': e.toString()});
    }
  }
}
