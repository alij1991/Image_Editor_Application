import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/platform/haptics.dart';
import '../notifiers/editor_session.dart';

final _log = AppLogger('BeforeAfterToggle');

/// Press-and-hold button that shows the original image (all ops disabled)
/// while pressed, and restores the edited view on release.
///
/// Uses [EditorSession.setAllOpsEnabledTransient] which emits a
/// [SetAllOpsEnabled] event on the history bloc. That event doesn't
/// record a history entry — it's a view-only toggle.
class BeforeAfterToggle extends StatefulWidget {
  const BeforeAfterToggle({required this.session, super.key});

  final EditorSession session;

  @override
  State<BeforeAfterToggle> createState() => _BeforeAfterToggleState();
}

class _BeforeAfterToggleState extends State<BeforeAfterToggle> {
  bool _holding = false;

  void _start() {
    if (_holding) return;
    _log.i('holding original');
    Haptics.tap();
    setState(() => _holding = true);
    widget.session.setAllOpsEnabledTransient(false);
  }

  void _end() {
    if (!_holding) return;
    _log.i('releasing');
    setState(() => _holding = false);
    widget.session.setAllOpsEnabledTransient(true);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Hold to view the original photo',
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _end(),
        onPointerCancel: (_) => _end(),
        child: IconButton(
          icon: Icon(
            _holding ? Icons.visibility_off : Icons.compare,
            color: _holding
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          onPressed: () {},
        ),
      ),
    );
  }
}
