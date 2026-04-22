import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:image_editor/core/preferences/pref_controller.dart';

/// X.A.3 — generic `PrefController<T>` + `BoolPrefController`
/// shorthand. Pins the hydrate / set / persist cycle across bool +
/// int + string payloads so a future preference type doesn't need
/// its own copy-paste StateNotifier.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BoolPrefController', () {
    test('starts at fallback when pref is unset', () {
      final c = BoolPrefController(prefKey: 'k', fallback: true);
      expect(c.state, isTrue);
    });

    test('hydrate upgrades state from a persisted value', () async {
      SharedPreferences.setMockInitialValues({'k': false});
      final c = BoolPrefController(prefKey: 'k', fallback: true);
      // Hydrate is async; wait a microtask for it to land.
      await Future<void>.delayed(Duration.zero);
      expect(c.state, isFalse,
          reason: 'hydrate should overwrite fallback with persisted value');
    });

    test('set persists + updates state', () async {
      final c = BoolPrefController(prefKey: 'k', fallback: false);
      await c.set(true);
      expect(c.state, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('k'), isTrue,
          reason: 'persisted value must match the new state');
    });

    test('setting the same value twice is a no-op for state', () async {
      final c = BoolPrefController(prefKey: 'k', fallback: false);
      await c.set(true);
      final firstStamp = c.state;
      await c.set(true);
      expect(c.state, firstStamp);
    });
  });

  group('PrefController<int>', () {
    test('round-trip int preference', () async {
      final c = PrefController<int>(
        prefKey: 'count',
        fallback: 0,
        getter: (p, k) => p.getInt(k),
        setter: (p, k, v) => p.setInt(k, v),
      );
      await c.set(42);
      expect(c.state, 42);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('count'), 42);
    });

    test('hydrate of a persisted int value', () async {
      SharedPreferences.setMockInitialValues({'count': 7});
      final c = PrefController<int>(
        prefKey: 'count',
        fallback: 0,
        getter: (p, k) => p.getInt(k),
        setter: (p, k, v) => p.setInt(k, v),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.state, 7);
    });
  });

  group('PrefController<String>', () {
    test('round-trip string preference', () async {
      final c = PrefController<String>(
        prefKey: 's',
        fallback: '',
        getter: (p, k) => p.getString(k),
        setter: (p, k, v) => p.setString(k, v),
      );
      await c.set('hello');
      expect(c.state, 'hello');
    });
  });
}
