import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('PrefController');

/// Phase X.A.3 — generic persisted-preference controller.
///
/// Pre-X.A.3 each bool setting defined its own `StateNotifier`
/// subclass (`_BoolPrefController` in `settings_page.dart`). Adding
/// a new preference meant copy-pasting the hydrate / set pattern.
/// `PrefController<T>` is the one place that knows about
/// [SharedPreferences] read/write; callers supply a [getter] and
/// [setter] that know how to marshal their specific type.
///
/// ```dart
/// final myFlagController = StateNotifierProvider<PrefController<bool>, bool>(
///   (ref) => PrefController<bool>(
///     prefKey: 'my_flag_v1',
///     fallback: true,
///     getter: (p, k) => p.getBool(k),
///     setter: (p, k, v) => p.setBool(k, v),
///   ),
/// );
/// ```
///
/// [BoolPrefController] is the common-case shorthand.
class PrefController<T> extends StateNotifier<T> {
  PrefController({
    required this.prefKey,
    required T fallback,
    required T? Function(SharedPreferences prefs, String key) getter,
    required Future<bool> Function(SharedPreferences prefs, String key, T value)
        setter,
  })  : _getter = getter,
        _setter = setter,
        super(fallback) {
    _hydrate();
  }

  final String prefKey;
  final T? Function(SharedPreferences, String) _getter;
  final Future<bool> Function(SharedPreferences, String, T) _setter;

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = _getter(prefs, prefKey);
      if (v != null && v != state) state = v;
    } catch (e) {
      _log.d('hydrate failed', {'key': prefKey, 'error': e.toString()});
    }
  }

  /// Update the in-memory state and persist to disk. Returns once the
  /// SharedPreferences write has landed (or failed silently).
  Future<void> set(T value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _setter(prefs, prefKey, value);
    } catch (e) {
      _log.w('persist failed', {'key': prefKey, 'error': e.toString()});
    }
  }
}

/// Common-case shorthand for bool preferences. Wraps [PrefController]
/// with the `getBool` / `setBool` marshallers pre-wired so call sites
/// don't have to spell them out.
class BoolPrefController extends PrefController<bool> {
  BoolPrefController({required super.prefKey, required super.fallback})
      : super(
          getter: _getBool,
          setter: _setBool,
        );

  static bool? _getBool(SharedPreferences prefs, String key) =>
      prefs.getBool(key);
  static Future<bool> _setBool(
          SharedPreferences prefs, String key, bool value) =>
      prefs.setBool(key, value);
}
