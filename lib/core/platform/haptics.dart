import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('Haptics');

/// Thin wrapper over [HapticFeedback] with typed intents. Centralizing
/// lets us tune the intensity of each interaction in one place and adds
/// a debug log so we can trace which user actions triggered which
/// feedback.
class Haptics {
  Haptics._();

  /// Fired when a slider resets to identity, a preset applies, or the
  /// before/after toggle engages — distinct, satisfying, but not
  /// disruptive.
  static Future<void> tap() async {
    _log.d('tap');
    await HapticFeedback.selectionClick();
  }

  /// Fired for confirmed state changes the user initiated (save preset,
  /// delete preset). Heavier than [tap].
  static Future<void> impact() async {
    _log.d('impact');
    await HapticFeedback.mediumImpact();
  }

  /// Fired for errors or invalid actions (save without a name, delete a
  /// built-in preset). Strongest pulse.
  static Future<void> warning() async {
    _log.d('warning');
    await HapticFeedback.heavyImpact();
  }
}
