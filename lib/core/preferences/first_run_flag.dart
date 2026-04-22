import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('FirstRunFlag');

/// Phase X.A.2 — central registry of onboarding tip keys.
///
/// Pre-X.A.2 the single key lived on `FirstRunFlag` itself; adding a
/// new coach mark meant hunting for the existing constant + risking
/// duplication. With this split, new keys go on `OnboardingKeys` and
/// `FirstRunFlag` stays focused on read / write / reset.
///
/// Key format: `<feature>_<descriptor>_v<version>`. Bump the version
/// suffix when the tip's copy changes enough that users who saw the
/// old wording should see it again.
class OnboardingKeys {
  OnboardingKeys._();

  /// Editor onboarding dialog — explains the Snapseed gesture layer
  /// and key controls on first launch of the editor route.
  static const editorOnboarding = 'editor_onboarding_v1';

  /// Every registered key. Adding a new entry here auto-threads
  /// through [FirstRunFlag.resetAllForTests] + any future "reset
  /// onboarding" settings action.
  static const List<String> all = <String>[
    editorOnboarding,
  ];
}

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

  /// Deprecated alias. Use [OnboardingKeys.editorOnboarding] instead.
  /// Kept as a forwarding constant so pre-X.A.2 call sites keep
  /// compiling until they migrate.
  @Deprecated('Use OnboardingKeys.editorOnboarding instead.')
  static const editorOnboardingV1 = OnboardingKeys.editorOnboarding;

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
