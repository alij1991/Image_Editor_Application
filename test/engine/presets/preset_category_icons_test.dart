import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/presets/built_in_presets.dart';
import 'package:image_editor/engine/presets/preset_category_icons.dart';

/// Phase XVI.62 — pin the taxonomy <-> icon registry consistency. The
/// preset rail builds chips by zipping `BuiltInPresets.categories`
/// with `presetCategoryIconFor`, so any drift between the two lists
/// silently shows generic palette icons in the UI for stale entries.
void main() {
  group('preset category icons (XVI.62)', () {
    test('every BuiltInPresets.categories id has a taxonomy entry', () {
      final taxonomyIds = {
        for (final c in presetCategoryTaxonomy) c.id,
      };
      for (final id in BuiltInPresets.categories) {
        expect(taxonomyIds.contains(id), isTrue,
            reason: 'category "$id" missing from presetCategoryTaxonomy '
                '— rail would render the fallback palette icon');
      }
    });

    test('every taxonomy entry maps back to BuiltInPresets.categories', () {
      // Reverse direction — a stale icon entry not referenced by any
      // category is dead code and should be removed.
      for (final c in presetCategoryTaxonomy) {
        expect(BuiltInPresets.categories.contains(c.id), isTrue,
            reason: 'taxonomy entry "${c.id}" has no category in '
                'BuiltInPresets.categories');
      }
    });

    test('every taxonomy entry has a non-null icon', () {
      for (final c in presetCategoryTaxonomy) {
        expect(c.icon, isNotNull);
        expect(c.label.isNotEmpty, isTrue);
      }
    });

    test('iconFor returns the taxonomy icon for known ids', () {
      for (final c in presetCategoryTaxonomy) {
        expect(presetCategoryIconFor(c.id), c.icon);
      }
    });

    test('iconFor falls back to palette for unknown ids', () {
      expect(presetCategoryIconFor('not-a-category'), Icons.palette);
      expect(presetCategoryIconFor(''), Icons.palette);
    });

    test('labelFor uses taxonomy when present, else echoes id', () {
      expect(presetCategoryLabelFor('popular'), 'Popular');
      expect(presetCategoryLabelFor('film'), 'Film');
      // Unknown id → echo so custom-category presets still have text
      // in the rail.
      expect(presetCategoryLabelFor('custom_user_category'),
          'custom_user_category');
    });

    test('taxonomy + BuiltInPresets.labelFor agree for every entry', () {
      // The taxonomy's `label` field and BuiltInPresets.labelFor
      // serve different surfaces (one drives the chip, the other
      // drives any code reading the legacy switch). They must agree
      // — otherwise the chip and a snackbar showing the same
      // category would say different names.
      for (final c in presetCategoryTaxonomy) {
        expect(BuiltInPresets.labelFor(c.id), c.label,
            reason:
                'BuiltInPresets.labelFor(${c.id}) != taxonomy label "${c.label}"');
      }
    });
  });
}
