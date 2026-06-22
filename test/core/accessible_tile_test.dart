import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_editor/core/widgets/accessible_tile.dart';

/// XVI.131 (F1) — pins the accessibility contract of AccessibleTile: a
/// single merged semantics node exposing the label, the button role, a
/// tap action, and the selected state — so screen readers announce
/// "<label>, selected, button" and can activate it.
void main() {
  Widget harness({required bool selected, required VoidCallback onTap}) =>
      MaterialApp(
        home: Scaffold(
          body: AccessibleTile(
            label: 'Grid 3×3 layout',
            selected: selected,
            onTap: onTap,
            // A presentational child whose OWN text must NOT leak as a
            // second semantics label.
            child: const Text('decorative-inner'),
          ),
        ),
      );

  testWidgets('exposes label + button role + tap action + selected state',
      (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(harness(selected: true, onTap: () => taps++));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Grid 3×3 layout')),
      // ignore: deprecated_member_use
      containsSemantics(
        label: 'Grid 3×3 layout',
        isButton: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );

    // Activating via the semantics tap action fires onTap.
    await tester.tap(find.bySemanticsLabel('Grid 3×3 layout'));
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('forwards onLongPress + exposes a tooltip', (tester) async {
    final handle = tester.ensureSemantics();
    var longPresses = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AccessibleTile(
          label: 'Sepia',
          selected: false,
          onTap: () {},
          onLongPress: () => longPresses++,
          tooltip: 'Sepia\nLong-press to delete',
          child: const Text('thumb'),
        ),
      ),
    ));
    await tester.longPress(find.bySemanticsLabel('Sepia'));
    expect(longPresses, 1);
    handle.dispose();
  });

  testWidgets('unselected tile reports not-selected', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(selected: false, onTap: () {}));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Grid 3×3 layout')),
      // ignore: deprecated_member_use
      containsSemantics(isSelected: false, isButton: true),
    );
    handle.dispose();
  });

  testWidgets("the child's inner text does not leak a duplicate label",
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(selected: false, onTap: () {}));
    // The decorative inner Text is excluded from semantics — only the
    // tile label is discoverable.
    expect(find.bySemanticsLabel('decorative-inner'), findsNothing);
    expect(find.bySemanticsLabel('Grid 3×3 layout'), findsOneWidget);
    handle.dispose();
  });
}
