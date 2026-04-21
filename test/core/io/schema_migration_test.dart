import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/io/schema_migration.dart';

/// Behaviour tests for [SchemaMigrator].
///
/// The helper is tiny and the store-specific tests exercise real
/// migrations, but the policy corners (missing schema field, future
/// version, gap in chain, multi-step chain) deserve isolated coverage
/// so regressions there don't cascade into store-level test failures
/// that mask the real cause.
void main() {
  group('SchemaMigrator', () {
    const tag = 'TestStore';

    test('returns the input untouched when version matches current', () {
      const migrator = SchemaMigrator(
        currentVersion: 1,
        schemaField: 'schema',
        storeTag: tag,
      );
      final out = migrator.migrate({'schema': 1, 'payload': 42});
      expect(out, isNotNull);
      expect(out!['schema'], 1);
      expect(out['payload'], 42);
    });

    test('treats a missing schema field as v0', () {
      final migrator = SchemaMigrator(
        currentVersion: 1,
        schemaField: 'schema',
        storeTag: tag,
        migrations: {
          0: (json) => {...json, 'upgraded': true},
        },
      );
      final out = migrator.migrate({'payload': 'anything'});
      expect(out, isNotNull);
      expect(out!['schema'], 1);
      expect(out['upgraded'], true);
      expect(out['payload'], 'anything');
    });

    test('runs a single-step v0 → v1 chain and stamps the new version',
        () {
      final migrator = SchemaMigrator(
        currentVersion: 1,
        schemaField: 'schema',
        storeTag: tag,
        migrations: {
          0: (json) {
            // v0 had `name`; v1 splits into `first` + `last`.
            final name = json['name'] as String? ?? '';
            final parts = name.split(' ');
            return {
              'first': parts.isNotEmpty ? parts.first : '',
              'last': parts.length > 1 ? parts.sublist(1).join(' ') : '',
            };
          },
        },
      );
      final out = migrator.migrate({'name': 'Ada Lovelace'});
      expect(out, isNotNull);
      expect(out!['schema'], 1);
      expect(out['first'], 'Ada');
      expect(out['last'], 'Lovelace');
      expect(out.containsKey('name'), false);
    });

    test('walks a multi-step chain in order', () {
      final log = <String>[];
      final migrator = SchemaMigrator(
        currentVersion: 3,
        schemaField: 'schema',
        storeTag: tag,
        migrations: {
          0: (json) {
            log.add('0→1');
            return {...json, 'stage1': true};
          },
          1: (json) {
            log.add('1→2');
            return {...json, 'stage2': true};
          },
          2: (json) {
            log.add('2→3');
            return {...json, 'stage3': true};
          },
        },
      );
      final out = migrator.migrate({'schema': 0, 'seed': 'x'});
      expect(out, isNotNull);
      expect(log, ['0→1', '1→2', '2→3']);
      expect(out!['schema'], 3);
      expect(out['stage1'], true);
      expect(out['stage2'], true);
      expect(out['stage3'], true);
      expect(out['seed'], 'x');
    });

    test('returns null when the chain has a gap', () {
      final migrator = SchemaMigrator(
        currentVersion: 3,
        schemaField: 'schema',
        storeTag: tag,
        migrations: {
          // Missing 1 → 2; v0 → v1 runs but then we can't reach v3.
          0: (json) => {...json, 'step': 1},
          2: (json) => {...json, 'step': 3},
        },
      );
      final out = migrator.migrate({'schema': 0});
      expect(out, isNull,
          reason: 'incomplete chain must return null so callers drop');
    });

    test('returns input untouched for a future version', () {
      const migrator = SchemaMigrator(
        currentVersion: 1,
        schemaField: 'schema',
        storeTag: tag,
      );
      final out = migrator.migrate({'schema': 99, 'payload': 'future'});
      expect(out, isNotNull);
      expect(out!['schema'], 99);
      expect(out['payload'], 'future');
    });

    test('respects a custom schemaField name', () {
      final migrator = SchemaMigrator(
        currentVersion: 2,
        schemaField: 'version',
        storeTag: tag,
        migrations: {
          0: (json) => {...json, 'fromZero': true},
          1: (json) => {...json, 'fromOne': true},
        },
      );
      final out = migrator.migrate({'version': 1, 'keep': 'me'});
      expect(out, isNotNull);
      expect(out!['version'], 2);
      expect(out['fromZero'], isNull,
          reason: 'starting at v1 must skip the v0 migration');
      expect(out['fromOne'], true);
      expect(out['keep'], 'me');
    });

    test('malformed schema field falls back to v0', () {
      final migrator = SchemaMigrator(
        currentVersion: 1,
        schemaField: 'schema',
        storeTag: tag,
        migrations: {
          0: (json) => {...json, 'rescued': true},
        },
      );
      final out = migrator.migrate({'schema': 'not-a-number', 'p': 1});
      expect(out, isNotNull);
      expect(out!['rescued'], true);
    });

    test('mutating the returned map is permitted by contract', () {
      final migrator = SchemaMigrator(
        currentVersion: 1,
        schemaField: 'schema',
        storeTag: tag,
        migrations: {0: (json) => {...json, 'wrapped': true}},
      );
      final out = migrator.migrate({'x': 1});
      expect(out, isNotNull);
      // The contract in the class doc says the caller may treat the
      // returned map as consumed/mutated. Exercise that.
      out!['extra'] = 'added';
      expect(out['extra'], 'added');
    });
  });
}
