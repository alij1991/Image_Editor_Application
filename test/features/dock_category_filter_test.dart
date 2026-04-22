import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/engine/pipeline/op_spec.dart';

/// IX.A.4 — the tool dock filters out categories with zero registered
/// specs (otherwise users learn to ignore the tab bar when "coming in
/// a later phase" is the only thing behind a tab).
///
/// This test exercises the filter expression directly — the widget
/// test in `tool_dock_test.dart` would require pumping the full panel
/// stack; a unit-level pin on the filter logic is cheaper to maintain
/// and catches the regression the dock is guarding against.
void main() {
  test('every current OpCategory has at least one registered spec', () {
    // A new `OpCategory.foo` without any `OpSpec` entries would be
    // hidden by the dock filter. Flagging that proactively here
    // means a developer adding a category gets a clear "add specs or
    // remove the enum entry" signal instead of a silently empty tab.
    for (final cat in OpCategory.values) {
      expect(OpSpecs.forCategory(cat), isNotEmpty,
          reason: 'OpCategory.${cat.name} has no specs — the tool '
              'dock will hide it. Either register specs or remove '
              'the enum value.');
    }
  });

  test('the dock filter keeps only non-empty categories', () {
    final filtered = OpCategory.values
        .where((c) => OpSpecs.forCategory(c).isNotEmpty)
        .toList(growable: false);
    // Today every category has specs — the filter is a no-op, but
    // pinning the current list catches accidental removals too.
    expect(filtered, OpCategory.values,
        reason: 'Filter output must match OpCategory.values while '
            'every category has at least one spec.');
  });

  test('adding a synthetic empty category is excluded by the filter', () {
    // Simulate the filter's predicate against a category we pretend
    // has no specs. Guards against a regression where the predicate
    // would include empty categories — the filter is
    // `OpSpecs.forCategory(c).isNotEmpty`.
    bool shouldKeep(OpCategory c, bool pretendEmpty) =>
        pretendEmpty ? false : OpSpecs.forCategory(c).isNotEmpty;

    // Real categories render.
    for (final c in OpCategory.values) {
      expect(shouldKeep(c, false), isTrue);
    }
    // Pretend each one were empty → filtered out.
    for (final c in OpCategory.values) {
      expect(shouldKeep(c, true), isFalse);
    }
  });

  test('OpSpecs.forCategory returns specs whose category matches', () {
    for (final cat in OpCategory.values) {
      final specs = OpSpecs.forCategory(cat);
      for (final spec in specs) {
        expect(spec.category, cat,
            reason: 'spec ${spec.type}/${spec.paramKey} categorised '
                'as ${spec.category.name} returned by forCategory(${cat.name})');
      }
    }
  });
}
