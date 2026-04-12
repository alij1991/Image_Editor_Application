import 'package:flutter/material.dart';

import '../logging/app_logger.dart';

final _log = AppLogger('UserFeedback');

/// Typed user-feedback helpers that wrap [ScaffoldMessenger] with
/// consistent icon + duration + color usage. Every feedback call logs,
/// so we can trace which message was shown to the user at what time.
///
/// Usage:
///   UserFeedback.success(context, 'Preset applied');
///   UserFeedback.info(context, 'Undone', action: 'Redo', onAction: ...);
///   UserFeedback.error(context, 'Failed to save preset');
class UserFeedback {
  UserFeedback._();

  static void success(BuildContext context, String message) {
    _log.i('success', {'message': message});
    _show(
      context,
      icon: Icons.check_circle_outline,
      message: message,
    );
  }

  static void info(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _log.i('info', {'message': message, 'action': actionLabel});
    _show(
      context,
      icon: Icons.info_outline,
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  static void error(BuildContext context, String message) {
    _log.w('error', {'message': message});
    _show(
      context,
      icon: Icons.error_outline,
      message: message,
      isError: true,
    );
  }

  static void _show(
    BuildContext context, {
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    bool isError = false,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 12),
              Flexible(child: Text(message)),
            ],
          ),
          action: actionLabel != null && onAction != null
              ? SnackBarAction(label: actionLabel, onPressed: onAction)
              : null,
        ),
      );
  }
}
