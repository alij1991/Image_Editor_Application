import '../logging/app_logger.dart';

final _log = AppLogger('SchemaMigration');

/// Declarative migration from one schema version to the next.
///
/// A migration is a **pure** function of the input JSON — no IO, no side
/// effects, no platform calls. It receives the map at version `N` and
/// returns a map at `N+1`. The migrator runs these in order to bring a
/// persisted document up to the current version.
///
/// Migrations should leave the schema field value alone; the caller
/// decides whether to stamp the new version into the returned map.
/// [SchemaMigrator.migrate] stamps it for you after the final step so
/// every migration function can focus on the shape change and nothing
/// else.
typedef SchemaMigration = Map<String, dynamic> Function(
    Map<String, dynamic> json);

/// Runs a chain of [SchemaMigration]s over a JSON map to bring it up to
/// a target [currentVersion].
///
/// Policy:
/// - Input map with [schemaField] matching [currentVersion] → returned
///   untouched.
/// - Input map at an older version → migrations `fromVersion ... current-1`
///   run in order, each transforming the map one step forward.
/// - Input map with no [schemaField] → treated as v0 (the pre-schema
///   era). The v0→v1 migration should shape the map into the modern
///   wrapper. Callers that don't want this behaviour should reject
///   unversioned input upstream.
/// - Input map at a **newer** version → returned as-is with a warning.
///   This is best-effort for users who downgraded the app.
/// - Missing migration step mid-chain → returns `null`. The caller
///   should treat this as "unloadable, drop with a warning".
///
/// The migrator never throws for version issues; it either succeeds
/// with a migrated map, returns the original for future versions, or
/// returns `null` for a broken chain. JSON shape errors from the
/// migration functions themselves propagate to the caller.
class SchemaMigrator {
  const SchemaMigrator({
    required this.currentVersion,
    required this.schemaField,
    required this.storeTag,
    this.migrations = const {},
  });

  /// The version the caller considers "current". Migrated maps carry
  /// this value in [schemaField] after a successful run.
  final int currentVersion;

  /// Key inside the JSON map that carries the schema version. Callers
  /// typically pick `'schema'` for a wrapper envelope or `'version'`
  /// for an inline field on a payload object.
  final String schemaField;

  /// Identifying tag used in log lines so one test run can distinguish
  /// multiple stores' migration attempts.
  final String storeTag;

  /// Each entry migrates from `fromVersion` to `fromVersion + 1`. The
  /// chain walks these sequentially; gaps abort with `null`.
  final Map<int, SchemaMigration> migrations;

  /// Apply any migrations needed to bring [json] up to
  /// [currentVersion]. Returns the migrated map, or `null` when the
  /// chain is incomplete.
  Map<String, dynamic>? migrate(Map<String, dynamic> json) {
    final from = _readVersion(json);
    if (from == currentVersion) return json;
    if (from > currentVersion) {
      _log.w('$storeTag: future version; best-effort parse', {
        'version': from,
        'currentVersion': currentVersion,
      });
      return json;
    }
    // Chain forward one step at a time.
    var current = json;
    var version = from;
    while (version < currentVersion) {
      final step = migrations[version];
      if (step == null) {
        _log.w('$storeTag: no migration from $version to ${version + 1}', {
          'currentVersion': currentVersion,
        });
        return null;
      }
      _log.i('$storeTag: migrating', {'from': version, 'to': version + 1});
      current = step(current);
      version += 1;
    }
    // Stamp the new version so readers downstream can trust the field.
    current[schemaField] = currentVersion;
    return current;
  }

  int _readVersion(Map<String, dynamic> json) {
    final raw = json[schemaField];
    if (raw is num) return raw.toInt();
    return 0; // Missing or malformed → treat as v0 (pre-schema).
  }
}
