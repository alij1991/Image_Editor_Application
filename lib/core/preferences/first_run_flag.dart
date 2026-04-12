import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('FirstRunFlag');

/// Tracks "has the user seen this onboarding tip yet?" using
/// [SharedPreferences]. Each distinct tip has its own key so we can
/// introduce new coach marks later without re-showing old ones.
///
/// The flag is read-through (defaults to true on any error) so a broken
/// SharedPreferences instance never blocks the user. We only log the
/// read once per key to avoid log spam.
class FirstRunFlag {
  FirstRunFlag._();

  static const _prefix = 'first_run.';

  /// Key for the editor onboarding dialog that explains the Snapseed
  /// gesture layer and key controls. Bump the suffix when you want to
  /// re-show the dialog to existing users.
  static const editorOnboardingV1 = 'editor_onboarding_v1';

  /// Returns true iff the user has NOT yet seen the tip.
  static Future<bool> shouldShow(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool('$_prefix$key') ?? false;
      _log.d('shouldShow', {'key': key, 'shown': !seen});
      return !seen;
    } catch (e) {
      _log.w('read failed — defaulting to not showing', {'key': key});
      return false;
    }
  }

  /// Mark [key] as seen so [shouldShow] returns false next time.
  static Future<void> markSeen(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_prefix$key', true);
      _log.i('marked seen', {'key': key});
    } catch (e) {
      _log.w('write failed', {'key': key, 'error': e.toString()});
    }
  }

  /// Test helper — resets every flag prefixed by `first_run.`.
  static Future<void> resetAllForTests() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys()) {
      if (k.startsWith(_prefix)) {
        await prefs.remove(k);
      }
    }
  }
}
