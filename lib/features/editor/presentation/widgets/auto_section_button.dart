import 'package:flutter/material.dart';

import '../../../../core/feedback/user_feedback.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../../../../core/theme/spacing.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('AutoBtn');

/// Pill button + optional secondary chip rendered at the top of the
/// Light and Color panels. One tap analyses the source image and folds
/// the computed targets into that section's sliders as a single undo
/// frame.
///
/// When [includeWhiteBalance] is true (Color panel), a second chip
/// exposes "Auto WB" which only touches temperature + tint.
class AutoSectionButton extends StatelessWidget {
  const AutoSectionButton({
    super.key,
    required this.session,
    required this.scope,
    this.includeWhiteBalance = false,
  });

  final EditorSession session;
  final AutoFixScope scope;
  final bool includeWhiteBalance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.lg,
        0,
      ),
      child: Row(
        children: [
          FilledButton.tonalIcon(
            onPressed: () => _run(context, scope),
            icon: const Icon(Icons.auto_fix_high, size: 18),
            label: Text(_label(scope)),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (includeWhiteBalance) ...[
            const SizedBox(width: Spacing.sm),
            ActionChip(
              avatar: const Icon(Icons.wb_auto, size: 18),
              label: const Text('Auto WB'),
              onPressed: () => _run(context, AutoFixScope.whiteBalance),
            ),
          ],
          const Spacer(),
          Tooltip(
            message:
                'Analyses the photo and sets this section\'s sliders. '
                'You can still fine-tune each one afterwards.',
            child: Icon(
              Icons.info_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _label(AutoFixScope s) => switch (s) {
        AutoFixScope.all => 'Auto',
        AutoFixScope.light => 'Auto Light',
        AutoFixScope.color => 'Auto Color',
        AutoFixScope.whiteBalance => 'Auto WB',
      };

  Future<void> _run(BuildContext context, AutoFixScope s) async {
    _log.i('tap', {'scope': s.name});
    Haptics.tap();
    final ok = await session.applyAuto(s);
    if (!context.mounted) return;
    String msg;
    if (ok) {
      msg = '${_label(s)} applied — tweak any slider to refine';
    } else if (s == AutoFixScope.whiteBalance) {
      // WB is the only scope that can return false — it has no
      // confidence-bonus fallback because a neutral photo genuinely
      // has nothing to correct.
      msg = 'Your whites already look neutral';
    } else {
      msg = 'Nothing to change here';
    }
    UserFeedback.info(context, msg);
  }
}
