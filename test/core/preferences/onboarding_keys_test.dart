import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:image_editor/core/preferences/first_run_flag.dart';

/// X.A.2 — central `OnboardingKeys` registry. Pins: every registered
/// key follows the `<feature>_<descriptor>_v<version>` format, the
/// `all` list contains every key (so reset sweeps don't miss any),
/// and the deprecated `FirstRunFlag.editorOnboardingV1` alias still
/// forwards to the new const.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('OnboardingKeys.all enumerates every static key', () {
    // Keeping the test tight: if a new key lands without being added
    // to `all`, the sweep / reset paths would miss it. Count + value
    // pin catches the omission.
    expect(OnboardingKeys.all, contains(OnboardingKeys.editorOnboarding));
    expect(OnboardingKeys.all.length, 1,
        reason: 'bump this number + the list above when adding a new key');
  });

  test('every registered key is unique', () {
    final set = OnboardingKeys.all.toSet();
    expect(set.length, OnboardingKeys.all.length);
  });

  test('every key follows the <name>_v<version> suffix convention', () {
    final re = RegExp(r'_v\d+$');
    for (final k in OnboardingKeys.all) {
      expect(re.hasMatch(k), isTrue,
          reason: 'key "$k" should end in _v<digit>+');
    }
  });

  test('deprecated FirstRunFlag.editorOnboardingV1 forwards to OnboardingKeys',
      () {
    // The `@Deprecated` annotation only affects lint output; the
    // constant itself must still resolve to the new value so
    // pre-migration call sites read/write the same pref key.
    // ignore: deprecated_member_use_from_same_package
    expect(FirstRunFlag.editorOnboardingV1, OnboardingKeys.editorOnboarding);
  });

  test('resetAllForTests clears a key set via markSeen', () async {
    await FirstRunFlag.markSeen(OnboardingKeys.editorOnboarding);
    expect(
      await FirstRunFlag.shouldShow(OnboardingKeys.editorOnboarding),
      isFalse,
    );
    await FirstRunFlag.resetAllForTests();
    expect(
      await FirstRunFlag.shouldShow(OnboardingKeys.editorOnboarding),
      isTrue,
    );
  });
}
